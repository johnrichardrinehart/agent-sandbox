use std::env;
use std::error::Error;
use std::path::PathBuf;

use sandbox::v0::{
    command_service_server::CommandServiceServer,
    filesystem_service_server::FilesystemServiceServer, health_service_server::HealthServiceServer,
};
use service::SandboxService;
use storage::S3Sync;
use tonic::transport::Server;
use tracing::{error, info};

mod service;
mod storage;

// Tonic generates this module; its output cannot follow this crate's stricter Clippy policy.
#[allow(clippy::pedantic)]
mod sandbox {
    pub mod v0 {
        tonic::include_proto!("sandbox.v0");
    }
}

const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("sandbox_descriptor");

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error + Send + Sync>> {
    tracing_subscriber::fmt().with_target(false).init();

    let address = env::var("AGENT_SANDBOX_LISTEN")
        .unwrap_or_else(|_| "0.0.0.0:8080".into())
        .parse()?;
    let root =
        PathBuf::from(env::var("AGENT_SANDBOX_HOME").unwrap_or_else(|_| "/home/user".into()));
    let storage = S3Sync::from_env()?;
    if let Some(storage) = &storage {
        storage.sync_down(&root).await?;
    }

    let service = SandboxService::new(&root)?;
    let filesystem = FilesystemServiceServer::new(service.clone());
    let command = CommandServiceServer::new(service.clone());
    let versioned_health = HealthServiceServer::new(service);
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

    info!(%address, root = %root.display(), "agent-sandbox gRPC service listening");
    Server::builder()
        .add_service(health)
        .add_service(reflection)
        .add_service(versioned_health)
        .add_service(filesystem)
        .add_service(command)
        .serve_with_shutdown(address, shutdown_signal(storage, root))
        .await?;

    Ok(())
}

async fn shutdown_signal(storage: Option<S3Sync>, root: PathBuf) {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("install SIGTERM handler");
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                if let Err(error) = result {
                    error!(%error, "failed to listen for Ctrl-C");
                }
            }
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    if let Err(error) = tokio::signal::ctrl_c().await {
        error!(%error, "failed to listen for shutdown signal");
    }

    info!("shutdown requested");
    if let Some(storage) = storage
        && let Err(error) = storage.sync_up(&root).await
    {
        error!(%error, "failed to synchronize sandbox to S3 during shutdown");
    }
}
