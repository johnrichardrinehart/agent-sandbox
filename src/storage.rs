use std::collections::HashSet;
use std::env;
use std::error::Error;
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use futures_util::TryStreamExt;
use object_store::aws::AmazonS3Builder;
use object_store::path::Path;
use object_store::{ObjectMeta, ObjectStore};
use tracing::info;
use walkdir::WalkDir;

pub(crate) type StorageResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Clone)]
pub(crate) struct S3Sync {
    store: Arc<dyn ObjectStore>,
    prefix: Path,
}

impl S3Sync {
    pub(crate) fn from_env() -> StorageResult<Self> {
        let bucket = env::var("AGENT_SANDBOX_S3_BUCKET")
            .ok()
            .filter(|value| !value.is_empty())
            .ok_or("AGENT_SANDBOX_S3_BUCKET must name a bucket")?;

        let mut builder = AmazonS3Builder::from_env()
            .with_bucket_name(bucket)
            .with_virtual_hosted_style_request(false);
        if let Some(endpoint) = env::var("AGENT_SANDBOX_S3_ENDPOINT")
            .ok()
            .filter(|value| !value.is_empty())
        {
            builder = builder
                .with_allow_http(endpoint.starts_with("http://"))
                .with_endpoint(endpoint);
        }

        let prefix = env::var("AGENT_SANDBOX_S3_PREFIX").unwrap_or_else(|_| "home".into());
        Ok(Self {
            store: Arc::new(builder.build()?),
            prefix: Path::parse(prefix)?,
        })
    }

    pub(crate) async fn verify_write(&self) -> StorageResult<()> {
        let nonce = SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos();
        let sentinel = Path::from(format!(
            ".agent-sandbox-test-{}-{nonce}",
            std::process::id()
        ));
        self.store.put(&sentinel, Vec::new().into()).await?;
        self.store.delete(&sentinel).await?;
        Ok(())
    }

    pub(crate) async fn sync_down(&self, root: &FsPath) -> StorageResult<()> {
        tokio::fs::create_dir_all(root).await?;
        let objects = self.list().await?;
        for object in &objects {
            let Some(relative) = self.relative_path(&object.location) else {
                continue;
            };
            let destination = relative
                .iter()
                .fold(root.to_path_buf(), |path, part| path.join(part));
            if let Some(parent) = destination.parent() {
                tokio::fs::create_dir_all(parent).await?;
            }
            let content = self.store.get(&object.location).await?.bytes().await?;
            tokio::fs::write(destination, content).await?;
        }
        info!(objects = objects.len(), "synchronized sandbox from S3");
        Ok(())
    }

    pub(crate) async fn sync_up(&self, root: &FsPath) -> StorageResult<()> {
        let local = local_files(root)?;
        let mut local_keys = HashSet::with_capacity(local.len());
        for (file, relative) in &local {
            let key = self.object_path(relative)?;
            let content = tokio::fs::read(file).await?;
            self.store.put(&key, content.into()).await?;
            local_keys.insert(key);
        }

        let remote = self.list().await?;
        let mut deleted = 0;
        for object in remote {
            if !local_keys.contains(&object.location) {
                self.store.delete(&object.location).await?;
                deleted += 1;
            }
        }
        info!(objects = local.len(), deleted, "synchronized sandbox to S3");
        Ok(())
    }

    async fn list(&self) -> StorageResult<Vec<ObjectMeta>> {
        Ok(self
            .store
            .list(Some(&self.prefix))
            .try_collect::<Vec<_>>()
            .await?)
    }

    fn relative_path(&self, object: &Path) -> Option<Vec<String>> {
        let parts = object
            .prefix_match(&self.prefix)?
            .map(|part| part.as_ref().to_owned())
            .collect::<Vec<_>>();
        (!parts.is_empty()).then_some(parts)
    }

    fn object_path(&self, relative: &FsPath) -> StorageResult<Path> {
        let relative = relative
            .to_str()
            .ok_or("sandbox file path is not valid UTF-8")?;
        let relative = Path::parse(relative)?;
        let mut result = self.prefix.clone();
        for part in relative.parts() {
            result = result.child(part);
        }
        Ok(result)
    }
}

fn local_files(root: &FsPath) -> StorageResult<Vec<(PathBuf, PathBuf)>> {
    let mut files = Vec::new();
    for entry in WalkDir::new(root).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file() {
            files.push((
                entry.path().to_path_buf(),
                entry.path().strip_prefix(root)?.to_path_buf(),
            ));
        }
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;
    use object_store::memory::InMemory;
    use tempfile::TempDir;

    fn syncer() -> S3Sync {
        S3Sync {
            store: Arc::new(InMemory::new()),
            prefix: Path::from("home"),
        }
    }

    #[tokio::test]
    async fn verifies_bucket_writes_without_leaving_sentinel() {
        let sync = syncer();
        sync.verify_write().await.expect("verify bucket write");
        let objects = sync
            .store
            .list(None)
            .try_collect::<Vec<_>>()
            .await
            .expect("list bucket");
        assert!(objects.is_empty());
    }

    #[tokio::test]
    async fn round_trips_and_removes_stale_objects() {
        let sync = syncer();
        let source = TempDir::new().expect("create source");
        tokio::fs::create_dir(source.path().join("nested"))
            .await
            .expect("create directory");
        tokio::fs::write(source.path().join("nested/file.txt"), b"content")
            .await
            .expect("write source");
        sync.store
            .put(&Path::from("home/stale.txt"), b"stale".to_vec().into())
            .await
            .expect("write stale object");

        sync.sync_up(source.path()).await.expect("sync up");
        assert!(
            sync.store
                .head(&Path::from("home/stale.txt"))
                .await
                .is_err()
        );

        let destination = TempDir::new().expect("create destination");
        sync.sync_down(destination.path()).await.expect("sync down");
        let content = tokio::fs::read(destination.path().join("nested/file.txt"))
            .await
            .expect("read destination");
        assert_eq!(content, b"content");
    }
}
