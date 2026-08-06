# Agent sandbox

Agent sandbox is a container service that runs coding-agent workloads as an unprivileged user. It provides a Rust service, a versioned gRPC API, an OCI image, Docker and Podman support, and restic backups.

The service listens on port 8080. Filesystem calls read and write small files under `/home/user`. Command calls start a fresh process and return its standard output, standard error, and exit code. The service rejects paths that escape `/home/user`, including symbolic link escapes.

## Getting started

Choose the Nix or non-Nix path. The sections after this one apply to both paths.

### Nix users

Install Nix with flakes enabled. Enter the development environment:

```console
nix develop
```

The shell provides two container runtimes:

- `podman` runs rootless without setup or authorization.
- `docker` connects to a worktree-local daemon. Starting this rootful daemon asks for wheel authorization.

All active shells in one worktree share the Docker daemon. Runtime files are under `/run/user/$UID`, and image storage is under `/var/tmp`. The daemon stops after the last registered shell exits or leaves the worktree. A new activation reuses a healthy daemon and replaces a stale daemon.

With nix-direnv installed, `direnv allow` enters the same environment. Set `AGENT_SANDBOX_SKIP_DOCKER_DAEMON=1` before activation when you need only Podman or another Docker daemon.

Build and check the project:

```console
nix fmt
nix flake check --print-build-logs
nix build .#agent-sandbox
nix build .#agent-image
```

Load and run the Nix-built OCI archive with Podman:

```console
podman load < "$(nix build --no-link --print-out-paths .#agent-image)"
podman run --rm --publish 8080:8080 ghcr.io/johnrichardrinehart/agent-sandbox:latest
```

Use the development shell's Docker daemon instead:

```console
docker load < "$(nix build --no-link --print-out-paths .#agent-image)"
docker run --rm --publish 8080:8080 ghcr.io/johnrichardrinehart/agent-sandbox:latest
```

Run the packaged smoke test after the service starts:

```console
nix run .#exercise-image
```

Run the service in an ephemeral `systemd-nspawn` container:

```console
nix run .#agent-systemd-nspawn
```

This command asks for wheel authorization. It uses an ephemeral overlay and runs the service as `sandbox-manager`. Inspect the generated command without elevation:

```console
nix run .#agent-systemd-nspawn -- --dry-run
```

The root flake follows the consumer-clean structure from `nix-project-template`. Package and image definitions are under `nix/flake/`. Formatters, hooks, and shell tools are isolated in `dev/`.

### Users without Nix

You do not need Nix on the host. Install Docker with the Compose plug-in. The compatibility Dockerfile uses a pinned `nixos/nix` base image and the locked flake inside the build.

Start the service with a local MinIO store:

```console
docker compose -f ./docker-compose-dev.yaml up --build
```

Compose waits for MinIO, creates the S3 bucket, and starts the service. Stop the stack:

```console
docker compose -f ./docker-compose-dev.yaml down
```

The MinIO volume keeps backups after `down`. Delete the backups with:

```console
docker compose -f ./docker-compose-dev.yaml down --volumes
```

To use an existing restic repository, set its connection variables and use the standard Compose file:

```console
export RESTIC_REPOSITORY=s3:https://s3.example.com/agent-sandbox/home
export RESTIC_PASSWORD='replace-this-value'
export AWS_ACCESS_KEY_ID='replace-this-value'
export AWS_SECRET_ACCESS_KEY='replace-this-value'
docker compose up
```

The standard Compose file pulls `ghcr.io/johnrichardrinehart/agent-sandbox:latest`. Add `--build` to build the compatibility image locally. Podman users can run the same file with `podman-compose up --build` and stop it with `podman-compose down`.

Install Bash and `grpcurl`, then run the source smoke test after the service starts:

```console
bash ./scripts/exercise-image.sh
```

## Common usage

### Container behavior

The Nix and compatibility images have the same runtime contract. They:

- Run as `sandbox-manager`.
- Use `/home/user` as the home and working directory.
- Include the Python libraries declared in `pyproject.toml`.
- Start `agent-sandbox` as the entrypoint.

The compatibility Dockerfile does not use a Python base image, `apt`, `pip`, or `uv`. The separate `uv.lock` file pins the Python project environment. The development Compose file tags its local build as `agent-sandbox:dev`.

The service listens on `0.0.0.0:8080` by default. Set `AGENT_SANDBOX_LISTEN` to use a different address.

Each command gets a private process namespace and temporary file system. Only files in `/home/user` persist between calls. Command timeouts default to 30 seconds and have a five-minute maximum. A missing program returns a nonzero exit code. A timeout returns exit code 124.

### Test a running service

The source smoke test works with and without Nix:

```console
./scripts/exercise-image.sh
```

On a Nix system, the `nix-shell` shebang provides Bash and `grpcurl`. Without Nix, run the script through an installed Bash as shown in the non-Nix instructions. The script checks reflection and the health APIs, writes and reads a fixture, and runs a Python command.

These variables configure the smoke test:

| Variable                | Default          | Purpose                                                                              |
| ----------------------- | ---------------- | ------------------------------------------------------------------------------------ |
| `AGENT_SANDBOX_ADDRESS` | `127.0.0.1:8080` | Select another gRPC host and port.                                                   |
| `GRPCURL_FLAGS`         | `-plaintext`     | Supply whitespace-separated `grpcurl` transport options, such as `-cacert ./ca.pem`. |

### Call the service

Reflection lets `grpcurl` call the service without local descriptor files:

```console
grpcurl -plaintext 127.0.0.1:8080 list sandbox.v0.FilesystemService
grpcurl -plaintext -d '{"path":"notes.txt","content":"aGVsbG8="}' \
  127.0.0.1:8080 sandbox.v0.FilesystemService/WriteFile
grpcurl -plaintext -d '{"argv":["python","-c","print(6 * 7)"]}' \
  127.0.0.1:8080 sandbox.v0.CommandService/ExecuteCommand
```

Protocol Buffer `bytes` fields use base64 in JSON. `ExecuteCommand.argv` does not use a shell. Add a shell to `argv` when you need shell syntax. The optional working directory is relative to `/home/user`.

### Configure restic backups

Restic persistence is mandatory. Before the service accepts requests, it:

1. Initializes or opens the repository.
2. Writes and removes a sentinel snapshot.
3. Restores the latest sandbox snapshot.

The service exits if an operation fails. The Compose restart policy restarts the failed container. The service takes snapshots at set intervals and after a clean shutdown. Restic uploads only new content chunks and metadata.

These variables configure backups:

- `RESTIC_REPOSITORY`: Required repository URL, such as `s3:https://s3.example.com/agent-sandbox/home`. Standard Compose defaults to `s3:http://host.docker.internal:9000/agent-sandbox/home`.
- `RESTIC_PASSWORD`, `RESTIC_PASSWORD_FILE`, or `RESTIC_PASSWORD_COMMAND`: Optional repository encryption secret. If none is set, the service uses the known value `agent-sandbox`.
- `AGENT_SANDBOX_BACKUP_INTERVAL_SECONDS`: Interval between snapshots. The default is 300 seconds.
- `AGENT_SANDBOX_BACKUP_HOST`: Stable restic host name. The default is `agent-sandbox`.
- `RESTIC_CACHE_DIR`: Optional cache path. The service uses `/tmp/restic-cache` by default so that it does not back up its cache.
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION`: S3 access settings.

Restic preserves regular files, empty directories, symbolic and hard links, permission bits, access and modification times, and supported special entries. It also records supported extended attributes. The unprivileged process cannot restore metadata that needs more privileges. Linux does not let a process set inode change time, so each restored inode has a new `ctime`.

A plain-HTTP S3-compatible service uses a repository URL that starts with `s3:http://`. Compose passes the backup variables to the container.

Compose uses [`seccomp.json`](seccomp.json), which is based on the Moby default profile at commit `f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b`. The profile adds only the namespace, mount, and root-switch system calls that Bubblewrap needs. Compose also drops all container capabilities. See [CAVEATS.md](CAVEATS.md) for filesystem, repository, and kernel limits.

## Project checks and continuous integration

Run the Docker-in-NixOS integration test explicitly:

```console
nix build .#nixos-vm-test -L
```

The test uses two nodes. The `machine` node runs Docker and the Compose container. The `storage` node runs the SeaweedFS S3 service. The test replaces the container and checks that restic restores files, empty directories, links, modes, timestamps, and special entries. It also checks chunk reuse after a small file change. Host-side `grpcurl` calls test file access, path confinement, command failures, and all three acceptance scripts.

GitHub Actions is a check-only adapter. SourceHut runs `nix flake check --print-build-logs`, builds the Nix OCI archive, and publishes only `refs/heads/main` to GHCR. Other SourceHut branches build and test the image but cannot publish it. CI does not run the NixOS VM test.

The SourceHut repository is the registered private mirror at `git.sr.ht/~fuzzybear3965/agent-sandbox`. A push that contains `.build.yml` submits a build automatically. The manifest uses the existing SourceHut CI SSH-key secret to clone this private repository.

### GHCR secret

Create a GitHub personal access token (classic) for `johnrichardrinehart` at <https://github.com/settings/tokens/new?scopes=write:packages>. Keep only `write:packages`. Do not add `repo`, `workflow`, or `delete:packages`.

The SourceHut file secret in `.build.yml` is mounted at `~/.ghcr_pat`. Its complete contents are the token. SourceHut runs tasks with shell tracing enabled, so the publishing app reads the file with tracing disabled and passes the token to `skopeo login` through standard input.

A main build publishes `ghcr.io/johnrichardrinehart/agent-sandbox:latest` and `0.0.n`, where `n` is the main commit count. It then confirms that both tags have the same digest. GHCR makes a new personal package private by default. After the first publication, make the package public in its GitHub package settings.
