"""Kernel boundary component checks and optional delegated-cgroup integration.

The namespace-only checks execute fixed, trusted fixtures. Production run()
always requires cgroups; these component tests do not enable a fallback mode.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import platform
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

CHECKOUT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CHECKOUT / "apps/ae_core/priv"))
import ae_sandbox as sandbox

LIMITS = {"memory_bytes": 134217728, "pids": 32, "cpu_percent": 100,
          "cpu_seconds": 5, "address_space_bytes": 536870912, "file_bytes": 33554432,
          "open_files": 128, "output_bytes": 65536, "wall_ms": 5000}


def python_mounts():
    # The production runtime only mounts BEAM's toolchain. Fixed Python probes
    # explicitly request their public standard library, never the host home.
    path = subprocess.check_output(["/usr/bin/python3", "-c", "import sysconfig; print(sysconfig.get_path('stdlib'))"],
                                   text=True).strip()
    return [(path, path)]


@unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "Linux x86_64 backend")
class BoundaryTests(unittest.TestCase):
    def test_expired_deadline_never_starts_a_process(self):
        with self.assertRaisesRegex(sandbox.Unavailable, "sandbox_deadline_expired"):
            sandbox.run(Path("/nonexistent-cgroup"), LIMITS, ["/bin/false"], deadline_ms=1)

    def test_required_limits_and_kernel_cgroup_files(self):
        with self.assertRaises(sandbox.Unavailable):
            sandbox.validate_limits({})
        with self.assertRaises(sandbox.Unavailable):
            sandbox.validate_limits({**LIMITS, "pids": True})
        with tempfile.TemporaryDirectory(prefix="ae-cgroup-negative-") as directory:
            root = Path(directory)
            # Files resembling cgroup controls must not pass kernel verification.
            (root / "cgroup.subtree_control").write_text("memory cpu pids")
            marker = root / "must-not-execute"
            with self.assertRaisesRegex(sandbox.Unavailable, "cgroup_v2_required"):
                sandbox.run(root, LIMITS, ["/bin/sh", "-c", f"touch {marker}"])
            self.assertFalse(marker.exists())

    def test_release_is_sealed_and_digest_checked(self):
        with tempfile.TemporaryDirectory(prefix="ae-seal-") as directory:
            release = Path(directory) / "seed"
            release.write_bytes(b"evaluated executable")
            digest = hashlib.sha256(release.read_bytes()).hexdigest()
            with sandbox.sealed_release(release, digest, 4096) as descriptor:
                release.write_bytes(b"changed after verification")
                self.assertEqual(os.read(descriptor, 4096), b"evaluated executable")
                with self.assertRaises(OSError):
                    os.write(descriptor, b"tampered")
            with self.assertRaisesRegex(sandbox.Unavailable, "artifact_digest_mismatch"):
                with sandbox.sealed_release(release, digest, 4096):
                    self.fail("changed contents accepted")
            symlink = Path(directory) / "link"
            symlink.symlink_to(release)
            with self.assertRaises(OSError):
                with sandbox.sealed_release(symlink, digest, 4096):
                    self.fail("symlink accepted")

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "Linux x86_64 backend")
    def test_namespace_seccomp_and_host_disclosure(self):
        with tempfile.TemporaryDirectory(prefix="ae-boundary-") as directory, socket.socket() as listener:
            root = Path(directory)
            private = root / "secret"
            private.write_text("HOST_CREDENTIAL_CANARY")
            public = root / "public"
            public.write_text("public input")
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            script = f'''
import ctypes, errno, json, os, socket
from pathlib import Path
assert not Path({str(private)!r}).exists()
assert not Path("/proc/{os.getpid()}").exists()
assert not Path("/sys/fs/cgroup").exists()
assert not Path("/run/docker.sock").exists()
assert "AE_SECRET_CANARY" not in os.environ
assert Path("/public").read_text() == "public input"
for path in ("/public", "/tmp/write", "/root-write", "/dev/write"):
    try:
        Path(path).write_text("denied")
        raise AssertionError("write escaped read-only mounts: " + path)
    except OSError as error:
        assert error.errno in (errno.EROFS, errno.EACCES)
try:
    socket.create_connection(("127.0.0.1", {port}), timeout=0.2)
    raise AssertionError("host network reachable")
except OSError:
    pass
libc = ctypes.CDLL(None, use_errno=True)
assert libc.unshare(0x10000000) == -1
assert ctypes.get_errno() == errno.EPERM
assert libc.syscall(56, 0x10000000 | 17, 0, 0, 0, 0) == -1
assert ctypes.get_errno() == errno.EPERM
fields = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
assert int(fields["CapEff"].strip(), 16) == 0
assert int(fields["CapBnd"].strip(), 16) == 0
assert fields["NoNewPrivs"].strip() == "1"
print(json.dumps({{"boundary": "ok"}}))
'''
            result = self.namespace(["/usr/bin/python3", "-c", script], readonly=[(public, "/public")])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout), {"boundary": "ok"})
            self.assertEqual(private.read_text(), "HOST_CREDENTIAL_CANARY")

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "Linux x86_64 backend")
    def test_unix_ipc_and_beam_survive_restrictions(self):
        with tempfile.TemporaryDirectory(prefix="ae-ipc-boundary-") as directory, socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(Path(directory) / "ipc"))
            listener.listen()
            listener.settimeout(5)
            failures = []

            def accept():
                try:
                    connection, _ = listener.accept()
                    with connection:
                        self.assertEqual(connection.recv(16), b"authenticated")
                        connection.sendall(b"ok")
                except Exception as error:
                    failures.append(error)

            thread = threading.Thread(target=accept, daemon=True)
            thread.start()
            script = 'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/ipc/ipc"); s.sendall(b"authenticated"); assert s.recv(16)==b"ok"'
            result = self.namespace(["/usr/bin/python3", "-c", script], readonly=[(directory, "/ipc")])
            thread.join(6)
            self.assertFalse(failures, failures)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = self.namespace(["/usr/bin/erl", "-noshell", "-eval", 'io:format("beam_ok~n"), halt().'])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout.strip(), b"beam_ok")

    @unittest.skipUnless(platform.system() == "Linux" and platform.machine() == "x86_64", "Linux x86_64 backend")
    def test_sealed_release_mount(self):
        with tempfile.TemporaryDirectory(prefix="ae-sealed-mount-") as directory:
            path = Path(directory) / "fixture"
            path.write_bytes(b"immutable data")
            with sandbox.sealed_release(path, hashlib.sha256(path.read_bytes()).hexdigest(), 4096) as descriptor:
                result = self.namespace(["/bin/cat", "/agent/seed"], data_files=[(descriptor, "/agent/seed")])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stdout, b"immutable data")

    @staticmethod
    def namespace(command, *, readonly=(), data_files=()):
        # Fixed trusted probes only. Never call this instead of run() for a job.
        with sandbox.seccomp_policy() as policy:
            arguments = sandbox.namespace_command(command, LIMITS, policy, python_mounts() + list(readonly), data_files)
            return subprocess.run(arguments, capture_output=True, timeout=10,
                env={**os.environ, "AE_SECRET_CANARY": "host-only"},
                pass_fds=(policy,) + tuple(fd for fd, _ in data_files))


@unittest.skipUnless(os.getenv("AE_TEST_CGROUP_ROOT"), "requires an explicitly delegated cgroup v2 test root")
class DelegatedCgroupTests(unittest.TestCase):
    def test_absolute_deadline_caps_the_configured_wall_allowance(self):
        root = Path(os.environ["AE_TEST_CGROUP_ROOT"])
        before = set(root.glob("ae-*"))
        started = time.monotonic()
        code, _, reason = sandbox.run(root, {**LIMITS, "wall_ms": 30000}, ["/bin/sleep", "30"],
            deadline_ms=time.time_ns() // 1000000 + 1500)
        self.assertNotEqual(code, 0)
        self.assertEqual(reason, "sandbox_timeout")
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(set(root.glob("ae-*")), before)

    def test_aggregate_cpu_and_process_budgets(self):
        root = Path(os.environ["AE_TEST_CGROUP_ROOT"])
        _, _, reason = sandbox.run(root, LIMITS, ["/usr/bin/python3", "-c", "while True: pass"],
                                   readonly=python_mounts(), cpu_budget_ms=50)
        self.assertEqual(reason, "sandbox_cpu_budget")
        # Make the per-process rlimit looser than the aggregate cgroup limit to
        # prove the actual kernel PID controller stops forks, not just RLIMIT_NPROC.
        group_limits = {**LIMITS, "pids": 16}
        script = '''
import errno, os, signal, time
children=[]
try:
    for _ in range(64):
        try: pid=os.fork()
        except OSError as error:
            assert error.errno == errno.EAGAIN
            break
        if pid == 0:
            time.sleep(5)
            os._exit(0)
        children.append(pid)
    assert 0 < len(children) < 16
finally:
    for pid in children: os.kill(pid, signal.SIGKILL)
    for pid in children: os.waitpid(pid, 0)
'''
        with sandbox.Cgroup(root, group_limits) as group, sandbox.seccomp_policy() as policy:
            arguments = sandbox.namespace_command(["/usr/bin/python3", "-c", script],
                {**LIMITS, "pids": 64}, policy, readonly=python_mounts())
            result = subprocess.run(arguments, capture_output=True, timeout=15,
                pass_fds=(policy,), preexec_fn=group.enter_child)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            events = dict(line.split() for line in (group.path / "pids.events").read_text().splitlines())
            self.assertGreater(int(events["max"]), 0)

    def test_real_membership_limits_and_cleanup(self):
        root = Path(os.environ["AE_TEST_CGROUP_ROOT"])
        before = set(root.glob("ae-*"))
        code, output, reason = sandbox.run(root, LIMITS, ["/usr/bin/python3", "-c", 'print("cgroup_ok")'], readonly=python_mounts())
        self.assertEqual((code, output.strip(), reason), (0, b"cgroup_ok", None))
        self.assertEqual(set(root.glob("ae-*")), before)

    def test_oom_timeout_and_output_limit(self):
        root = Path(os.environ["AE_TEST_CGROUP_ROOT"])
        code, output, _ = sandbox.run(root, LIMITS, ["/usr/bin/python3", "-c", 'print("oom_start",flush=True); x=bytearray(256*1024*1024); print("bad")'], readonly=python_mounts())
        self.assertNotEqual(code, 0)
        self.assertIn(b"oom_start\n", output)
        self.assertNotIn(b"bad", output)
        _, _, reason = sandbox.run(root, {**LIMITS, "wall_ms": 100}, ["/bin/sleep", "5"])
        self.assertEqual(reason, "sandbox_timeout")
        _, _, reason = sandbox.run(root, {**LIMITS, "output_bytes": 128}, ["/usr/bin/python3", "-c", 'print("x"*4096)'], readonly=python_mounts())
        self.assertEqual(reason, "sandbox_output_limit")


if __name__ == "__main__":
    unittest.main()
