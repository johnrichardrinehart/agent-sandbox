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
          pkgs.util-linux
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
          data_dir="/var/tmp/agent-sandbox-docker-$uid-$project_id"
          owners_dir="$daemon_dir/owners"
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

          unmount_tree() {
            local root=$1
            local mount_target

            while IFS= read -r mount_target; do
              case "$mount_target" in
                "$root" | "$root"/*)
                  umount "$mount_target" 2>/dev/null \
                    || umount --lazy "$mount_target" 2>/dev/null \
                    || true
                  ;;
              esac
            done < <(findmnt --raw --noheadings --output TARGET | sort --reverse)
          }

          register_owner() {
            printf '%s\n' "$2" >"$owners_dir/$1"
          }

          owner_is_active() {
            local tracked_pid=$1
            local tracked_watch_cwd=$2
            local tracked_cwd

            [[ "$tracked_pid" =~ ^[1-9][0-9]*$ ]] || return 1
            [[ "$tracked_watch_cwd" == 0 || "$tracked_watch_cwd" == 1 ]] || return 1
            kill -0 "$tracked_pid" 2>/dev/null || return 1
            [[ "$tracked_watch_cwd" == 0 ]] && return 0
            tracked_cwd=$(readlink -f "/proc/$tracked_pid/cwd" 2>/dev/null || true)
            [[ "$tracked_cwd" == "$project_root" || "$tracked_cwd" == "$project_root/"* ]]
          }

          cleanup() {
            if [[ -n "''${daemon_pid:-}" ]]; then
              kill "$daemon_pid" 2>/dev/null || true
              wait "$daemon_pid" 2>/dev/null || true
            fi
            ip link delete "$bridge" 2>/dev/null || true
            unmount_tree "$daemon_dir"
            unmount_tree "$data_dir"
            rm -rf "$daemon_dir" "$data_dir"
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
              && "$previous_command" == *dockerd*"--data-root $data_dir"* ]]; then
              kill "$previous_daemon" 2>/dev/null || true
              for _ in $(seq 1 50); do
                kill -0 "$previous_daemon" 2>/dev/null || break
                sleep 0.1
              done
            fi
          fi

          ip link delete "$bridge" 2>/dev/null || true
          unmount_tree "$daemon_dir"
          unmount_tree "$data_dir"
          rm -rf "$daemon_dir" "$data_dir"
          install -d -m 0750 -o root -g "$gid" "$daemon_dir" "$data_dir"
          install -d -m 0770 -o root -g "$gid" "$owners_dir"
          install -m 0660 -o root -g "$gid" /dev/null "$owners_dir/$owner_pid"
          register_owner "$owner_pid" "$watch_cwd"
          printf '%s\n' "$$" >"$daemon_dir/runner.pid"

          ip link add name "$bridge" type bridge
          ip address add "$bridge_address" dev "$bridge"
          ip link set "$bridge" up

          dockerd \
            --bridge "$bridge" \
            --fixed-cidr "$bridge_cidr" \
            --data-root "$data_dir" \
            --exec-root "$daemon_dir/exec" \
            --group "$gid" \
            --host "unix://$daemon_dir/docker.sock" \
            --pidfile "$pidfile" &
          daemon_pid=$!

          while kill -0 "$daemon_pid" 2>/dev/null; do
            active_owners=0
            for owner_file in "$owners_dir"/*; do
              [[ -f "$owner_file" ]] || continue
              tracked_pid="''${owner_file##*/}"
              tracked_watch_cwd=$(<"$owner_file")
              if owner_is_active "$tracked_pid" "$tracked_watch_cwd"; then
                active_owners=$((active_owners + 1))
              else
                rm -f "$owner_file"
              fi
            done
            [[ "$active_owners" -gt 0 ]] || break
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
          owners_dir="$daemon_dir/owners"
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

          register_owner() {
            printf '%s\n' "$2" >"$owners_dir/$1"
          }

          if [[ -S "$socket" \
            && -d "$owners_dir" ]] \
            && docker --host "$docker_host" info >/dev/null 2>&1; then
            register_owner "$owner_pid" "$watch_cwd"
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

          : >"$log"

          # Close inherited file descriptors before sudo starts the runner.
          # Long-lived processes can keep direnv's internal pipes open.
          ${pkgs.bash}/bin/bash -c '
            exec </dev/null >"$1" 2>&1
            for fd_path in /proc/$$/fd/*; do
              fd="''${fd_path##*/}"
              [[ "$fd" =~ ^[0-9]+$ && "$fd" -ge 3 ]] || continue
              eval "exec $fd>&-"
            done
            exec sudo --non-interactive --background "$2" \
              "$3" "$4" "$5" "$6"
          ' _ "$log" ${runDockerDaemon}/bin/agent-dockerd-runner \
            "$owner_pid" "$watch_cwd" "$project_root" "$project_id"

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
        docker-detachment = pkgs.runCommand "agent-sandbox-docker-detachment-check" { } ''
          daemon=${startDockerDaemon}/bin/agent-docker-daemon
          runner=${runDockerDaemon}/bin/agent-dockerd-runner
          grep --fixed-strings 'for fd_path in /proc/$$/fd/*' "$daemon" >/dev/null
          grep --fixed-strings 'exec sudo --non-interactive --background' "$daemon" >/dev/null
          grep --fixed-strings 'sudo -v' "$daemon" >/dev/null
          grep --fixed-strings 'data_dir="/var/tmp/agent-sandbox-docker-$uid-$project_id"' "$runner" >/dev/null
          grep --fixed-strings 'owners_dir="$daemon_dir/owners"' "$runner" >/dev/null
          grep --fixed-strings 'register_owner "$owner_pid" "$watch_cwd"' "$daemon" >/dev/null
          grep --fixed-strings 'for owner_file in "$owners_dir"/*; do' "$runner" >/dev/null
          grep --fixed-strings '[[ "$active_owners" -gt 0 ]] || break' "$runner" >/dev/null
          if grep --fixed-strings 'owner.pid' "$daemon" "$runner" >/dev/null; then
            exit 1
          fi
          grep --fixed-strings 'findmnt --raw --noheadings --output TARGET' "$runner" >/dev/null
          grep --fixed-strings 'umount --lazy "$mount_target"' "$runner" >/dev/null
          test "$(grep --count --fixed-strings 'unmount_tree "$daemon_dir"' "$runner")" -eq 2
          test "$(grep --count --fixed-strings 'unmount_tree "$data_dir"' "$runner")" -eq 2
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
          pkgs.grpcurl
          pkgs.nixd
          pkgs.podman
          pkgs.podman-compose
          pkgs.protobuf
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
