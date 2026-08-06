_: {
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs) lib;

      rustSource = lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions [
          ../../src
          ../../proto
          ../../build.rs
          ../../Cargo.toml
          ../../Cargo.lock
        ];
      };

      agent = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-sandbox";
        version = "0.1.0";
        src = rustSource;
        cargoLock.lockFile = ../../Cargo.lock;
        nativeBuildInputs = [ pkgs.protobuf ];
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

      agentRuntimePackages = [
        agent
        pkgs.cacert
        pkgs.tesseract
        python
      ];

      agentRuntime = pkgs.buildEnv {
        name = "agent-sandbox-runtime";
        paths = agentRuntimePackages;
      };

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
        contents = agentRuntimePackages;
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

      publishImage = pkgs.writeShellApplication {
        name = "publish-image";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.skopeo
        ];
        text = lib.removePrefix "#!/usr/bin/env nix-shell\n" (
          builtins.readFile ../../scripts/publish-image.sh
        );
      };

      exerciseImage = pkgs.writeShellApplication {
        name = "exercise-agent-image";
        runtimeInputs = [ pkgs.grpcurl ];
        text = lib.removePrefix "#!/usr/bin/env nix-shell\n" (
          builtins.readFile ../../scripts/exercise-image.sh
        );
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

      clippyCheck = pkgs.rustPlatform.buildRustPackage {
        pname = "agent-sandbox-clippy";
        version = "0.1.0";
        src = rustSource;
        cargoLock.lockFile = ../../Cargo.lock;
        nativeBuildInputs = [
          pkgs.clippy
          pkgs.protobuf
        ];
        strictDeps = true;
        doCheck = false;
        buildPhase = ''
          runHook preBuild
          cargo clippy --all-targets --locked --offline -- -D warnings
          runHook postBuild
        '';
        installPhase = ''
          touch "$out"
        '';
      };

      scriptShebangCheck = pkgs.runCommand "agent-sandbox-script-shebang-check" { } ''
        for script in ${../../scripts}/*.sh; do
          test "$(head -n 1 "$script")" = '#!/usr/bin/env nix-shell'
          grep --fixed-strings --line-regexp '#! nix-shell -i bash' "$script" >/dev/null
        done
        touch "$out"
      '';

      sourcehutManifestCheck =
        pkgs.runCommand "agent-sandbox-sourcehut-manifest-check"
          {
            nativeBuildInputs = [
              pkgs.jq
              pkgs.yq-go
            ];
          }
          ''
            yq --output-format=json '.' ${../../.build.yml} | jq --exit-status '
              .image == "nixos/unstable" and
              .sources == ["git@git.sr.ht:~fuzzybear3965/agent-sandbox"] and
              .secrets == [
                "3a60ba67-89eb-49e6-a818-f4d28848de74",
                "6e416072-c83c-4b52-b040-42396f7d2b74"
              ] and
              (.tasks | length) == 3 and
              .submitter["git.sr.ht"].enabled == true
            ' >/dev/null
            cp ${../../.build.yml} "$out"
          '';

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
            podman-compose --file ${../../docker-compose.yaml} config > "$out"
          '';

      # Keep this test as an explicit package rather than a flake check. CI runs
      # `nix flake check`, so it evaluates but does not build the expensive VM.
      nixosVmTest = pkgs.testers.runNixOSTest {
        name = "agent-sandbox-docker";

        nodes.machine =
          { pkgs, ... }:
          {
            virtualisation = {
              docker.enable = true;
              diskSize = 8192;
              memorySize = 2048;
            };
            environment.systemPackages = [
              pkgs.docker-compose
              pkgs.grpcurl
            ];
          };

        testScript = ''
          start_all()
          machine.wait_for_unit("docker.service")
          machine.succeed("docker load < ${agentImage}")
          machine.succeed(
              "docker-compose --project-name agent-sandbox "
              "--file ${../../docker-compose.yaml} up --detach --no-build"
          )
          machine.wait_until_succeeds(
              "grpcurl -plaintext 127.0.0.1:8080 list "
              "sandbox.v0.FilesystemService | grep WriteFile"
          )
          machine.succeed(
              "grpcurl -plaintext -d "
              "'{\"service\":\"sandbox.v0.FilesystemService\"}' "
              "127.0.0.1:8080 grpc.health.v1.Health/Check "
              "| grep SERVING"
          )
          machine.succeed(
              "grpcurl -plaintext -d "
              "'{\"service\":\"sandbox.v0.CommandService\"}' "
              "127.0.0.1:8080 grpc.health.v1.Health/Check "
              "| grep SERVING"
          )
          machine.succeed(
              "test \"$(docker ps --filter status=running --format '{{.Names}}' | wc -l)\" -eq 1"
          )
        '';
      };
    in
    {
      packages = {
        default = agent;
        agent-sandbox = agent;
        agent-image = agentImage;
        oci-image = agentImage;
        agent-rootfs = agentRootfs;
        agent-runtime = agentRuntime;
        agent-systemd-nspawn = nspawnApp;
        exercise-image = exerciseImage;
        publish-image = publishImage;
        nixos-vm-test = nixosVmTest;
      };

      apps = {
        agent-systemd-nspawn = {
          program = lib.getExe nspawnApp;
          meta.description = "Run agent-sandbox in an ephemeral systemd-nspawn unit";
        };
        exercise-image = {
          program = lib.getExe exerciseImage;
          meta.description = "Exercise a running agent sandbox OCI image";
        };
        publish-image = {
          program = lib.getExe publishImage;
          meta.description = "Publish and verify the agent sandbox OCI image";
        };
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
          exerciseImage
          nspawnApp
          publishImage
          scriptShebangCheck
          sourcehutManifestCheck
          ;
        agentPackage = agent;
      };
    };
}
