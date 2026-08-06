# Caveats

## Filesystem backup limits

The container runs restic as the unprivileged `sandbox-manager` user. Restic backs up the filesystem tree that this user can read and restores metadata that this user can set.

## Ownership and privileged metadata

Files that sandbox commands create have the same UID and GID as `sandbox-manager`. Restic restores these files with the correct effective ownership. It cannot restore another UID or a GID that is not in the process group list.

The process can restore normal mode bits and permitted `user.*` extended attributes. It cannot set privileged attributes in namespaces such as `trusted.*` or `security.*`. ACL and filesystem flag support depends on the filesystem, the restic version, and the permissions of `sandbox-manager`.

## Times and inode identity

Restic records and restores access time and modification time. A later file read can change access time according to the mount policy.

Linux does not provide an operation that sets inode change time. A restored inode therefore has a new `ctime`. Inode numbers are also new after a restore. Restic preserves a hard-link relationship, but the restored link group can have a different inode number from the source link group.

## Entry types

Restic preserves regular files, directories, empty directories, symbolic links, hard links, and supported special entries. The integration test checks a FIFO. Active Unix sockets are process state and are not backup data. The unprivileged process cannot create device nodes.

Names do not need to be valid UTF-8. The integration test checks a name that contains a non-UTF-8 byte.

## Snapshot consistency

A periodic backup is not an atomic filesystem snapshot. A command can change a file while restic scans it. The final backup starts after the gRPC server stops accepting work, so it has a stable tree when all command processes have exited.

Each snapshot records deletions, but older snapshots still contain their earlier trees. Repository retention and pruning must run as a separate maintenance task. Pruning can read and rewrite repository packs and is not part of container shutdown.

## Repository access

The repository password encrypts the backup. The service uses the known value `agent-sandbox` when no password setting is present. This default checks encrypted repository operation, but it does not provide confidentiality. Set a private password for confidential data. Data cannot be restored if a private password is lost.

Only one sandbox should write to a repository host and path unless the deployment has a separate coordination policy.

## Command namespaces increase the kernel attack surface

The command sandbox uses Bubblewrap user, process, IPC, and mount namespaces. Docker's default seccomp profile blocks the system calls that create these namespaces. This project uses [`seccomp.json`](seccomp.json), a narrow extension of the Moby default profile, to permit `clone`, `clone3`, `mount`, `pivot_root`, `umount`, `umount2`, and `unshare`.

This policy does not give a container access to the host mount namespace. The container runs as a non-root user, and Compose drops all Linux capabilities. A process cannot mount in the container's initial mount namespace because it does not have `CAP_SYS_ADMIN`. A process can gain capabilities only in a new user namespace and can use them only in child namespaces that it owns. The profile does not add `setns`, so a process cannot use that system call to join another namespace. Commands can create nested user namespaces because the outer seccomp policy must permit the first user namespace that Bubblewrap creates.

User namespaces expose more kernel code than Docker's default seccomp profile. A kernel defect in that code can increase the risk of a container escape. Keep the host kernel current, and do not replace the profile with `seccomp=unconfined`.
