# Code Sandbox Requirements

You'll build a containerized code sandbox: an RPC service that can manage files and execute arbitrary commands, running as an unprivileged OS user.

### 1. Dockerfile — **must**

- Its entrypoint should start the service
- It **should** declare a non-root OS user, `sandbox-manager`, whose home directory is `/home/sandbox-manager` (create it if it doesn't exist)
- The service (and everything it executes) runs as `sandbox-manager`, never as root
- It **should** preinstall all Python libraries declared by the project's dependency manifest; `requirements.txt` is optional, but its listed dependencies must be available to the container's `python` interpreter

### 2. docker-compose — **must**

Able to start and kill the service, and any other services added in the process.

### 3. The RPC service — **must**

- Implemented in a popular backend language such as Go, Rust, Python, TypeScript, or C++
- ~~Uses gRPC, JSON RPC, or HTTP~~
- Uses an RPC interface

> **Note:** Distinguishing `gRPC` from `HTTP` as mutually exclusive options is confusing because gRPC uses HTTP/2 as its transport, or HTTP/3 depending on configuration.

- On startup, syncs `/home/sandbox-manager` from an S3 bucket (a local S3 such as MinIO or MiniStack in `docker-compose` is fine)
- Exposes the two control planes below, plus a health check

**Filesystem control plane**

- Think along the lines of `WriteFile`, `ReadFile`
- Operations are scoped to `/home/sandbox-manager` — reject paths that escape it
- Develop a policy for symlinks, hardlinks, and reflinks, and add tests that enforce that policy.
- It's okay to assume we won't write or read large files

**Command control plane**

- Think along the lines of `ExecuteCommand`
- It should return stdout, stderr, and the exit code so the agent can recover from errors and understand whether the command it ran succeeded
- Execution is stateless (apart from `/home/sandbox-manager`): each command runs as a fresh process, and nothing is shared between calls except the files in `/home/sandbox-manager`

**Health check**

- It **must** expose a health check, so the running instance can be marked as healthy

### 4. Graceful shutdown — **should**

On `SIGTERM`, sync `/home/sandbox-manager` to an S3 bucket before exiting.

### 5. Logging — **should**

The service should implement a logger and use it accordingly.

### 6. README

Include a `README.md` that explains the project, and how another team member would get set up to run it.

### Acceptance

The scripts must run successfully inside the sandbox, driven entirely through your RPC service.
* `csv_transform.py`
* `linked_list.py`
* `ocr_demo.py`

# John Rinehart Addendum

Drawing the boundary at `/home/sandbox-manager/*` forces the developer to create `seccomp` or other strange semantics policies around files in `/tmp` and symlinks to paths above `/home/sandbox-manager/`. The problem should instead be restructured so the developer creates a system that tracks, updates, and manages files that the user owns or creates anywhere in the container through a developer-managed manifest. The manifest must sync alongside the tracked filesystem contents and filesystem metadata.

I chose `/home/sandbox-manager` because it keeps `/etc/passwd`, `HOME`, the working directory, and the user name consistent. This is not only technically possible; it is what we implemented. Other home paths are possible, but they are less standard and make that relationship more confusing.
