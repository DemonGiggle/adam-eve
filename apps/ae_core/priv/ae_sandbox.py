"""Linux execution boundary owned by the controller, never by agent source.

All untrusted execution requires BOTH namespace/seccomp isolation and verified
cgroup v2 controllers. There is deliberately no rlimit-only fallback.
"""
import argparse
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import selectors
import stat
import subprocess
import sys
import time
import uuid


class Unavailable(RuntimeError):
    pass


LIMIT_KEYS = {"memory_bytes", "pids", "cpu_percent", "cpu_seconds", "address_space_bytes",
              "file_bytes", "open_files", "output_bytes", "wall_ms"}


def validate_limits(limits):
    if set(limits) != LIMIT_KEYS or any(type(v) is not int or not 0 < v < 2**63 for v in limits.values()):
        raise Unavailable("sandbox_limits_required")
    return limits


def cgroup_filesystem(path):
    # statfs.f_type is the first native long on the supported Linux x86_64 ABI.
    libc = ctypes.CDLL(None, use_errno=True)
    buffer = ctypes.create_string_buffer(512)
    if libc.statfs(os.fsencode(path), buffer) != 0:
        raise Unavailable("cgroup_root_unavailable")
    return ctypes.c_long.from_buffer(buffer).value == 0x63677270


class Cgroup:
    def __init__(self, root, limits):
        self.root = Path(root)
        self.limits = validate_limits(limits)
        self.path = None

    def __enter__(self):
        if platform.system() != "Linux" or platform.machine() != "x86_64":
            raise Unavailable("unsupported_sandbox_platform")
        if self.root.is_symlink() or not cgroup_filesystem(self.root):
            raise Unavailable("cgroup_v2_required")
        try:
            enabled = set((self.root / "cgroup.subtree_control").read_text().split())
            if not {"cpu", "memory", "pids"} <= enabled:
                raise Unavailable("cgroup_controllers_not_delegated")
            self.path = self.root / ("ae-" + uuid.uuid4().hex)
            self.path.mkdir(mode=0o700)
            limits = self.limits
            values = {"memory.max": str(limits["memory_bytes"]), "memory.swap.max": "0",
                      "pids.max": str(limits["pids"]), "cpu.max": f"{limits['cpu_percent'] * 1000} 100000",
                      "memory.oom.group": "1"}
            for name, value in values.items():
                (self.path / name).write_text(value)
                if (self.path / name).read_text().strip() != value:
                    raise Unavailable("cgroup_limit_not_enforced")
            if not (self.path / "cgroup.kill").exists():
                raise Unavailable("cgroup_kill_required")
            return self
        except (OSError, Unavailable) as error:
            self.__exit__(None, None, None)
            if isinstance(error, Unavailable):
                raise
            raise Unavailable("cgroup_delegation_unusable") from error

    def enter_child(self):
        # This runs in the trusted, single-threaded launcher's fork before exec.
        # No generated code or compiler hook executes before cgroup membership.
        (self.path / "cgroup.procs").write_text("0")

    def cpu_used(self):
        fields = dict(line.split() for line in (self.path / "cpu.stat").read_text().splitlines())
        return int(fields["usage_usec"])

    def kill(self):
        if self.path is not None and self.path.exists():
            kill_file = self.path / "cgroup.kill"
            if kill_file.exists():
                kill_file.write_text("1")

    def __exit__(self, *_):
        if self.path is None:
            return
        try:
            self.kill()
            for _ in range(100):
                try:
                    self.path.rmdir()
                    self.path = None
                    return
                except OSError as error:
                    if error.errno not in (errno.EBUSY, errno.ENOTEMPTY):
                        raise
                    time.sleep(0.01)
        except FileNotFoundError:
            self.path = None
        if self.path is not None:
            raise Unavailable("cgroup_cleanup_failed")


@contextmanager
def seccomp_policy():
    """Keep the candidate from remounting cgroups or creating fresh namespaces."""
    if platform.machine() != "x86_64":
        raise Unavailable("unsupported_seccomp_architecture")
    try:
        lib = ctypes.CDLL("libseccomp.so.2")
    except OSError as error:
        raise Unavailable("libseccomp_required") from error
    lib.seccomp_init.argtypes = [ctypes.c_uint32]
    lib.seccomp_init.restype = ctypes.c_void_p
    lib.seccomp_release.argtypes = [ctypes.c_void_p]
    lib.seccomp_syscall_resolve_name.argtypes = [ctypes.c_char_p]
    lib.seccomp_syscall_resolve_name.restype = ctypes.c_int
    lib.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.c_void_p]
    lib.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.seccomp_attr_set.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint32]
    context = lib.seccomp_init(0x7FFF0000)  # SCMP_ACT_ALLOW; foreign architectures fail closed.
    if not context:
        raise Unavailable("seccomp_initialization_failed")
    descriptor = os.memfd_create("ae-seccomp", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    try:
        # SCMP_FLTATR_ACT_BADARCH / SCMP_FLTATR_CTL_NNP.
        if lib.seccomp_attr_set(context, 2, 0x80000000) != 0 or lib.seccomp_attr_set(context, 3, 1) != 0:
            raise Unavailable("seccomp_attributes_failed")
        class Compare(ctypes.Structure):
            _fields_ = [("arg", ctypes.c_uint), ("op", ctypes.c_uint),
                        ("mask", ctypes.c_uint64), ("value", ctypes.c_uint64)]

        def deny(name, error=errno.EPERM, comparison=None):
            number = lib.seccomp_syscall_resolve_name(name.encode())
            if number < 0:
                raise Unavailable("seccomp_syscall_unavailable")
            pointer = ctypes.byref(comparison) if comparison is not None else None
            if lib.seccomp_rule_add_array(context, 0x00050000 | error, number,
                    1 if comparison is not None else 0, pointer) != 0:
                raise Unavailable("seccomp_rule_failed")

        for name in ("mount", "umount2", "pivot_root", "move_mount", "open_tree", "fsopen", "fsconfig",
                     "fsmount", "fspick", "unshare", "setns", "ptrace", "process_vm_readv", "process_vm_writev",
                     "open_by_handle_at", "name_to_handle_at", "bpf", "perf_event_open", "keyctl", "add_key",
                     "request_key", "io_uring_setup", "io_uring_register", "io_uring_enter", "userfaultfd",
                     "kexec_load", "init_module", "finit_module", "delete_module", "reboot", "swapon", "swapoff"):
            deny(name)
        deny("clone3", errno.ENOSYS)  # libc can fall back to the checked clone syscall.
        for bit in (0x00020000, 0x02000000, 0x04000000, 0x08000000, 0x10000000, 0x20000000, 0x40000000):
            deny("clone", comparison=Compare(0, 7, bit, bit))  # SCMP_CMP_MASKED_EQ
        if lib.seccomp_export_bpf(context, descriptor) != 0:
            raise Unavailable("seccomp_export_failed")
        os.lseek(descriptor, 0, os.SEEK_SET)
        fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS,
                    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
        yield descriptor
    finally:
        os.close(descriptor)
        lib.seccomp_release(context)


def namespace_command(command, limits, policy, readonly=(), data_files=(), writable_tmp=()):
    validate_limits(limits)
    args = ["/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session", "--clearenv",
            "--cap-drop", "ALL", "--hostname", "adam-eve"]
    for path in ("/usr/bin", "/usr/lib/erlang", "/usr/lib/x86_64-linux-gnu", "/usr/lib64"):
        if not Path(path).is_dir():
            raise Unavailable("sandbox_toolchain_unavailable")
        args += ["--ro-bind", path, path]
    args += ["--symlink", "usr/bin", "/bin", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
             "--proc", "/proc", "--remount-ro", "/proc", "--dev", "/dev", "--remount-ro", "/dev",
             "--tmpfs", "/tmp", "--remount-ro", "/tmp"]
    for source, target in readonly:
        args += ["--ro-bind", str(source), target]
    for descriptor, target in data_files:
        args += ["--ro-bind-data", str(descriptor), target]
    for target in writable_tmp:
        args += ["--tmpfs", target]
    args += ["--setenv", "PATH", "/usr/bin:/bin", "--setenv", "HOME", "/tmp",
             "--setenv", "LANG", "C.UTF-8", "--setenv", "TZ", "UTC",
             "--setenv", "ERL_FLAGS", "+S 2:2 +A 1 +SDcpu 1:1 +SDio 1 +MIscs 32",
             "--chdir", "/", "--remount-ro", "/", "--seccomp", str(policy), "--",
             "/usr/bin/prlimit", f"--as={limits['address_space_bytes']}",
             f"--cpu={limits['cpu_seconds']}", f"--nproc={limits['pids']}",
             f"--nofile={limits['open_files']}", f"--fsize={limits['file_bytes']}", "--"]
    return args + list(command)


def run(cgroup_root, limits, command, *, readonly=(), data_files=(), writable_tmp=(), watch_parent=False, cpu_budget_ms=None):
    """Run an opaque program only after the kernel resource boundary is ready."""
    validate_limits(limits)
    if cpu_budget_ms is None:
        cpu_budget_ms = limits["cpu_seconds"] * 1000
    if type(cpu_budget_ms) is not int or not 0 < cpu_budget_ms <= limits["cpu_seconds"] * 1000:
        raise Unavailable("invalid_cpu_budget")
    with Cgroup(cgroup_root, limits) as group, seccomp_policy() as policy:
        args = namespace_command(command, limits, policy, readonly, data_files, writable_tmp)
        descriptors = (policy,) + tuple(fd for fd, _ in data_files)
        with selectors.DefaultSelector() as selector:
            if watch_parent:
                selector.register(sys.stdin.buffer, selectors.EVENT_READ, "parent")
            with subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    env={"PATH": "/usr/bin:/bin"}, close_fds=True, pass_fds=descriptors,
                    preexec_fn=group.enter_child) as child:
                try:
                    selector.register(child.stdout, selectors.EVENT_READ, "output")
                    deadline = time.monotonic() + limits["wall_ms"] / 1000
                    output = bytearray()
                    reason = None
                    while child.poll() is None or selector.get_map().get(child.stdout.fileno()):
                        if time.monotonic() >= deadline:
                            reason = "sandbox_timeout"
                        if group.cpu_used() > cpu_budget_ms * 1000:
                            reason = "sandbox_cpu_budget"
                        if reason:
                            group.kill()
                            break
                        for key, _ in selector.select(0.05):
                            data = os.read(key.fd, 65536)
                            if key.data == "parent":
                                if not data:
                                    reason = "controller_disconnected"
                                    group.kill()
                                    break
                            elif not data:
                                selector.unregister(child.stdout)
                            else:
                                if len(output) + len(data) > limits["output_bytes"]:
                                    reason = "sandbox_output_limit"
                                    group.kill()
                                    break
                                output.extend(data)
                    child.wait(timeout=5)
                    return child.returncode, bytes(output), reason
                finally:
                    group.kill()
                    child.wait(timeout=5)


@contextmanager
def sealed_release(path, digest, max_bytes):
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise Unavailable("invalid_artifact_digest")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise Unavailable("invalid_release_file")
        data = bytearray()
        while True:
            chunk = os.read(descriptor, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > max_bytes:
                raise Unavailable("release_size_limit")
        if hashlib.sha256(data).hexdigest() != digest:
            raise Unavailable("artifact_digest_mismatch")
    finally:
        os.close(descriptor)
    frozen = os.memfd_create("ae-release", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
    try:
        remaining = memoryview(data)
        while remaining:
            remaining = remaining[os.write(frozen, remaining):]
        os.lseek(frozen, 0, os.SEEK_SET)
        fcntl.fcntl(frozen, fcntl.F_ADD_SEALS,
                    fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL)
        yield frozen
    finally:
        os.close(frozen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cgroup-root", required=True, type=Path)
    parser.add_argument("--limits-json", required=True)
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--runtime", type=Path)
    parser.add_argument("--digest")
    parser.add_argument("--ipc-dir", type=Path)
    parser.add_argument("--token")
    args = parser.parse_args()
    try:
        limits = validate_limits(json.loads(args.limits_json))
        if args.probe:
            code, _, reason = run(args.cgroup_root, limits, ["/usr/bin/true"])
            if code or reason:
                raise Unavailable(reason or "sandbox_probe_failed")
            print(json.dumps({"available": True}))
            return
        if args.runtime is None or args.ipc_dir is None or args.token is None or args.digest is None:
            raise Unavailable("runtime_arguments_required")
        with sealed_release(args.runtime, args.digest, limits["file_bytes"]) as release:
            code, _, reason = run(args.cgroup_root, limits,
                ["/usr/bin/escript", "/agent/seed", "/ipc/ipc", args.token],
                readonly=[(args.ipc_dir, "/ipc")], data_files=[(release, "/agent/seed")], watch_parent=True)
        if code or reason:
            raise Unavailable(reason or "sandbox_runtime_failed")
    except (Unavailable, OSError, ValueError, subprocess.SubprocessError) as error:
        # A fixed bounded status, never arbitrary child output, reaches the VM.
        reason = str(error) if isinstance(error, Unavailable) else "sandbox_unavailable"
        print(json.dumps({"available": False, "error": reason}))
        sys.exit(1)


if __name__ == "__main__":
    main()
