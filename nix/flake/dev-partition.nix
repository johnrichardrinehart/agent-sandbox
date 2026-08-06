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
          project_id=$4
          uid="''${SUDO_UID:?agent-dockerd-runner must run through sudo}"
          gid="''${SUDO_GID:?agent-dockerd-runner must run through sudo}"
          runtime_dir="/run/user/$uid"
          daemon_dir="$runtime_dir/agent-sandbox-docker-$project_id"
          pidfile="$daemon_dir/dockerd.pid"
          bridge="asd-''${project_id:0:11}"
          network_id=$(printf '%s' "$project_root" | cksum | cut -d ' ' -f1)
          bridge_second=$((64 + network_id % 64))
          bridge_third=$((network_id / 64 % 256))
          bridge_address="10.$bridge_second.$bridge_third.1/24"
          bridge_cidr="10.$bridge_second.$bridge_third.0/24"

          [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || exit 1
          [[ "$watch_cwd" == 0 || "$watch_cwd" == 1 ]] || exit 1
          [[ "$project_root" == /* && -d "$project_root" ]] || exit 1
          [[ "$project_id" =~ ^[A-Za-z0-9_.-]{1,40}$ ]] || exit 1
          [[ "$project_id" != . && "$project_id" != .. ]] || exit 1

          cleanup() {
            if [[ -n "''${daemon_pid:-}" ]]; then
              kill "$daemon_pid" 2>/dev/null || true
              wait "$daemon_pid" 2>/dev/null || true
            fi
            ip link delete "$bridge" 2>/dev/null || true
            rm -rf "$daemon_dir"
          }
          trap cleanup EXIT INT TERM

          if [[ -f "$daemon_dir/runner.pid" ]]; then
            previous_runner=$(<"$daemon_dir/runner.pid")
            previous_command=$(tr '\0' ' ' <"/proc/$previous_runner/cmdline" 2>/dev/null || true)
            if [[ "$previous_runner" =~ ^[1-9][0-9]*$ \
              && "$previous_command" == *agent-dockerd-runner*" $project_id"* ]]; then
              kill "$previous_runner" 2>/dev/null || true
              for _ in $(seq 1 50); do
                kill -0 "$previous_runner" 2>/dev/null || break
                sleep 0.1
              done
            fi
          fi

          if [[ -f "$pidfile" ]]; then
            previous_daemon=$(<"$pidfile")
            previous_command=$(tr '\0' ' ' <"/proc/$previous_daemon/cmdline" 2>/dev/null || true)
            if [[ "$previous_daemon" =~ ^[1-9][0-9]*$ \
              && "$previous_command" == *dockerd*"--data-root $daemon_dir/data"* ]]; then
              kill "$previous_daemon" 2>/dev/null || true
              for _ in $(seq 1 50); do
                kill -0 "$previous_daemon" 2>/dev/null || break
                sleep 0.1
              done
            fi
          fi

          ip link delete "$bridge" 2>/dev/null || true
          rm -rf "$daemon_dir"
          install -d -m 0750 -o root -g "$gid" "$daemon_dir"
          printf '%s\n' "$$" >"$daemon_dir/runner.pid"
          printf '%s\n' "$owner_pid" >"$daemon_dir/owner.pid"

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
          project_root=$(readlink -f "$3")
          project_name=$(basename "$project_root")
          project_id=$(printf '%s' "$project_name" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-40)
          [[ "$project_id" != . && "$project_id" != .. ]] || project_id=worktree
          uid=$(id -u)
          daemon_dir="/run/user/$uid/agent-sandbox-docker-$project_id"
          socket="$daemon_dir/docker.sock"
          log="/run/user/$uid/agent-sandbox-dockerd-$project_id.log"
          docker_host="unix://$socket"

          [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || {
            echo 'Docker daemon owner PID must be a positive integer.' >&2
            exit 1
          }
          [[ "$watch_cwd" == 0 || "$watch_cwd" == 1 ]] || {
            echo 'Docker daemon cwd monitoring must be 0 or 1.' >&2
            exit 1
          }
          [[ "$project_root" == /* && -d "$project_root" ]] || {
            echo 'Docker daemon project root must be an existing directory.' >&2
            exit 1
          }

          if [[ -S "$socket" \
            && -f "$daemon_dir/owner.pid" \
            && "$(<"$daemon_dir/owner.pid")" == "$owner_pid" ]] \
            && docker --host "$docker_host" info >/dev/null 2>&1; then
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

          sudo_arguments=()
          if [[ "$watch_cwd" == 1 ]]; then
            sudo_arguments+=(--non-interactive)
          else
            echo 'Authorizing the ephemeral Docker daemon for this development shell.' >&2
          fi
          sudo "''${sudo_arguments[@]}" -v

          : >"$log"

          # The runner serializes replacement and validates stale PIDs before
          # killing them. The caller opens its user-owned log before sudo.
          # shellcheck disable=SC2024
          sudo "''${sudo_arguments[@]}" -b ${runDockerDaemon}/bin/agent-dockerd-runner \
            "$owner_pid" "$watch_cwd" "$project_root" "$project_id" \
            >"$log" 2>&1

          for _ in $(seq 1 100); do
            if [[ -S "$socket" ]] && docker --host "$docker_host" info >/dev/null 2>&1; then
              exit 0
            fi
            sleep 0.1
          done

          echo "Docker's socket did not become ready at $socket" >&2
          tail -n 20 "$log" >&2
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
        docker-authorization = pkgs.runCommand "agent-sandbox-docker-authorization-check" { } ''
          grep --fixed-strings 'sudo_arguments+=(--non-interactive)' \
            ${startDockerDaemon}/bin/agent-docker-daemon >/dev/null
          grep --fixed-strings 'sudo --non-interactive -v' ${../../.envrc} >/dev/null
          touch "$out"
        '';
        exercise-image = agentSandboxChecks.exerciseImage;
        publish-image = agentSandboxChecks.publishImage;
        script-shebangs = agentSandboxChecks.scriptShebangCheck;
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
          docker_project_root=$(readlink -f "''${AGENT_SANDBOX_PROJECT_ROOT:-$PWD}")
          docker_project_name=$(basename "$docker_project_root")
          docker_project_id=$(printf '%s' "$docker_project_name" | tr -c 'A-Za-z0-9_.-' '-' | cut -c1-40)
          [[ "$docker_project_id" != . && "$docker_project_id" != .. ]] || docker_project_id=worktree
          export DOCKER_SOCK="$XDG_RUNTIME_DIR/agent-sandbox-docker-$docker_project_id/docker.sock"
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
