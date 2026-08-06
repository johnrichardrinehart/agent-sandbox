use std::env;

use sandbox::v0::{
    ExecuteCommandRequest, ExecuteCommandResponse, HealthCheckRequest, HealthCheckResponse,
    ReadFileRequest, ReadFileResponse, ServingStatus, WriteFileRequest, WriteFileResponse,
    command_service_server::{CommandService, CommandServiceServer},
    filesystem_service_server::{FilesystemService, FilesystemServiceServer},
    health_service_server::{HealthService, HealthServiceServer},
};
use tonic::{Request, Response, Status, transport::Server};

// Tonic generates this module; its output cannot follow this crate's stricter Clippy policy.
#[allow(clippy::pedantic)]
mod sandbox {
    pub mod v0 {
        tonic::include_proto!("sandbox.v0");
    }
}

const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("sandbox_descriptor");

#[derive(Default)]
struct SandboxService;

#[tonic::async_trait]
impl FilesystemService for SandboxService {
    async fn write_file(
        &self,
        _request: Request<WriteFileRequest>,
    ) -> Result<Response<WriteFileResponse>, Status> {
        Err(Status::unimplemented("WriteFile is not implemented yet"))
    }

    async fn read_file(
        &self,
        _request: Request<ReadFileRequest>,
    ) -> Result<Response<ReadFileResponse>, Status> {
        Err(Status::unimplemented("ReadFile is not implemented yet"))
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
        _request: Request<ExecuteCommandRequest>,
    ) -> Result<Response<ExecuteCommandResponse>, Status> {
        Err(Status::unimplemented(
            "ExecuteCommand is not implemented yet",
        ))
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let address = env::var("AGENT_SANDBOX_LISTEN")
        .unwrap_or_else(|_| "0.0.0.0:8080".into())
        .parse()?;

    let filesystem = FilesystemServiceServer::new(SandboxService);
    let command = CommandServiceServer::new(SandboxService);
    let versioned_health = HealthServiceServer::new(SandboxService);
    let (mut health_reporter, health) = tonic_health::server::health_reporter();
    health_reporter
        .set_serving::<FilesystemServiceServer<SandboxService>>()
        .await;
    health_reporter
        .set_serving::<CommandServiceServer<SandboxService>>()
        .await;
    health_reporter
        .set_serving::<HealthServiceServer<SandboxService>>()
        .await;

    let reflection = tonic_reflection::server::Builder::configure()
        .register_encoded_file_descriptor_set(FILE_DESCRIPTOR_SET)
        .register_encoded_file_descriptor_set(tonic_health::pb::FILE_DESCRIPTOR_SET)
        .build_v1()?;

    eprintln!("agent-sandbox gRPC service listening on {address}");
    Server::builder()
        .add_service(health)
        .add_service(reflection)
        .add_service(versioned_health)
        .add_service(filesystem)
        .add_service(command)
        .serve(address)
        .await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tonic::Code;

    #[tokio::test]
    async fn filesystem_handlers_are_explicit_stubs() {
        let service = SandboxService;
        let error = service
            .read_file(Request::new(ReadFileRequest {
                path: "fixture.txt".into(),
            }))
            .await
            .expect_err("stub must reject calls");

        assert_eq!(error.code(), Code::Unimplemented);
    }

    #[tokio::test]
    async fn command_handler_is_an_explicit_stub() {
        let service = SandboxService;
        let error = service
            .execute_command(Request::new(ExecuteCommandRequest {
                argv: vec!["true".into()],
                ..Default::default()
            }))
            .await
            .expect_err("stub must reject calls");

        assert_eq!(error.code(), Code::Unimplemented);
    }
}
