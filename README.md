# Agent sandbox

Agent sandbox is a Nix-built container service for running coding-agent workloads as an unprivileged user. This bootstrap provides the Rust service package, OCI image, rootless Podman environment, Docker Compose compatibility, and an ephemeral `systemd-nspawn` runner.

The service currently exposes `GET /healthz` on port 8080. The filesystem and command RPC planes described in [INSTRUCTIONS.md](INSTRUCTIONS.md) are the next implementation milestone.

## Set up

Install Nix with flakes enabled. Enter the development environment:

```console
nix develop
```

The first shell activation after each reboot asks for wheel authorization. It installs a cgroup delegation drop-in under `/run`, then starts a rootless, Docker-compatible Podman API as the transient `agent-sandbox-podman.service` user unit. The service lasts for the user session; neither the drop-in nor its marker survives a reboot. Set `AGENT_SANDBOX_SKIP_PODMAN_SERVICE=1` on hosts where service startup is not wanted.

With nix-direnv installed, `direnv allow` activates the same shell when entering the repository. The shell includes Cargo, Clippy, rustfmt, Podman, and podman-compose and exports `DOCKER_HOST` and `DOCKER_SOCK` for the rootless Podman socket.

## Build and check

```console
nix fmt
nix flake check --print-build-logs
nix build .#agent-sandbox
nix build .#agent-image
```

The root flake follows the consumer-clean structure from `nix-project-template`: package and image definitions live under `nix/flake/`, while formatters, hooks, and shell tools are isolated in `dev/`.

## Run containers

Load the Nix-built OCI archive into Podman:

```console
podman load < "$(nix build --no-link --print-out-paths .#agent-image)"
podman run --rm --publish 8080:8080 ghcr.io/johnrichardrinehart/agent-sandbox:latest
```

The compatibility Dockerfile and Compose definition run through rootless Podman:

```console
podman-compose up --build
podman-compose down
```

Both images run as `sandbox-manager`, use `/home/user` as the home and working directory, preinstall every library listed in `requirements.txt`, and start `agent-sandbox` as their entrypoint. Compose references `ghcr.io/johnrichardrinehart/agent-sandbox:latest`; `--build` replaces it locally with the compatibility Dockerfile build.

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
