# Testing and project hygiene

This repository uses several checks. Each check covers a different failure
mode. Run the fast checks while you work. Run the full VM test before a release
or when you change the container or backup path.

Commands that start with `nix` require Nix to be installed and available on
`PATH`. Do not assume that every developer or CI environment has Nix. If Nix
is not available, run the Cargo and Docker-based checks described below and
skip the Nix-only checks.

## Rust checks

Run the Rust unit and integration tests with Cargo:

```console
cargo test --locked
```

Run Clippy for every target and treat warnings as errors:

```console
cargo clippy --all-targets --locked -- -D warnings
```

The crate also forbids unsafe Rust and denies the `all` and `pedantic` Clippy
lint groups. The Nix package runs the test suite during its normal check phase.
The flake has a separate `cargo-clippy` check, so `nix flake check` covers the
same strict Clippy policy in a pinned environment.

Format Rust code with the repository formatter rather than with an ad hoc
version of `rustfmt`.

## Formatting and static checks

If `nix` is on `PATH`, enter the development shell and run:

```console
nix develop
nix fmt
```

If Nix is not available, use the Rust and shell tools installed on the host,
or use the Docker-based development path in [`README.md`](README.md). The
Nix formatter and its full set of static checks are not available without Nix.

The formatter is `treefmt`. It runs the configured formatters and linters for
Nix, Rust, shell, TOML, Markdown, and workflow files. The configured tools
include:

- `nixfmt` for Nix;
- `rustfmt` for Rust;
- `shfmt` and `shellcheck` for shell files;
- `actionlint` for GitHub Actions workflows;
- `deadnix` and `statix` for Nix hygiene;
- `taplo` for TOML;
- `prettier` for supported prose and data files.

Check formatting without changing files when needed:

```console
nix fmt -- --fail-on-change
```

The exact file set and formatter options live in
[`nix/flake/dev-partition.nix`](nix/flake/dev-partition.nix). The challenge
fixture `INSTRUCTIONS.md` is excluded from formatting.

## Flake checks

If `nix` is on `PATH`, run the authoritative check set with:

```console
nix flake check --print-build-logs
```

This is a Nix-only check. Do not require it from environments that do not
have Nix.

This evaluates and builds the checks in the development partition. They cover
more than compilation:

- the Rust package and strict Clippy check;
- the OCI image, root filesystem, and `systemd-nspawn` application;
- Compose file rendering;
- shell shebangs;
- the SourceHut build manifest;
- image exercise and publish scripts;
- Docker daemon cleanup behavior.

The pre-commit setup runs `treefmt`, checks for large added files, and checks
for merge-conflict markers. A pre-push hook runs the same `nix flake check`
command. Install the hooks by entering `nix develop`.

GitHub Actions runs `nix flake check --print-build-logs`. SourceHut runs the
same check, builds the OCI archive, and handles the image publish step for the
main branch.

## Service smoke test

Start a service instance, then run:

```console
./scripts/exercise-image.sh
```

The script uses gRPC reflection and health checks, writes and reads a file,
and executes a command. It checks response contents and exits on the first
failed command. `nix run .#exercise-image` provides the same script as a Nix
application.

## NixOS VM integration test

If `nix` is on `PATH`, build and run the complete VM test with:

```console
nix build .#nixos-vm-test -L
```

This test requires Nix and Linux virtualization support. It is not a required
local check for a host without Nix.

The test creates two NixOS nodes:

- `machine` runs Docker, Compose, the sandbox image, and the gRPC checks;
- `storage` runs SeaweedFS as an S3-compatible restic backend.

The test checks container startup, service discovery, health, path
confinement, command errors, command timeouts, missing executables, process
isolation, symbolic-link escapes, and transient files. It also runs the three
acceptance scripts through the RPC service:

- `csv_transform.py` must print `wrote summary.csv`;
- `linked_list.py` must print `OK` to standard error;
- `ocr_demo.py` must print `OCR round trip OK`.

Each case must return exit code zero and produce its expected output. The test
then stops and starts the service and checks that restic restores files,
empty directories, links, modes, timestamps, special entries, and changed
file content. It also checks that a small change does not create an excessive
restic data delta.

The VM test is an explicit package, not a flake check. This keeps ordinary CI
from building the expensive VM. Run it explicitly when changes affect the
runtime image, Compose setup, RPC behavior, process isolation, or backups.

## A useful local sequence

For a Rust-only change, use:

```console
cargo test --locked
cargo clippy --all-targets --locked -- -D warnings
```

If `nix` is on `PATH`, also run:

```console
nix fmt -- --check
```

For a container or service change, use the same commands, then run the smoke
test. If Nix is available, also run the NixOS VM test and finish with
`nix flake check --print-build-logs`.
