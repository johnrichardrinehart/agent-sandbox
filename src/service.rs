use std::path::{Component, Path, PathBuf};
use std::{fs, io};

#[cfg(unix)]
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

use tokio::process::Command;
use tokio::time::{Duration, timeout};
use tonic::{Request, Response, Status};
use tracing::info;

use crate::sandbox::v0::{
    ExecuteCommandRequest, ExecuteCommandResponse, HealthCheckRequest, HealthCheckResponse,
    ReadFileRequest, ReadFileResponse, ServingStatus, WriteFileRequest, WriteFileResponse,
    command_service_server::CommandService, filesystem_service_server::FilesystemService,
    health_service_server::HealthService,
};

const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 30_000;
const MAX_COMMAND_TIMEOUT_MS: u64 = 300_000;
const COMMAND_TIMEOUT_EXIT_CODE: i32 = 124;

#[derive(Clone)]
pub(crate) struct SandboxService {
    root: PathBuf,
    sandbox_program: PathBuf,
}

impl SandboxService {
    pub(crate) fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        let sandbox_program = std::env::var_os("AGENT_SANDBOX_BWRAP")
            .map_or_else(|| PathBuf::from("bwrap"), PathBuf::from);
        Self::with_sandbox_program(root, sandbox_program)
    }

    fn with_sandbox_program(
        root: impl AsRef<Path>,
        sandbox_program: impl Into<PathBuf>,
    ) -> io::Result<Self> {
        fs::create_dir_all(root.as_ref())?;
        Ok(Self {
            root: fs::canonicalize(root)?,
            sandbox_program: sandbox_program.into(),
        })
    }

    fn relative_path(&self, requested: &str) -> Result<PathBuf, SandboxPathError> {
        if requested.is_empty() {
            return Err(SandboxPathError::Invalid("path must not be empty"));
        }

        let requested = Path::new(requested);
        let relative = if requested.is_absolute() {
            requested.strip_prefix(&self.root).map_err(|_| {
                SandboxPathError::Denied("absolute path must be under the sandbox root")
            })?
        } else {
            requested
        };

        let mut clean = PathBuf::new();
        for component in relative.components() {
            match component {
                Component::Normal(part) => clean.push(part),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                    return Err(SandboxPathError::Denied("path escapes the sandbox root"));
                }
            }
        }

        if clean.as_os_str().is_empty() {
            return Err(SandboxPathError::Invalid("path must name an entry"));
        }
        Ok(clean)
    }

    fn existing_path(&self, requested: &str) -> Result<PathBuf, SandboxPathError> {
        let relative = self.relative_path(requested)?;
        let canonical = fs::canonicalize(self.root.join(relative))?;
        self.ensure_scoped(canonical)
    }

    fn writable_path(
        &self,
        requested: &str,
        create_parents: bool,
    ) -> Result<PathBuf, SandboxPathError> {
        let relative = self.relative_path(requested)?;
        let candidate = self.root.join(relative);

        match fs::symlink_metadata(&candidate) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                return Err(SandboxPathError::Denied(
                    "write target must not be a symbolic link",
                ));
            }
            Ok(_) => return self.ensure_scoped(fs::canonicalize(candidate)?),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }

        let parent = candidate
            .parent()
            .ok_or(SandboxPathError::Invalid("path has no parent"))?;
        let canonical_parent = if create_parents {
            self.create_scoped_parents(parent)?
        } else {
            self.ensure_scoped(fs::canonicalize(parent)?)?
        };
        let filename = candidate
            .file_name()
            .ok_or(SandboxPathError::Invalid("path must name a file"))?;
        Ok(canonical_parent.join(filename))
    }

    fn create_scoped_parents(&self, parent: &Path) -> Result<PathBuf, SandboxPathError> {
        let relative = parent
            .strip_prefix(&self.root)
            .map_err(|_| SandboxPathError::Denied("path escapes the sandbox root"))?;
        let mut current = self.root.clone();
        for component in relative.components() {
            current.push(component);
            match fs::symlink_metadata(&current) {
                Ok(_) => {
                    current = self.ensure_scoped(fs::canonicalize(&current)?)?;
                    if !current.is_dir() {
                        return Err(SandboxPathError::Invalid("parent path is not a directory"));
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {
                    fs::create_dir(&current)?;
                    current = self.ensure_scoped(fs::canonicalize(&current)?)?;
                }
                Err(error) => return Err(error.into()),
            }
        }
        Ok(current)
    }

    fn ensure_scoped(&self, path: PathBuf) -> Result<PathBuf, SandboxPathError> {
        if path.starts_with(&self.root) {
            Ok(path)
        } else {
            Err(SandboxPathError::Denied("path escapes the sandbox root"))
        }
    }

    fn working_directory(&self, requested: &str) -> Result<PathBuf, SandboxPathError> {
        let directory = if requested.is_empty() {
            self.root.clone()
        } else {
            self.existing_path(requested)?
        };
        if directory.is_dir() {
            Ok(directory)
        } else {
            Err(SandboxPathError::Invalid(
                "working directory is not a directory",
            ))
        }
    }
}

#[tonic::async_trait]
impl FilesystemService for SandboxService {
    async fn write_file(
        &self,
        request: Request<WriteFileRequest>,
    ) -> Result<Response<WriteFileResponse>, Status> {
        let request = request.into_inner();
        let path = self
            .writable_path(&request.path, request.create_parents)
            .map_err(SandboxPathError::into_status)?;
        write_content(&path, &request.content).map_err(|error| io_status(&error))?;
        info!(path = %path.display(), bytes = request.content.len(), "wrote file");
        Ok(Response::new(WriteFileResponse {
            bytes_written: request.content.len() as u64,
        }))
    }

    async fn read_file(
        &self,
        request: Request<ReadFileRequest>,
    ) -> Result<Response<ReadFileResponse>, Status> {
        let path = self
            .existing_path(&request.into_inner().path)
            .map_err(SandboxPathError::into_status)?;
        if !path.is_file() {
            return Err(Status::invalid_argument("path is not a file"));
        }
        let content = fs::read(&path).map_err(|error| io_status(&error))?;
        info!(path = %path.display(), bytes = content.len(), "read file");
        Ok(Response::new(ReadFileResponse { content }))
    }
}

#[tonic::async_trait]
impl HealthService for SandboxService {
    async fn check(
        &self,
        _request: Request<HealthCheckRequest>,
    ) -> Result<Response<HealthCheckResponse>, Status> {
        Ok(Response::new(HealthCheckResponse {
            status: ServingStatus::Serving.into(),
        }))
    }
}

#[tonic::async_trait]
impl CommandService for SandboxService {
    async fn execute_command(
        &self,
        request: Request<ExecuteCommandRequest>,
    ) -> Result<Response<ExecuteCommandResponse>, Status> {
        let request = request.into_inner();
        let (program, arguments) = request
            .argv
            .split_first()
            .ok_or_else(|| Status::invalid_argument("argv must contain an executable"))?;
        let working_directory = self
            .working_directory(&request.working_directory)
            .map_err(SandboxPathError::into_status)?;
        let timeout_ms = match request.timeout_ms {
            0 => DEFAULT_COMMAND_TIMEOUT_MS,
            value if value <= MAX_COMMAND_TIMEOUT_MS => value,
            _ => {
                return Err(Status::invalid_argument(format!(
                    "timeout_ms must not exceed {MAX_COMMAND_TIMEOUT_MS}"
                )));
            }
        };

        info!(program, cwd = %working_directory.display(), timeout_ms, "executing command");
        let mut command = Command::new(&self.sandbox_program);
        command
            .args([
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--chmod",
                "1777",
                "/tmp",
                "--tmpfs",
                "/var/tmp",
                "--chmod",
                "1777",
                "/var/tmp",
                "--dev",
                "/dev",
                "--tmpfs",
                "/proc",
                "--bind",
            ])
            .arg(&self.root)
            .arg(&self.root)
            .args([
                "--unshare-user",
                "--unshare-pid",
                "--unshare-ipc",
                "--die-with-parent",
            ])
            .args(["--new-session", "--setenv", "HOME"])
            .arg(&self.root)
            .arg("--chdir")
            .arg(&working_directory)
            .arg("--")
            .arg(program)
            .args(arguments)
            .envs(request.environment)
            .kill_on_drop(true);

        let response = match timeout(Duration::from_millis(timeout_ms), command.output()).await {
            Ok(Ok(output)) => ExecuteCommandResponse {
                stdout: output.stdout,
                stderr: output.stderr,
                exit_code: output.status.code().unwrap_or(-1),
            },
            Ok(Err(error)) => ExecuteCommandResponse {
                stdout: Vec::new(),
                stderr: format!("failed to start command sandbox: {error}\n").into_bytes(),
                exit_code: 127,
            },
            Err(_) => ExecuteCommandResponse {
                stdout: Vec::new(),
                stderr: b"command timed out\n".to_vec(),
                exit_code: COMMAND_TIMEOUT_EXIT_CODE,
            },
        };

        info!(program, exit_code = response.exit_code, "command completed");
        Ok(Response::new(response))
    }
}

enum SandboxPathError {
    Invalid(&'static str),
    Denied(&'static str),
    Io(io::Error),
}

impl SandboxPathError {
    fn into_status(self) -> Status {
        match self {
            Self::Invalid(message) => Status::invalid_argument(message),
            Self::Denied(message) => Status::permission_denied(message),
            Self::Io(error) => io_status(&error),
        }
    }
}

impl From<io::Error> for SandboxPathError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[cfg(unix)]
fn write_content(path: &Path, content: &[u8]) -> io::Result<()> {
    // O_NOFOLLOW prevents a concurrent replacement with a symbolic link.
    const O_NOFOLLOW: i32 = 0x20_000;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .custom_flags(O_NOFOLLOW)
        .open(path)?;
    file.write_all(content)
}

#[cfg(not(unix))]
fn write_content(path: &Path, content: &[u8]) -> io::Result<()> {
    fs::write(path, content)
}

fn io_status(error: &io::Error) -> Status {
    match error.kind() {
        io::ErrorKind::NotFound => Status::not_found(error.to_string()),
        io::ErrorKind::PermissionDenied => Status::permission_denied(error.to_string()),
        io::ErrorKind::AlreadyExists | io::ErrorKind::InvalidInput => {
            Status::invalid_argument(error.to_string())
        }
        _ => Status::internal(error.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    use tonic::Code;

    fn service() -> (TempDir, SandboxService) {
        let root = TempDir::new().expect("create temporary root");
        let service =
            SandboxService::with_sandbox_program(root.path(), "bwrap").expect("create service");
        (root, service)
    }

    fn command_sandbox_is_supported() -> bool {
        let root = TempDir::new().expect("create sandbox probe root");
        std::process::Command::new("bwrap")
            .args([
                "--ro-bind",
                "/",
                "/",
                "--tmpfs",
                "/tmp",
                "--chmod",
                "1777",
                "/tmp",
                "--tmpfs",
                "/var/tmp",
                "--chmod",
                "1777",
                "/var/tmp",
                "--dev",
                "/dev",
                "--tmpfs",
                "/proc",
                "--bind",
            ])
            .arg(root.path())
            .arg(root.path())
            .args([
                "--unshare-user",
                "--unshare-pid",
                "--unshare-ipc",
                "--die-with-parent",
                "--new-session",
                "--chdir",
            ])
            .arg(root.path())
            .args(["--", "true"])
            .status()
            .is_ok_and(|status| status.success())
    }

    #[tokio::test]
    async fn writes_and_reads_nested_files() {
        let (_root, service) = service();
        service
            .write_file(Request::new(WriteFileRequest {
                path: "fixtures/example.txt".into(),
                content: b"hello".to_vec(),
                create_parents: true,
            }))
            .await
            .expect("write file");

        let response = service
            .read_file(Request::new(ReadFileRequest {
                path: "fixtures/example.txt".into(),
            }))
            .await
            .expect("read file")
            .into_inner();
        assert_eq!(response.content, b"hello");
    }

    #[tokio::test]
    async fn rejects_parent_path_escape() {
        let (_root, service) = service();
        let error = service
            .write_file(Request::new(WriteFileRequest {
                path: "../escape.txt".into(),
                content: Vec::new(),
                create_parents: true,
            }))
            .await
            .expect_err("escape must fail");
        assert_eq!(error.code(), Code::PermissionDenied);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlink_path_escape() {
        use std::os::unix::fs::symlink;

        let (root, service) = service();
        let outside = TempDir::new().expect("create outside directory");
        symlink(outside.path(), root.path().join("outside")).expect("create symlink");
        let error = service
            .write_file(Request::new(WriteFileRequest {
                path: "outside/escape.txt".into(),
                content: Vec::new(),
                create_parents: false,
            }))
            .await
            .expect_err("symlink escape must fail");
        assert_eq!(error.code(), Code::PermissionDenied);
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_dangling_symlink_without_writing_outside_root() {
        use std::os::unix::fs::symlink;

        let (root, service) = service();
        let outside = TempDir::new().expect("create outside directory");
        let outside_file = outside.path().join("escaped.txt");
        symlink(&outside_file, root.path().join("dangling")).expect("create dangling symlink");

        let error = service
            .write_file(Request::new(WriteFileRequest {
                path: "dangling".into(),
                content: b"escape".to_vec(),
                create_parents: false,
            }))
            .await
            .expect_err("dangling symlink must fail");

        assert_eq!(error.code(), Code::PermissionDenied);
        assert!(!outside_file.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlink_parent_without_creating_outside_directories() {
        use std::os::unix::fs::symlink;

        let (root, service) = service();
        let outside = TempDir::new().expect("create outside directory");
        symlink(outside.path(), root.path().join("outside")).expect("create directory symlink");

        let error = service
            .write_file(Request::new(WriteFileRequest {
                path: "outside/new/escaped.txt".into(),
                content: b"escape".to_vec(),
                create_parents: true,
            }))
            .await
            .expect_err("symlink parent must fail");

        assert_eq!(error.code(), Code::PermissionDenied);
        assert!(!outside.path().join("new").exists());
    }

    #[tokio::test]
    async fn executes_each_command_in_a_fresh_process() {
        if !command_sandbox_is_supported() {
            return;
        }
        let (_root, service) = service();
        let response = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["sh".into(), "-c".into(), "printf '%s' \"$VALUE\"".into()],
                environment: [("VALUE".into(), "available".into())].into(),
                ..Default::default()
            }))
            .await
            .expect("execute command")
            .into_inner();
        assert_eq!(response.stdout, b"available");
        assert!(response.stderr.is_empty());
        assert_eq!(response.exit_code, 0);
    }

    #[tokio::test]
    async fn commands_do_not_share_temporary_files() {
        if !command_sandbox_is_supported() {
            return;
        }
        let (_root, service) = service();
        let write = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["sh".into(), "-c".into(), "printf leak >/tmp/leak".into()],
                ..Default::default()
            }))
            .await
            .expect("write temporary file")
            .into_inner();
        assert_eq!(write.exit_code, 0);

        let read = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["sh".into(), "-c".into(), "test ! -e /tmp/leak".into()],
                ..Default::default()
            }))
            .await
            .expect("check temporary file")
            .into_inner();
        assert_eq!(read.exit_code, 0);
    }

    #[tokio::test]
    async fn command_completion_terminates_descendants() {
        if !command_sandbox_is_supported() {
            return;
        }
        let (root, service) = service();
        let marker = root.path().join("descendant-finished");
        let response = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec![
                    "sh".into(),
                    "-c".into(),
                    "(sleep 0.1; touch descendant-finished) </dev/null >/dev/null 2>&1 &".into(),
                ],
                ..Default::default()
            }))
            .await
            .expect("start detached descendant")
            .into_inner();
        assert_eq!(response.exit_code, 0);

        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(!marker.exists());
    }

    #[tokio::test]
    async fn missing_executable_returns_response_triplet() {
        if !command_sandbox_is_supported() {
            return;
        }
        let (_root, service) = service();
        let response = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["executable-that-does-not-exist".into()],
                ..Default::default()
            }))
            .await
            .expect("return command result")
            .into_inner();

        assert_ne!(response.exit_code, 0);
        assert!(response.stdout.is_empty());
        assert!(!response.stderr.is_empty());
    }

    #[tokio::test]
    async fn timeout_returns_response_triplet() {
        if !command_sandbox_is_supported() {
            return;
        }
        let (_root, service) = service();
        let response = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["sleep".into(), "10".into()],
                timeout_ms: 10,
                ..Default::default()
            }))
            .await
            .expect("return timeout result")
            .into_inner();

        assert_eq!(response.exit_code, COMMAND_TIMEOUT_EXIT_CODE);
        assert!(response.stdout.is_empty());
        assert_eq!(response.stderr, b"command timed out\n");
    }
}
