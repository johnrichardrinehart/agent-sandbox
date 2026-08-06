# Caveats

## Command namespaces increase the kernel attack surface

The command sandbox uses Bubblewrap user, process, IPC, and mount namespaces. Docker's default seccomp profile blocks the system calls that create these namespaces. This project uses [`seccomp.json`](seccomp.json), a narrow extension of the Moby default profile, to permit `clone`, `clone3`, `mount`, `pivot_root`, `umount`, `umount2`, and `unshare`.

This policy does not give a container access to the host mount namespace. The container runs as a non-root user, and Compose drops all Linux capabilities. A process cannot mount in the container's initial mount namespace because it does not have `CAP_SYS_ADMIN`. A process can gain capabilities only in a new user namespace and can use them only in child namespaces that it owns. The profile does not add `setns`, so a process cannot use that system call to join another namespace. Commands can create nested user namespaces because the outer seccomp policy must permit the first user namespace that Bubblewrap creates.

User namespaces expose more kernel code than Docker's default seccomp profile. A kernel defect in that code can increase the risk of a container escape. Keep the host kernel current, and do not replace the profile with `seccomp=unconfined`.
