{ config, ... }:
{
  flake.packages.aarch64-darwin = config.flake.packages.aarch64-linux;

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
        nativeCheckInputs = [ pkgs.bubblewrap ];
        strictDeps = true;

        meta = {
          description = "Containerized code sandbox service";
          license = lib.licenses.mit;
          mainProgram = "agent-sandbox";
          platforms = lib.platforms.linux;
        };
      };

      tesseract = pkgs.tesseract.override {
        enableLanguages = [ "eng" ];
      };

      python = pkgs.python3.withPackages (pythonPackages: [
        pythonPackages.matplotlib
        pythonPackages.numpy
        pythonPackages.openpyxl
        pythonPackages.orjson
        pythonPackages.pandas
        pythonPackages.pillow
        ((pythonPackages.pytesseract.override { inherit tesseract; }).overridePythonAttrs (_: {
          doCheck = false;
        }))
        pythonPackages.requests
      ]);

      agentRuntimePackages = [
        agent
        pkgs.bubblewrap
        pkgs.cacert
        pkgs.restic
        tesseract
        python
      ];

      agentRuntime = pkgs.buildEnv {
        name = "agent-sandbox-runtime";
        paths = agentRuntimePackages;
      };

      agentRootfs = pkgs.runCommand "agent-sandbox-rootfs" { } ''
        mkdir -p "$out/dev" "$out/etc" "$out/home/user" "$out/proc" "$out/tmp" "$out/usr/bin" "$out/var/tmp"
        chmod 1777 "$out/tmp" "$out/var/tmp"
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
          mkdir -p ./dev ./etc ./home/user ./proc ./tmp ./var/tmp
          chmod 1777 ./tmp ./var/tmp
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
            "AGENT_SANDBOX_BWRAP=${lib.getExe pkgs.bubblewrap}"
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
            mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$out"
            podman-compose --file ${../../docker-compose.yaml} config > "$out/standard.yaml"
            podman-compose --file ${../../docker-compose-dev.yaml} config > "$out/development.yaml"
            grep --fixed-strings 'RESTIC_REPOSITORY: s3:http://s3:9000/agent-sandbox/home' "$out/development.yaml" >/dev/null
            if grep --fixed-strings 'AGENT_SANDBOX_S3_ENDPOINT' "$out/development.yaml" >/dev/null; then
              exit 1
            fi
            grep --fixed-strings 'while ! nix build --out-link /opt/agent-runtime .#agent-runtime; do' ${../../Dockerfile} >/dev/null
            grep --fixed-strings '[ "$build_attempt" -lt 3 ] || exit 1;' ${../../Dockerfile} >/dev/null
          '';

      # Keep this test as an explicit package rather than a flake check. CI runs
      # `nix flake check`, so it evaluates but does not build the expensive VM.
      nixosVmTest = pkgs.testers.runNixOSTest {
        name = "agent-sandbox-cluster";

        nodes = {
          machine =
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
                pkgs.jq
              ];
            };

          storage =
            { pkgs, ... }:
            {
              systemd.services.seaweedfs = {
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                serviceConfig = {
                  DynamicUser = true;
                  StateDirectory = "seaweedfs";
                  Environment = [
                    "AWS_ACCESS_KEY_ID=sandbox"
                    "AWS_SECRET_ACCESS_KEY=sandbox-secret"
                  ];
                  ExecStart = "${pkgs.seaweedfs}/bin/weed server -dir=/var/lib/seaweedfs -ip=127.0.0.1 -ip.bind=0.0.0.0 -master.port=19333 -volume.port=18080 -filer -filer.port=18888 -s3 -s3.port=9000";
                };
              };
              networking.firewall.allowedTCPPorts = [ 9000 ];
              environment.systemPackages = [
                pkgs.curl
                pkgs.jq
                pkgs.restic
              ];
            };
        };

        testScript = ''
          start_all()
          machine.wait_for_unit("docker.service")
          storage.wait_for_unit("seaweedfs.service")
          storage.wait_until_succeeds(
              "curl --silent --output /dev/null http://127.0.0.1:9000"
          )
          machine.succeed("docker load < ${agentImage}")
          machine.fail(
              "docker run --rm --network none "
              "--env RESTIC_REPOSITORY=s3:http://127.0.0.1:1/missing "
              "--env AWS_DEFAULT_REGION=us-east-1 "
              "ghcr.io/johnrichardrinehart/agent-sandbox:latest"
          )

          storage_ip = storage.succeed(
              "ip -4 -o address show dev eth1 | awk '{print $4}' | cut -d/ -f1"
          ).strip()
          compose_env = (
              "AGENT_SANDBOX_BACKUP_INTERVAL_SECONDS=3600 "
              "AGENT_SANDBOX_SECCOMP_PROFILE=${../../seccomp.json} "
              f"RESTIC_REPOSITORY=s3:http://{storage_ip}:9000/agent-sandbox/home "
              "AWS_ACCESS_KEY_ID=sandbox "
              "AWS_SECRET_ACCESS_KEY=sandbox-secret "
              "AWS_DEFAULT_REGION=us-east-1 "
          )
          storage_env = (
              "RESTIC_REPOSITORY=s3:http://127.0.0.1:9000/agent-sandbox/home "
              "RESTIC_PASSWORD=agent-sandbox "
              "AWS_ACCESS_KEY_ID=sandbox "
              "AWS_SECRET_ACCESS_KEY=sandbox-secret "
              "AWS_DEFAULT_REGION=us-east-1 "
          )
          compose = (
              compose_env
              + "docker-compose --project-name agent-sandbox "
              + "--file ${../../docker-compose.yaml} "
          )
          machine.succeed(compose + "up --detach --no-build")
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

          def write_file(source, destination):
              machine.succeed(
                  f"payload=$(base64 -w0 {source}); "
                  f"request=$(jq -nc --arg path '{destination}' --arg content \"$payload\" "
                  "'{path:$path,content:$content,createParents:true}'); "
                  "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
                  "sandbox.v0.FilesystemService/WriteFile >/dev/null"
              )
              machine.succeed(
                  f"request=$(jq -nc --arg path '{destination}' '{{path:$path}}'); "
                  "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
                  "sandbox.v0.FilesystemService/ReadFile "
                  f"| jq -r .content | base64 -d | cmp - {source}"
              )

          def execute_script(script, expected, stream="stdout"):
              machine.succeed(
                  f"request=$(jq -nc --arg script '{script}' "
                  "'{argv:[\"python\",$script],timeoutMs:\"120000\"}'); "
                  "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
                  "sandbox.v0.CommandService/ExecuteCommand >/tmp/command.json; "
                  "code=$(jq -r '.exitCode // 0' /tmp/command.json); "
                  "if [ \"$code\" -ne 0 ]; then "
                  "jq -r .stderr /tmp/command.json | base64 -d >&2; exit \"$code\"; fi; "
                  f"jq -r .{stream} /tmp/command.json | base64 -d | grep -F '{expected}'"
              )

          def execute_python(code, expected):
              machine.succeed(
                  f"request=$(jq -nc --arg code \"{code}\" "
                  "'{argv:[\"python\",\"-c\",$code],timeoutMs:\"120000\"}'); "
                  "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
                  "sandbox.v0.CommandService/ExecuteCommand >/tmp/python.json; "
                  "test \"$(jq -r '.exitCode // 0' /tmp/python.json)\" -eq 0; "
                  f"jq -r .stdout /tmp/python.json | base64 -d | grep -Fx '{expected}'"
              )

          machine.fail(
              "grpcurl -plaintext -d "
              "'{\"path\":\"../escape.txt\",\"content\":\"\"}' "
              "127.0.0.1:8080 sandbox.v0.FilesystemService/WriteFile"
          )

          write_file("${../../csv_transform.py}", "csv_transform.py")
          write_file("${../../linked_list.py}", "linked_list.py")
          write_file("${../../ocr_demo.py}", "ocr_demo.py")
          execute_script("csv_transform.py", "wrote summary.csv")
          execute_script("linked_list.py", "OK", "stderr")
          execute_script("ocr_demo.py", "OCR round trip OK")

          machine.succeed(
              "code=\"import sys; print('bad', file=sys.stderr); raise SystemExit(7)\"; "
              "request=$(jq -nc --arg code \"$code\" "
              "'{argv:[\"python\",\"-c\",$code]}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.CommandService/ExecuteCommand >/tmp/failure.json; "
              "test \"$(jq -r .exitCode /tmp/failure.json)\" -eq 7; "
              "jq -r .stderr /tmp/failure.json | base64 -d | grep -Fx bad"
          )
          machine.succeed(
              "request=$(jq -nc --arg command "
              "'open(\"/tmp/leak\", \"w\").write(\"leak\")' "
              "'{argv:[\"python\",\"-c\",$command]}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.CommandService/ExecuteCommand >/tmp/transient.json; "
              "code=$(jq -r '.exitCode // 0' /tmp/transient.json); "
              "if [ \"$code\" -ne 0 ]; then "
              "jq -r .stderr /tmp/transient.json | base64 -d >&2; exit \"$code\"; fi"
          )
          machine.succeed(
              "request=$(jq -nc --arg command "
              "'import os,sys; sys.exit(os.path.exists(\"/tmp/leak\"))' "
              "'{argv:[\"python\",\"-c\",$command]}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.CommandService/ExecuteCommand | jq -e '(.exitCode // 0) == 0'"
          )
          machine.succeed(
              "request=$(jq -nc --arg command "
              "'import os,time; pid=os.fork(); "
              "pid and os._exit(0); os.setsid(); "
              "fd=os.open(\"/dev/null\",os.O_RDWR); "
              "[os.dup2(fd,n) for n in (0,1,2)]; "
              "time.sleep(1); open(\"descendant-leak\",\"w\").close()' "
              "'{argv:[\"python\",\"-c\",$command]}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.CommandService/ExecuteCommand | jq -e '(.exitCode // 0) == 0'; "
              "sleep 2"
          )
          machine.fail(
              "grpcurl -plaintext -d '{\"path\":\"descendant-leak\"}' "
              "127.0.0.1:8080 sandbox.v0.FilesystemService/ReadFile"
          )
          machine.succeed(
              "grpcurl -plaintext -d '{\"argv\":[\"missing-executable\"]}' "
              "127.0.0.1:8080 sandbox.v0.CommandService/ExecuteCommand "
              "| jq -e '(.exitCode // 0) != 0 and ((.stderr // \"\") | length > 0)'"
          )
          machine.succeed(
              "grpcurl -plaintext -d "
              "'{\"argv\":[\"python\",\"-c\",\"import time; time.sleep(10)\"],\"timeoutMs\":\"10\"}' "
              "127.0.0.1:8080 sandbox.v0.CommandService/ExecuteCommand "
              "| jq -e '.exitCode == 124 and ((.stderr | @base64d) == \"command timed out\\n\")'"
          )
          machine.succeed(
              "request=$(jq -nc --arg command "
              "'import os; os.symlink(\"/tmp/escaped\", \"dangling\")' "
              "'{argv:[\"python\",\"-c\",$command]}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.CommandService/ExecuteCommand | jq -e '(.exitCode // 0) == 0'"
          )
          machine.fail(
              "grpcurl -plaintext -d "
              "'{\"path\":\"dangling\",\"content\":\"ZXNjYXBl\"}' "
              "127.0.0.1:8080 sandbox.v0.FilesystemService/WriteFile"
          )

          machine.succeed(
              "request=$(jq -nc --arg path persisted.txt --arg content cGVyc2lzdGVk "
              "'{path:$path,content:$content}'); "
              "grpcurl -plaintext -d \"$request\" 127.0.0.1:8080 "
              "sandbox.v0.FilesystemService/WriteFile >/dev/null"
          )
          execute_python(
              "import os; from pathlib import Path; "
              "root=Path('/home/user'); os.chmod(root,0o750); "
              "empty=root/'empty'; empty.mkdir(); os.chmod(empty,0o711); "
              "os.utime(empty,ns=(946684800000000000,946684800000000000)); "
              "large=root/'large.bin'; large.write_bytes(os.urandom(16*1024*1024)); "
              "executable=root/'executable'; executable.write_text('#!/bin/sh\\n'); "
              "os.chmod(executable,0o751); saved=root/'persisted.txt'; os.chmod(saved,0o640); "
              "os.utime(saved,ns=(946684800000000000,946684800000000000)); "
              "os.link(saved,root/'hard-link'); os.symlink('persisted.txt',root/'symbolic-link'); "
              "os.utime(root/'symbolic-link',ns=(946684800000000000,946684800000000000),follow_symlinks=False); "
              "os.mkfifo(root/'named-pipe',0o600); "
              "fd=os.open(os.fsencode(root)+b'/non-utf8-\\xff',os.O_WRONLY|os.O_CREAT,0o600); "
              "os.write(fd,b'bytes-name'); os.close(fd); "
              "(root/'ctime-before.txt').write_text(str(os.stat(saved).st_ctime_ns)); "
              "print('metadata-created')",
              "metadata-created",
          )
          machine.succeed(compose + "down")
          first_snapshot = storage.succeed(
              storage_env + "restic snapshots --json | jq -r '.[-1].id'"
          ).strip()
          first_size = int(storage.succeed(
              storage_env
              + f"restic stats --json --mode raw-data {first_snapshot} | jq -r .total_size"
          ))
          machine.succeed(compose + "up --detach --no-build")
          machine.wait_until_succeeds(
              "grpcurl -plaintext 127.0.0.1:8080 list "
              "sandbox.v0.FilesystemService | grep WriteFile"
          )
          execute_python(
              "import os,stat; from pathlib import Path; root=Path('/home/user'); "
              "saved=root/'persisted.txt'; info=os.stat(saved); empty=root/'empty'; "
              "empty_info=os.stat(empty); link_info=os.lstat(root/'symbolic-link'); "
              "assert stat.S_IMODE(os.stat(root).st_mode)==0o750; "
              "assert empty.is_dir() and not any(empty.iterdir()); "
              "assert stat.S_IMODE(empty_info.st_mode)==0o711; "
              "assert empty_info.st_atime_ns==946684800000000000; "
              "assert empty_info.st_mtime_ns==946684800000000000; "
              "assert (root/'symbolic-link').is_symlink(); "
              "assert os.readlink(root/'symbolic-link')=='persisted.txt'; "
              "assert link_info.st_atime_ns==946684800000000000; "
              "assert link_info.st_mtime_ns==946684800000000000; "
              "assert os.stat(root/'hard-link').st_ino==info.st_ino; "
              "assert stat.S_IMODE(info.st_mode)==0o640; "
              "assert stat.S_IMODE(os.stat(root/'executable').st_mode)==0o751; "
              "assert info.st_uid==os.getuid() and info.st_gid==os.getgid(); "
              "assert info.st_atime_ns==946684800000000000; "
              "assert info.st_mtime_ns==946684800000000000; "
              "assert info.st_ctime_ns>int((root/'ctime-before.txt').read_text()); "
              "assert stat.S_ISFIFO(os.stat(root/'named-pipe').st_mode); "
              "assert stat.S_IMODE(os.stat(root/'named-pipe').st_mode)==0o600; "
              "assert os.path.exists(os.fsencode(root)+b'/non-utf8-\\xff'); "
              "large=root/'large.bin'; data=bytearray(large.read_bytes()); "
              "data[len(data)//2]^=1; large.write_bytes(data); print('metadata-ok')",
              "metadata-ok",
          )
          machine.succeed(
              "grpcurl -plaintext -d '{\"path\":\"persisted.txt\"}' "
              "127.0.0.1:8080 sandbox.v0.FilesystemService/ReadFile "
              "| jq -r .content | base64 -d | grep -Fx persisted"
          )
          machine.succeed(compose + "down")
          second_snapshot = storage.succeed(
              storage_env + "restic snapshots --json | jq -r '.[-1].id'"
          ).strip()
          combined_size = int(storage.succeed(
              storage_env
              + f"restic stats --json --mode raw-data {first_snapshot} {second_snapshot} "
              "| jq -r .total_size"
          ))
          assert combined_size < first_size * 3 // 2, (
              f"restic delta was too large: first={first_size}, combined={combined_size}"
          )
        '';
      };
    in
    {
      packages = lib.optionalAttrs pkgs.stdenv.isLinux {
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
        exercise-image = {
          program = lib.getExe exerciseImage;
          meta.description = "Exercise a running agent sandbox OCI image";
        };
        publish-image = {
          program = lib.getExe publishImage;
          meta.description = "Publish and verify the agent sandbox OCI image";
        };
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        agent-systemd-nspawn = {
          program = lib.getExe nspawnApp;
          meta.description = "Run agent-sandbox in an ephemeral systemd-nspawn unit";
        };
      };

      # Consumer outputs are mirrored into the development partition's checks.
      # This keeps `nix flake check` authoritative without putting authoring
      # inputs in the image or package closure.
      _module.args.agentSandboxChecks = {
        inherit
          clippyCheck
          composeCheck
          exerciseImage
          publishImage
          scriptShebangCheck
          sourcehutManifestCheck
          ;
      }
      // lib.optionalAttrs pkgs.stdenv.isLinux {
        inherit
          agentImage
          agentRootfs
          nspawnApp
          ;
        agentPackage = agent;
      };
    };
}
