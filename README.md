# Agent sandbox

Agent sandbox is a Nix-built container service for running coding-agent workloads as an unprivileged user. This bootstrap provides the Rust service package, OCI image, rootless Podman environment, Docker Compose compatibility, and an ephemeral `systemd-nspawn` runner.

The service currently exposes `GET /healthz` on port 8080. The filesystem and command RPC planes described in [INSTRUCTIONS.md](INSTRUCTIONS.md) are the next implementation milestone.

## Set up

Install Nix with flakes enabled. Enter the development environment:

```console
nix develop
```

The shell provides two separate container runtimes. `podman` runs rootless without setup or authorization. The `docker` client connects to a project-local Docker daemon started directly by the shell, not by a systemd unit. Starting that rootful daemon asks for wheel authorization. Its socket, process files, and storage live under `/run/user/$UID/agent-sandbox-docker-$PID` and are removed when the development shell exits.

With nix-direnv installed, `direnv allow` activates the same environment when entering the repository. Each interactive shell gets its own Docker daemon; leaving the repository or closing that shell stops it. The shell exports `DOCKER_HOST` and `DOCKER_SOCK` for its Docker socket. Set `AGENT_SANDBOX_SKIP_DOCKER_DAEMON=1` when only rootless Podman is needed.

## Build and check

```console
nix fmt
nix flake check --print-build-logs
nix build .#agent-sandbox
nix build .#agent-image
```

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

## Continuous integration

GitHub Actions remains a check-only adapter. SourceHut runs the same `nix flake check --print-build-logs` contract from [`.build.yml`](.build.yml), builds the Nix OCI archive, and publishes only `refs/heads/main` to GHCR. Other SourceHut branches build and test the image but cannot publish it.

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
