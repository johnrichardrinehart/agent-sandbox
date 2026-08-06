use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let protos = [
        "proto/v0/command.proto",
        "proto/v0/filesystem.proto",
        "proto/v0/health.proto",
    ];
    let descriptor_path = PathBuf::from(env::var("OUT_DIR")?).join("sandbox_descriptor.bin");

    tonic_build::configure()
        .file_descriptor_set_path(descriptor_path)
        .compile_protos(&protos, &["proto"])?;

    for proto in protos {
        println!("cargo:rerun-if-changed={proto}");
    }

    Ok(())
}
