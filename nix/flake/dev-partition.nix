{ inputs, ... }:
{
  imports = [
    inputs.git-hooks.flakeModule
    inputs.treefmt-nix.flakeModule
  ];

  perSystem =
    {
      agentSandboxChecks,
      config,
      pkgs,
      ...
    }:
    let
      runDockerDaemon = pkgs.writeShellApplication {
        name = "agent-dockerd-runner";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.docker
          pkgs.iproute2
        ];
        text = ''
          owner_pid=$1
          watch_cwd=$2
          project_root=$3
          uid="''${SUDO_UID:?agent-dockerd-runner must run through sudo}"
          gid="''${SUDO_GID:?agent-dockerd-runner must run through sudo}"
          daemon_dir="/run/user/$uid/agent-sandbox-docker-$owner_pid"
          pidfile="$daemon_dir/dockerd.pid"
          bridge="asd-$owner_pid"
          bridge_octet=$((owner_pid % 200 + 20))
          bridge_address="10.254.$bridge_octet.1/24"
          bridge_cidr="10.254.$bridge_octet.0/24"

          cleanup() {
            if [[ -n "''${daemon_pid:-}" ]]; then
              kill "$daemon_pid" 2>/dev/null || true
              wait "$daemon_pid" 2>/dev/null || true
            fi
            ip link delete "$bridge" 2>/dev/null || true
            rm -rf "$daemon_dir"
          }
          trap cleanup EXIT INT TERM

          install -d -m 0750 -o root -g "$gid" "$daemon_dir"
          printf '%s\n' "$$" >"$daemon_dir/runner.pid"

          ip link add name "$bridge" type bridge
          ip address add "$bridge_address" dev "$bridge"
          ip link set "$bridge" up

          dockerd \
            --bridge "$bridge" \
            --fixed-cidr "$bridge_cidr" \
            --data-root "$daemon_dir/data" \
            --exec-root "$daemon_dir/exec" \
            --group "$gid" \
            --host "unix://$daemon_dir/docker.sock" \
            --pidfile "$pidfile" &
          daemon_pid=$!

          while kill -0 "$owner_pid" 2>/dev/null && kill -0 "$daemon_pid" 2>/dev/null; do
            if [[ "$watch_cwd" == 1 ]]; then
              owner_cwd=$(readlink -f "/proc/$owner_pid/cwd" 2>/dev/null || true)
              [[ "$owner_cwd" == "$project_root" || "$owner_cwd" == "$project_root/"* ]] || break
            fi
            sleep 1
          done
        '';
      };

      startDockerDaemon = pkgs.writeShellApplication {
        name = "agent-docker-daemon";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.docker-client
        ];
        text = ''
          owner_pid=$1
          watch_cwd=$2
          project_root=$3
          uid=$(id -u)
          daemon_dir="/run/user/$uid/agent-sandbox-docker-$owner_pid"
          socket="$daemon_dir/docker.sock"
          log="/run/user/$uid/agent-sandbox-dockerd-$owner_pid.log"
          docker_host="unix://$socket"

          [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || {
            echo 'Docker daemon owner PID must be a positive integer.' >&2
            exit 1
          }

          if [[ -S "$socket" ]] && docker --host "$docker_host" info >/dev/null 2>&1; then
            exit 0
          fi

          if [[ " $(id -Gn) " != *" wheel "* ]]; then
            echo 'The ephemeral Docker daemon requires membership in the wheel group.' >&2
            exit 1
          fi
          if ! command -v sudo >/dev/null; then
            echo 'The ephemeral Docker daemon requires the host sudo wrapper.' >&2
            exit 1
          fi

          echo 'Authorizing the ephemeral Docker daemon for this development shell.' >&2
          sudo -v

          if [[ -f "$daemon_dir/runner.pid" ]]; then
            sudo kill "$(<"$daemon_dir/runner.pid")" 2>/dev/null || true
            sleep 0.2
          fi
          sudo rm -rf "$daemon_dir"
          : >"$log"

          # The caller opens its user-owned log before sudo starts the runner.
          # shellcheck disable=SC2024
          sudo -b ${runDockerDaemon}/bin/agent-dockerd-runner \
            "$owner_pid" "$watch_cwd" "$project_root" \
            >"$log" 2>&1

          for _ in $(seq 1 100); do
            if [[ -S "$socket" ]] && docker --host "$docker_host" info >/dev/null 2>&1; then
              exit 0
            fi
            sleep 0.1
          done

          echo "Docker's socket did not become ready at $socket" >&2
          tail -n 20 "$log" >&2
          if [[ -f "$daemon_dir/runner.pid" ]]; then
            sudo kill "$(<"$daemon_dir/runner.pid")" 2>/dev/null || true
          fi
          exit 1
        '';
      };
    in
    {
      treefmt = {
        projectRootFile = "flake.nix";
        flakeCheck = false;
        programs = {
          actionlint.enable = true;
          deadnix.enable = true;
          nixfmt.enable = true;
          prettier.enable = true;
          rustfmt.enable = true;
          shellcheck.enable = true;
          shfmt.enable = true;
          statix.enable = true;
          taplo.enable = true;
        };
        settings.formatter = {
          # The challenge specification and acceptance scripts are fixtures.
          prettier.excludes = [ "INSTRUCTIONS.md" ];
          shellcheck.includes = [
            "*.sh"
            ".envrc"
          ];
          shfmt.includes = [
            "*.sh"
            ".envrc"
          ];
        };
      };

      pre-commit.settings.hooks = {
        treefmt.enable = true;
        check-added-large-files.enable = true;
        check-merge-conflicts.enable = true;

        flake-check-before-push = {
          enable = true;
          name = "authoritative Nix checks";
          entry = "${pkgs.nix}/bin/nix flake check --print-build-logs";
          always_run = true;
          pass_filenames = false;
          require_serial = true;
          stages = [ "pre-push" ];
        };
      };

      checks = {
        agent-sandbox = agentSandboxChecks.agentPackage;
        agent-image = agentSandboxChecks.agentImage;
        agent-rootfs = agentSandboxChecks.agentRootfs;
        agent-systemd-nspawn = agentSandboxChecks.nspawnApp;
        cargo-clippy = agentSandboxChecks.clippyCheck;
        compose = agentSandboxChecks.composeCheck;
        publish-image = agentSandboxChecks.publishImage;
        sourcehut-manifest = agentSandboxChecks.sourcehutManifestCheck;
      };

      devShells.default = pkgs.mkShell {
        packages = [
          startDockerDaemon
          pkgs.cargo
          pkgs.clippy
          pkgs.docker-client
          pkgs.nixd
          pkgs.podman
          pkgs.podman-compose
          pkgs.rustc
          pkgs.rustfmt
        ];
        shellHook = ''
          ${config.pre-commit.installationScript}
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          docker_owner_pid="''${AGENT_SANDBOX_DIRENV_OWNER_PID:-$$}"
          docker_watch_cwd="''${AGENT_SANDBOX_DIRENV_ACTIVE:-0}"
          docker_project_root="''${AGENT_SANDBOX_PROJECT_ROOT:-$PWD}"
          export DOCKER_SOCK="$XDG_RUNTIME_DIR/agent-sandbox-docker-$docker_owner_pid/docker.sock"
          export DOCKER_HOST="unix://$DOCKER_SOCK"

          if [[ -z "''${CI:-}" \
            && "''${AGENT_SANDBOX_DIRENV_ACTIVE:-}" != 1 \
            && "''${AGENT_SANDBOX_SKIP_DOCKER_DAEMON:-}" != 1 ]]; then
            agent-docker-daemon \
              "$docker_owner_pid" "$docker_watch_cwd" "$docker_project_root"
          fi
        '';
      };
    };
}
