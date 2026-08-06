# Agent sandbox

Agent sandbox is a Nix-built container service for running coding-agent workloads as an unprivileged user. This bootstrap provides the Rust service package, OCI image, rootless Podman environment, Docker Compose compatibility, and an ephemeral `systemd-nspawn` runner.

The service exposes the versioned API in [`proto/v0`](proto/v0), gRPC reflection, and the standard gRPC health service on port 8080. Filesystem calls read and write small files under `/home/user`. Command calls start a fresh process and return its standard output, standard error, and exit code. The service rejects paths that escape `/home/user`, including symlink escapes.

## Set up

Install Nix with flakes enabled. Enter the development environment:

```console
nix develop
```

The shell provides two separate container runtimes. `podman` runs rootless without setup or authorization. The `docker` client connects to a worktree-local Docker daemon started directly by the shell, not by a systemd unit. Starting that rootful daemon asks for wheel authorization. The sanitized worktree directory name identifies its socket, process files, network bridge, and storage under `/run/user/$UID`; for example, `main` uses `agent-sandbox-docker-main`. Stable, readable names let users find stale resources and let the next activation reap state left by an interrupted shell.

With nix-direnv installed, `direnv allow` activates the same environment when entering the repository. Leaving the worktree or closing its shell stops the Docker daemon and removes its runtime resources. A new activation for the same worktree replaces any stale daemon before exporting `DOCKER_HOST` and `DOCKER_SOCK`. Set `AGENT_SANDBOX_SKIP_DOCKER_DAEMON=1` when only rootless Podman is needed.

## Build and check

```console
nix fmt
nix flake check --print-build-logs
nix build .#agent-sandbox
nix build .#agent-image
```

Run the Docker-in-NixOS integration test explicitly:

```console
nix build .#nixos-vm-test -L
```

The VM test uses a two-node cluster. The `machine` node runs `docker.service` and the single Compose container. The separate `storage` node runs the SeaweedFS S3 service. The test replaces the container and checks that restic restores files, empty directories, links, modes, timestamps, and special entries. It also checks chunk reuse after a small file change. Host-side `grpcurl` calls test file access, path confinement, command failures, and all three acceptance scripts.

The root flake follows the consumer-clean structure from `nix-project-template`: package and image definitions live under `nix/flake/`, while formatters, hooks, and shell tools are isolated in `dev/`.

## Run containers

Load the Nix-built OCI archive into either runtime:

```console
podman load < "$(nix build --no-link --print-out-paths .#agent-image)"
podman run --rm --publish 8080:8080 ghcr.io/johnrichardrinehart/agent-sandbox:latest

# Or use the shell's ephemeral Docker daemon.
docker load < "$(nix build --no-link --print-out-paths .#agent-image)"
docker run --rm --publish 8080:8080 ghcr.io/johnrichardrinehart/agent-sandbox:latest
```

The compatibility Dockerfile and Compose definition run through rootless Podman:

```console
podman-compose up --build
podman-compose down
```

Both images run as `sandbox-manager`, use `/home/user` as the home and working directory, preinstall the Python libraries declared in `pyproject.toml`, and start `agent-sandbox` as their entrypoint. The single-stage compatibility Dockerfile uses the pinned `nixos/nix:2.35.1` base and the locked flake to build the same Nix runtime package set as the OCI image; it does not use a Python base, apt, pip, or uv. `uv.lock` pins the separate Python project environment. Compose references `ghcr.io/johnrichardrinehart/agent-sandbox:latest`; `--build` replaces it locally with the compatibility Dockerfile build.

Exercise a running gRPC image with the packaged smoke test:

```console
nix run .#exercise-image
```

The source script provides the same zero-setup behavior:

```console
./scripts/exercise-image.sh
```

The script uses a `nix-shell` shebang to provide Bash and `grpcurl` when executed on a Nix system. Without Nix, install Bash and `grpcurl`, then run `bash scripts/exercise-image.sh`; the `nix-shell` directives are ordinary shell comments in that mode. The script checks reflection and both health APIs, then writes and reads a fixture and runs a Python command through the control planes. Its optional settings are:

| Variable                | Default          | Purpose                                                                              |
| ----------------------- | ---------------- | ------------------------------------------------------------------------------------ |
| `AGENT_SANDBOX_ADDRESS` | `127.0.0.1:8080` | Select another gRPC host and port.                                                   |
| `GRPCURL_FLAGS`         | `-plaintext`     | Supply whitespace-separated `grpcurl` transport options, such as `-cacert ./ca.pem`. |

The service itself listens on `0.0.0.0:8080` by default. Set `AGENT_SANDBOX_LISTEN` when starting the binary or container to change its bind address. The development shell chooses a project-local Docker socket and exports `DOCKER_HOST` and `DOCKER_SOCK`; normal Docker commands need no socket options. Set `AGENT_SANDBOX_SKIP_DOCKER_DAEMON=1` before entering the shell when using only Podman or an independently managed runtime.

## Call the service

Reflection lets `grpcurl` call the service without local descriptor files:

```console
grpcurl -plaintext 127.0.0.1:8080 list sandbox.v0.FilesystemService
grpcurl -plaintext -d '{"path":"notes.txt","content":"aGVsbG8="}' \
  127.0.0.1:8080 sandbox.v0.FilesystemService/WriteFile
grpcurl -plaintext -d '{"argv":["python","-c","print(6 * 7)"]}' \
  127.0.0.1:8080 sandbox.v0.CommandService/ExecuteCommand
```

Protocol Buffer `bytes` fields use base64 in JSON. `ExecuteCommand.argv` does not use a shell. Specify a shell in `argv` when you need shell syntax. The optional working directory is relative to `/home/user`. Each command gets a private process namespace and temporary file system. Only files in `/home/user` persist between calls. Command timeouts default to 30 seconds and have a five-minute maximum. A missing program returns a nonzero exit code. A timeout returns exit code 124.

## Configure restic backups

Restic persistence is mandatory. The container runs restic as `sandbox-manager`. Before it accepts requests, it initializes or opens the repository, writes and removes a sentinel snapshot, and restores the latest sandbox snapshot. The service exits if these operations fail. The Compose restart policy restarts the failed container. The service takes snapshots at set intervals and after a clean shutdown. Restic stores the directory tree directly and uploads only new content chunks and metadata.

These variables configure backups:

- `RESTIC_REPOSITORY`: required repository URL, such as `s3:https://s3.example.com/agent-sandbox/home`. Compose defaults to `s3:http://host.docker.internal:9000/agent-sandbox/home`.
- `RESTIC_PASSWORD`, `RESTIC_PASSWORD_FILE`, or `RESTIC_PASSWORD_COMMAND`: optional repository encryption secret. If none is set, the service uses the known value `agent-sandbox`.
- `AGENT_SANDBOX_BACKUP_INTERVAL_SECONDS`: interval between snapshots. The default is 300 seconds.
- `AGENT_SANDBOX_BACKUP_HOST`: stable restic host name. The default is `agent-sandbox`.
- `RESTIC_CACHE_DIR`: optional cache path. The service uses `/tmp/restic-cache` by default so that it does not back up its cache.
- Standard `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_DEFAULT_REGION` variables configure S3 access.

Restic preserves regular files, empty directories, symbolic and hard links, permission bits, access and modification times, and supported special entries. It also records supported extended attributes. The unprivileged process cannot restore metadata that requires extra privileges. Linux does not let a process set inode change time, so each restored inode has a new `ctime`. See [CAVEATS.md](CAVEATS.md) for the filesystem and repository limits.

Compose passes these variables into its single container. A plain-HTTP S3-compatible service can be selected with a repository URL that starts with `s3:http://`. Compose uses [`seccomp.json`](seccomp.json), which is based on the Moby default profile at commit `f9bc03ec19b2dc4c091449b08e88f85c0caa9f0b`. The profile adds only the namespace, mount, and root-switch system calls that Bubblewrap needs. Compose also drops all container capabilities. See [CAVEATS.md](CAVEATS.md) for the remaining kernel risk.

## Continuous integration

GitHub Actions remains a check-only adapter. SourceHut runs the same `nix flake check --print-build-logs` contract from [`.build.yml`](.build.yml), builds the Nix OCI archive, and publishes only `refs/heads/main` to GHCR. Other SourceHut branches build and test the image but cannot publish it. The NixOS VM test is a package, not a flake check, so CI does not build or run it.

The SourceHut repository is the registered private mirror at `git.sr.ht/~fuzzybear3965/agent-sandbox`. A push containing `.build.yml` submits a build automatically. The manifest uses the existing SourceHut CI SSH-key secret to clone this private repository.

### GHCR secret

Create a GitHub personal access token (classic) for `johnrichardrinehart` at <https://github.com/settings/tokens/new?scopes=write:packages>. This URL avoids the GitHub token form's default addition of the broad `repo` scope. Keep only `write:packages`, which includes image download and upload; do not add `repo`, `workflow`, or `delete:packages`.

The SourceHut file secret declared in `.build.yml` is mounted at `~/.ghcr_pat`; its complete contents are the token. SourceHut runs tasks with shell tracing enabled, so the publishing app reads the file with tracing disabled and passes the token to `skopeo login` through standard input.

A main build publishes `ghcr.io/johnrichardrinehart/agent-sandbox:latest` and `0.0.n`, where `n` is the main commit count, then confirms that both tags have the same digest. GHCR makes a new personal package private by default. After its first publication, change the package visibility to public in its GitHub package settings so the documented Compose command can pull it without authentication.

## Run with systemd-nspawn

```console
nix run .#agent-systemd-nspawn
```

This command asks for wheel authorization and launches the Nix root filesystem through `systemd-nspawn` with an ephemeral overlay. It runs the service as `sandbox-manager`; changes vanish when the unit exits. Inspect the generated command without elevation with:

```console
nix run .#agent-systemd-nspawn -- --dry-run
```
