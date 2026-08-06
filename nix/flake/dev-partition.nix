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
      startPodmanService = pkgs.writeShellApplication {
        name = "agent-podman-service";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.podman
          pkgs.systemd
        ];
        text = ''
          runtime_dir="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          socket_dir="$runtime_dir/podman"
          socket="$socket_dir/podman.sock"
          marker=/run/agent-sandbox-podman-delegation

          mkdir -p "$socket_dir"

          # Match the neocache development shell's runtime cgroup delegation.
          # The drop-in and marker live under /run and disappear on reboot.
          if [[ ! -e "$marker" ]]; then
            if [[ " $(id -Gn) " != *" wheel "* ]]; then
              echo 'Podman setup requires membership in the wheel group.' >&2
              exit 1
            fi
            if ! command -v sudo >/dev/null; then
              echo 'Podman setup requires the host sudo wrapper.' >&2
              exit 1
            fi

            echo 'Authorizing ephemeral rootless Podman setup for this boot.' >&2
            sudo -v
            printf '[Service]\nDelegate=cpu cpuset io memory pids\n' \
              | sudo tee /run/systemd/system/user@.service.d/agent-sandbox.conf >/dev/null
            sudo systemctl daemon-reload
            sudo touch "$marker"
          fi

          if [[ -S "$socket" ]]; then
            exit 0
          fi

          if ! systemctl --user is-active --quiet agent-sandbox-podman.service; then
            systemd-run --user --quiet --unit=agent-sandbox-podman \
              --property=Delegate=yes \
              podman --log-level=error system service --time=0 "unix://$socket"
          fi

          for _ in $(seq 1 50); do
            [[ -S "$socket" ]] && exit 0
            sleep 0.1
          done

          echo "Podman's Docker-compatible socket did not appear at $socket" >&2
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
      };

      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.cargo
          pkgs.clippy
          pkgs.nixd
          pkgs.podman
          pkgs.podman-compose
          pkgs.rustc
          pkgs.rustfmt
        ];
        shellHook = ''
          ${config.pre-commit.installationScript}
          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
          export DOCKER_SOCK="$XDG_RUNTIME_DIR/podman/podman.sock"

          if [[ -z "''${CI:-}" && "''${AGENT_SANDBOX_SKIP_PODMAN_SERVICE:-}" != 1 ]]; then
            ${startPodmanService}/bin/agent-podman-service
          fi
        '';
      };
    };
}
