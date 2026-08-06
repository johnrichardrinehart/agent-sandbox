# Code Sandbox Requirements

You'll build a containerized code sandbox: an RPC service that can manage files and execute arbitrary commands, running as an unprivileged OS user.

### 1. Dockerfile — **must**

- Its entrypoint should start the service
- It **should** declare a non-root OS user, `sandbox-manager`, whose home directory is `/home/user` (create it if it doesn't exist)
- The service (and everything it executes) runs as `sandbox-manager`, never as root
- It **should** preinstall all the python libraries in `requirements.txt`

### 2. docker-compose — **must**

Able to start and kill the service, and any other services added in the process.

### 3. The RPC service — **must**

- Implemented in a popular backend language such as Go, Rust, Python, TypeScript, or C++
- Uses gRPC, JSON RPC, or HTTP
- On startup, syncs `/home/user` from an S3 bucket (a local S3 such as MinIO or MiniStack in `docker-compose` is fine)
- Exposes the two control planes below, plus a health check

**Filesystem control plane**

- Think along the lines of `WriteFile`, `ReadFile`
- Operations are scoped to `/home/user` — reject paths that escape it
- It's okay to assume we won't write or read large files

**Command control plane**

- Think along the lines of `ExecuteCommand`
- It should return stdout, stderr, and the exit code so the agent can recover from errors and understand whether the command it ran succeeded
- Execution is stateless: each command runs as a fresh process, and nothing is shared between calls except the files in `/home/user`

**Health check**

- It **must** expose a health check, so the running instance can be marked as healthy

### 4. Graceful shutdown — **should**

On `SIGTERM`, sync `/home/user` to an S3 bucket before exiting.

### 5. Logging — **should**

The service should implement a logger and use it accordingly.

### 6. README

Include a `README.md` that explains the project, and how another team member would get set up to run it.
