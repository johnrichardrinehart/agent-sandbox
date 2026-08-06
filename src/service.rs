use std::path::{Component, Path, PathBuf};
use std::{fs, io};

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

#[derive(Clone)]
pub(crate) struct SandboxService {
    root: PathBuf,
}

impl SandboxService {
    pub(crate) fn new(root: impl AsRef<Path>) -> io::Result<Self> {
        fs::create_dir_all(root.as_ref())?;
        Ok(Self {
            root: fs::canonicalize(root)?,
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

        if candidate.exists() {
            return self.ensure_scoped(fs::canonicalize(candidate)?);
        }

        let parent = candidate
            .parent()
            .ok_or(SandboxPathError::Invalid("path has no parent"))?;
        if create_parents {
            fs::create_dir_all(parent)?;
        }
        let canonical_parent = fs::canonicalize(parent)?;
        let canonical_parent = self.ensure_scoped(canonical_parent)?;
        let filename = candidate
            .file_name()
            .ok_or(SandboxPathError::Invalid("path must name a file"))?;
        Ok(canonical_parent.join(filename))
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
        fs::write(&path, &request.content).map_err(|error| io_status(&error))?;
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
        let mut command = Command::new(program);
        command
            .args(arguments)
            .current_dir(working_directory)
            .envs(request.environment)
            .kill_on_drop(true);

        let output = timeout(Duration::from_millis(timeout_ms), command.output())
            .await
            .map_err(|_| Status::deadline_exceeded("command timed out"))?
            .map_err(|error| Status::internal(format!("failed to execute command: {error}")))?;

        let exit_code = output.status.code().unwrap_or(-1);
        info!(program, exit_code, "command completed");
        Ok(Response::new(ExecuteCommandResponse {
            stdout: output.stdout,
            stderr: output.stderr,
            exit_code,
        }))
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
        let service = SandboxService::new(root.path()).expect("create service");
        (root, service)
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

    #[tokio::test]
    async fn executes_each_command_in_a_fresh_process() {
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
}
