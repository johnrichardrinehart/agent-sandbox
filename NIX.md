# Why this repository uses Nix

Nix is the build and development system for this repository. The root flake
builds the service, runtime files, container image, root filesystem, checks,
and development shell. The lock files pin the flake inputs.

## Benefits

### Repeatable tools and builds

The flake selects the Rust compiler, Cargo, Protobuf compiler, formatters,
linters, container tools, and test tools. A developer and CI use the same
versions instead of depending on the host distribution.

Cargo dependencies are also built from `Cargo.lock`. The Nix Rust package uses
locked dependencies and the Clippy package runs Cargo in locked, offline mode.
This makes dependency changes visible and prevents an accidental network fetch
from changing a check.

### One description of the runtime

Nix builds the Rust service and assembles the same runtime inputs used by the
OCI image. That runtime includes Bubblewrap, restic, certificates, Tesseract,
and the Python environment. The image declares the non-root user, home directory, working directory, entrypoint, and port in the build description.

The same outputs can also run as an ephemeral `systemd-nspawn` container. This
reduces the gap between a local build, the image, and a direct runtime test.

### Strong checks

The flake makes build products and policy checks first-class outputs. It checks
Rust, Clippy, formatters, shell scripts, Compose files, CI metadata, image
scripts, and Docker daemon cleanup. The NixOS VM test uses a real NixOS
network with a Docker service and an S3-compatible storage node. It tests the
assembled image and the backup path, not only individual Rust functions.

### Isolated development tools

The development partition keeps authoring tools out of the consumer package
and image input graph. `nix develop` supplies the tools needed for formatting,
linting, testing, Compose work, and gRPC calls without asking each developer
to install matching host packages.

### Multiple supported host paths

Nix is the primary path, but it is not required to run the project. The
compatibility Dockerfile uses a pinned `nixos/nix` image to build the locked
flake. Users without Nix can use Docker Compose and the source smoke test.

## Costs and trade-offs

### First builds take time

The first `nix develop`, package build, image build, or VM test may download and
build a large dependency closure. Rust crates, Python packages, OCR data,
container layers, and NixOS system packages all add work. The VM test also
builds a kernel and starts virtual machines. Use binary caches when available,
and expect a cold VM build to take much longer than a unit test.

Later builds are faster because Nix reuses store paths and unchanged build
outputs. A source or lock-file change can still invalidate part of the closure.

### Disk use can be high

Nix keeps immutable versions of inputs and outputs. Different compiler,
package, or flake revisions can remain in `/nix/store` until garbage
collection. Container layers and VM outputs add more data. Developers must
manage the Nix store with their normal system policy.

### Nix has a learning cost

The flake separates consumer outputs from development inputs and uses a
partition for authoring tools. This keeps the design clean, but it is less
familiar than a Makefile or a host package list. The useful entry points are:

```console
nix develop
nix fmt
nix flake check --print-build-logs
nix build .#agent-sandbox
nix build .#agent-image
nix build .#nixos-vm-test -L
```

### Some operations need host integration

The development shell can start a worktree-local Docker daemon. Depending on
the host, this needs wheel membership and `sudo` authorization. The
`systemd-nspawn` application also needs `sudo`. These operations are isolated
from the package build, but they are not fully unprivileged host operations.

Nix itself is strongest on Linux for this project. The flake declares
Linux systems because the service uses Linux containers, Bubblewrap, Docker,
and NixOS VM tests.

### Reproducibility is not absolute

The flake and lock files pin Nix inputs, but builds still depend on the target
system, available binary caches, network access to fetch uncached sources, and
kernel features for container and VM tests. External services used at runtime,
such as an S3 endpoint or a container registry, remain outside the Nix build.

The repository therefore keeps a Docker Compose path and documents runtime
limits in [`CAVEATS.md`](CAVEATS.md). Nix improves repeatability and reviewable
builds; it does not remove the need to test the real host and service
boundaries.
