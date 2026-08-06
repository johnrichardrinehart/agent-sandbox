_: {
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs) lib;

      rustSource = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ../../src
          ../../Cargo.toml
          ../../Cargo.lock
        ];
      };

      agent = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-sandbox";
        version = "0.1.0";
        src = rustSource;
        cargoLock.lockFile = ../../Cargo.lock;
        strictDeps = true;

        meta = {
          description = "Containerized code sandbox service";
          license = lib.licenses.mit;
          mainProgram = "agent-sandbox";
          platforms = lib.platforms.linux;
        };
      };

      python = pkgs.python3.withPackages (pythonPackages: [
        pythonPackages.matplotlib
        pythonPackages.numpy
        pythonPackages.openpyxl
        pythonPackages.orjson
        pythonPackages.pandas
        pythonPackages.pillow
        pythonPackages.pytesseract
        pythonPackages.requests
      ]);

      agentRootfs = pkgs.runCommand "agent-sandbox-rootfs" { } ''
        mkdir -p "$out/etc" "$out/home/user" "$out/usr/bin"
        cat > "$out/etc/passwd" <<'EOF'
        root:x:0:0:root:/root:/bin/sh
        sandbox-manager:x:10001:10001:Sandbox manager:/home/user:/bin/sh
        EOF
        cat > "$out/etc/group" <<'EOF'
        root:x:0:
        sandbox-manager:x:10001:
        EOF
        ln -s ${lib.getExe agent} "$out/usr/bin/agent-sandbox"
      '';

      agentImage = pkgs.dockerTools.buildLayeredImage {
        name = "ghcr.io/johnrichardrinehart/agent-sandbox";
        tag = "latest";
        contents = [
          agent
          pkgs.cacert
          pkgs.tesseract
          python
        ];
        fakeRootCommands = ''
          mkdir -p ./etc ./home/user
          cat > ./etc/passwd <<'EOF'
          root:x:0:0:root:/root:/bin/sh
          sandbox-manager:x:10001:10001:Sandbox manager:/home/user:/bin/sh
          EOF
          cat > ./etc/group <<'EOF'
          root:x:0:
          sandbox-manager:x:10001:
          EOF
          chown 10001:10001 ./home/user
        '';
        config = {
          User = "sandbox-manager";
          Env = [
            "HOME=/home/user"
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ];
          WorkingDir = "/home/user";
          Entrypoint = [ (lib.getExe agent) ];
          ExposedPorts."8080/tcp" = { };
          Labels = {
            "org.opencontainers.image.description" = "Containerized code sandbox service";
            "org.opencontainers.image.licenses" = "MIT";
            "org.opencontainers.image.source" = "https://github.com/johnrichardrinehart/agent-sandbox";
            "org.opencontainers.image.title" = "Agent sandbox";
          };
        };
      };

      nspawnApp = pkgs.writeShellApplication {
        name = "agent-systemd-nspawn";
        runtimeInputs = [ pkgs.systemd ];
        text = ''
          machine="agent-sandbox-$UID"
          command=(
            sudo ${pkgs.systemd}/bin/systemd-nspawn
            --quiet
            --directory=${agentRootfs}
            --volatile=overlay
            --register=no
            --settings=no
            --machine="$machine"
            --bind-ro=/nix/store
            "--tmpfs=/home/user:mode=0750,uid=10001,gid=10001"
            --setenv=HOME=/home/user
            --setenv=AGENT_SANDBOX_LISTEN=0.0.0.0:8080
            --user=sandbox-manager
            /usr/bin/agent-sandbox
          )

          if [[ "''${1:-}" == "--dry-run" ]]; then
            printf '%q ' "''${command[@]}"
            printf '\n'
            exit 0
          fi

          if ! command -v sudo >/dev/null; then
            echo 'agent-systemd-nspawn requires the host sudo wrapper' >&2
            exit 1
          fi

          echo 'Starting an ephemeral systemd-nspawn unit (wheel authorization required).' >&2
          exec "''${command[@]}"
        '';
      };

      clippyCheck = pkgs.stdenvNoCC.mkDerivation {
        pname = "agent-sandbox-clippy";
        version = "0.1.0";
        src = rustSource;
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.clippy
          pkgs.rustc
        ];
        buildPhase = ''
          runHook preBuild
          export CARGO_HOME="$TMPDIR/cargo-home"
          cargo clippy --all-targets --locked --offline -- -D warnings
          runHook postBuild
        '';
        installPhase = ''
          touch "$out"
        '';
      };

      composeCheck =
        pkgs.runCommand "agent-sandbox-compose-check"
          {
            nativeBuildInputs = [
              pkgs.podman
              pkgs.podman-compose
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            export XDG_RUNTIME_DIR="$TMPDIR/run"
            mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
            podman-compose --file ${../../docker-compose.yml} config > "$out"
          '';
    in
    {
      packages = {
        default = agent;
        agent-sandbox = agent;
        agent-image = agentImage;
        oci-image = agentImage;
        agent-rootfs = agentRootfs;
        agent-systemd-nspawn = nspawnApp;
      };

      apps.agent-systemd-nspawn = {
        program = lib.getExe nspawnApp;
        meta.description = "Run agent-sandbox in an ephemeral systemd-nspawn unit";
      };

      # Consumer outputs are mirrored into the development partition's checks.
      # This keeps `nix flake check` authoritative without putting authoring
      # inputs in the image or package closure.
      _module.args.agentSandboxChecks = {
        inherit
          agentImage
          agentRootfs
          clippyCheck
          composeCheck
          nspawnApp
          ;
        agentPackage = agent;
      };
    };
}
