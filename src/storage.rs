use std::env;
use std::error::Error;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tokio::process::Command;
use tokio::sync::watch;
use tokio::time::{Instant, MissedTickBehavior};
use tracing::{info, warn};

pub(crate) type StorageResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

const DEFAULT_BACKUP_INTERVAL_SECONDS: u64 = 300;
const DEFAULT_RESTIC_PASSWORD: &str = "agent-sandbox";
const RESTIC_PARTIAL_BACKUP_EXIT_CODE: i32 = 3;
const RESTIC_REPOSITORY_MISSING_EXIT_CODE: i32 = 10;

#[derive(Clone)]
pub(crate) struct ResticBackup {
    repository: String,
    host: String,
    cache: PathBuf,
    interval: Duration,
}

impl ResticBackup {
    pub(crate) fn from_env() -> StorageResult<Self> {
        let repository = env::var("RESTIC_REPOSITORY")
            .ok()
            .filter(|value| !value.is_empty())
            .ok_or("RESTIC_REPOSITORY must name a repository")?;

        let interval = env::var("AGENT_SANDBOX_BACKUP_INTERVAL_SECONDS")
            .map_or(Ok(DEFAULT_BACKUP_INTERVAL_SECONDS), |value| value.parse())?;
        if interval == 0 {
            return Err("AGENT_SANDBOX_BACKUP_INTERVAL_SECONDS must be greater than zero".into());
        }

        Ok(Self {
            repository,
            host: env::var("AGENT_SANDBOX_BACKUP_HOST").unwrap_or_else(|_| "agent-sandbox".into()),
            cache: env::var_os("RESTIC_CACHE_DIR")
                .map_or_else(|| PathBuf::from("/tmp/restic-cache"), PathBuf::from),
            interval: Duration::from_secs(interval),
        })
    }

    pub(crate) async fn restore(&self, root: &Path) -> StorageResult<()> {
        tokio::fs::create_dir_all(root).await?;
        self.ensure_repository().await?;
        self.verify_write().await?;

        let root = path_argument(root)?;
        let snapshots = self
            .run([
                "snapshots",
                "--json",
                "--latest",
                "1",
                "--host",
                &self.host,
                "--path",
                root,
            ])
            .await?;
        require_success("list restic snapshots", snapshots.status, &snapshots.stderr)?;

        if snapshots.stdout.iter().all(u8::is_ascii_whitespace)
            || snapshots.stdout == b"[]\n"
            || snapshots.stdout == b"[]"
        {
            info!("restic repository has no sandbox snapshot");
            return Ok(());
        }

        let descendants = format!("{root}/**");
        let restored = self
            .run([
                "restore",
                "latest",
                "--target",
                "/",
                "--delete",
                "--include",
                root,
                "--include",
                &descendants,
                "--host",
                &self.host,
                "--path",
                root,
            ])
            .await?;
        require_success(
            "restore sandbox snapshot",
            restored.status,
            &restored.stderr,
        )?;
        info!(root, "restored sandbox from restic");
        Ok(())
    }

    async fn verify_write(&self) -> StorageResult<()> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let sentinel = self.cache.join(format!(
            ".agent-sandbox-test-{}-{nonce}",
            std::process::id()
        ));
        tokio::fs::create_dir_all(&self.cache).await?;
        tokio::fs::write(&sentinel, b"sentinel").await?;
        let sentinel_argument = path_argument(&sentinel)?;
        let output = self
            .run([
                "backup",
                sentinel_argument,
                "--host",
                &self.host,
                "--tag",
                "agent-sandbox-test",
                "--json",
            ])
            .await;
        tokio::fs::remove_file(&sentinel).await?;
        let output = output?;
        require_success("write restic sentinel", output.status, &output.stderr)?;
        let snapshot = snapshot_id(&output.stdout)?;
        let forgotten = self.run(["forget", snapshot]).await?;
        require_success(
            "remove restic sentinel snapshot",
            forgotten.status,
            &forgotten.stderr,
        )?;
        Ok(())
    }

    pub(crate) async fn backup(&self, root: &Path) -> StorageResult<()> {
        let root = path_argument(root)?;
        let output = self
            .run([
                "backup",
                "--host",
                &self.host,
                "--tag",
                "agent-sandbox",
                "--with-atime",
                root,
            ])
            .await?;

        if output.status.success() {
            info!(root, "saved sandbox restic snapshot");
            return Ok(());
        }
        if output.status.code() == Some(RESTIC_PARTIAL_BACKUP_EXIT_CODE) {
            warn!(
                root,
                stderr = %String::from_utf8_lossy(&output.stderr).trim(),
                "saved a partial sandbox restic snapshot"
            );
            return Ok(());
        }

        Err(command_error(
            "save sandbox restic snapshot",
            output.status,
            &output.stderr,
        ))
    }

    pub(crate) async fn run_periodic(&self, root: &Path, mut stop: watch::Receiver<bool>) {
        let start = Instant::now() + self.interval;
        let mut interval = tokio::time::interval_at(start, self.interval);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                changed = stop.changed() => {
                    if changed.is_err() || *stop.borrow() {
                        return;
                    }
                }
                _ = interval.tick() => {
                    if let Err(error) = self.backup(root).await {
                        warn!(%error, "periodic restic backup failed");
                    }
                }
            }
        }
    }

    async fn ensure_repository(&self) -> StorageResult<()> {
        let config = self.run(["cat", "config"]).await?;
        if config.status.success() {
            return Ok(());
        }
        if config.status.code() != Some(RESTIC_REPOSITORY_MISSING_EXIT_CODE) {
            return Err(command_error(
                "open restic repository",
                config.status,
                &config.stderr,
            ));
        }

        let initialized = self.run(["init"]).await?;
        require_success(
            "initialize restic repository",
            initialized.status,
            &initialized.stderr,
        )?;
        info!(repository = %self.repository, "initialized restic repository");
        Ok(())
    }

    async fn run<I, S>(&self, arguments: I) -> StorageResult<std::process::Output>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        tokio::fs::create_dir_all(&self.cache).await?;
        let mut command = Command::new("restic");
        command
            .args(arguments)
            .env("RESTIC_REPOSITORY", &self.repository)
            .env("RESTIC_CACHE_DIR", &self.cache)
            .kill_on_drop(true);
        set_restic_password(&mut command);
        Ok(command.output().await?)
    }
}

fn set_restic_password(command: &mut Command) {
    let variables = [
        "RESTIC_PASSWORD",
        "RESTIC_PASSWORD_FILE",
        "RESTIC_PASSWORD_COMMAND",
    ];
    let configured = variables
        .iter()
        .any(|name| env::var_os(name).is_some_and(|value| !value.is_empty()));

    for name in variables {
        if env::var_os(name).is_some_and(|value| value.is_empty()) {
            command.env_remove(name);
        }
    }
    if !configured {
        command.env("RESTIC_PASSWORD", DEFAULT_RESTIC_PASSWORD);
    }
}

fn snapshot_id(output: &[u8]) -> StorageResult<&str> {
    let output = std::str::from_utf8(output)?;
    let marker = "\"snapshot_id\":\"";
    let start = output
        .rfind(marker)
        .map(|index| index + marker.len())
        .ok_or("restic did not return a sentinel snapshot ID")?;
    let end = output[start..]
        .find('"')
        .map(|index| start + index)
        .ok_or("restic returned an invalid sentinel snapshot ID")?;
    Ok(&output[start..end])
}

fn path_argument(path: &Path) -> StorageResult<&str> {
    path.to_str()
        .ok_or_else(|| "sandbox root is not valid UTF-8".into())
}

fn require_success(action: &str, status: ExitStatus, stderr: &[u8]) -> StorageResult<()> {
    if status.success() {
        Ok(())
    } else {
        Err(command_error(action, status, stderr))
    }
}

fn command_error(action: &str, status: ExitStatus, stderr: &[u8]) -> Box<dyn Error + Send + Sync> {
    format!(
        "failed to {action}: restic exited with {status}: {}",
        String::from_utf8_lossy(stderr).trim()
    )
    .into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_success_status() {
        let status = std::process::Command::new("true")
            .status()
            .expect("run true");
        require_success("test", status, b"").expect("accept success");
    }

    #[test]
    fn reads_snapshot_id_from_restic_summary() {
        let output = br#"{"message_type":"summary","snapshot_id":"abc123"}"#;
        assert_eq!(snapshot_id(output).expect("read snapshot ID"), "abc123");
    }

    #[test]
    fn reports_command_failure() {
        let status = std::process::Command::new("false")
            .status()
            .expect("run false");
        let error =
            require_success("test action", status, b"test detail").expect_err("reject failure");
        assert!(error.to_string().contains("test action"));
        assert!(error.to_string().contains("test detail"));
    }
}
