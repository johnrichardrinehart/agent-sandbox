FROM rust:1.88-bookworm AS builder
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN cargo build --locked --release

FROM python:3.13-slim-bookworm
RUN apt-get update \
    && apt-get install --no-install-recommends --yes tesseract-ocr \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --requirement /tmp/requirements.txt \
    && rm /tmp/requirements.txt
RUN groupadd --gid 10001 --system sandbox-manager \
    && useradd --uid 10001 --gid sandbox-manager --system \
      --home-dir /home/user --create-home sandbox-manager
COPY --from=builder /build/target/release/agent-sandbox /usr/local/bin/agent-sandbox
USER sandbox-manager
ENV HOME=/home/user
WORKDIR /home/user
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2)"]
ENTRYPOINT ["/usr/local/bin/agent-sandbox"]
