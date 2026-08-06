FROM nixos/nix:2.35.1

ENV NIX_CONFIG="experimental-features = nix-command flakes"
WORKDIR /build
COPY . .
RUN mkdir -p /opt /home/user /tmp \
    && build_attempt=1 \
    && while ! nix build --out-link /opt/agent-runtime .#agent-runtime; do \
      [ "$build_attempt" -lt 3 ] || exit 1; \
      build_attempt=$((build_attempt + 1)); \
      sleep 5; \
    done \
    && printf '%s\n' \
      'sandbox-manager:x:10001:10001:Sandbox manager:/home/user:/bin/sh' \
      >>/etc/passwd \
    && printf '%s\n' 'sandbox-manager:x:10001:' >>/etc/group \
    && chown 10001:10001 /home/user \
    && chmod 1777 /tmp \
    && find /build -mindepth 1 -delete \
    && nix store gc

USER sandbox-manager
ENV HOME=/home/user
ENV AGENT_SANDBOX_BWRAP=/opt/agent-runtime/bin/bwrap
ENV PATH=/opt/agent-runtime/bin:/nix/var/nix/profiles/default/bin
ENV SSL_CERT_FILE=/opt/agent-runtime/etc/ssl/certs/ca-bundle.crt
WORKDIR /home/user
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD ["python", "-c", "import socket; socket.create_connection(('127.0.0.1', 8080), timeout=2).close()"]
ENTRYPOINT ["/opt/agent-runtime/bin/agent-sandbox"]
