"""Candidate preparation never runs source; production compilation requires cgroups."""
import copy
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

CHECKOUT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CHECKOUT / "apps/ae_core/priv"))
import ae_candidate as candidate
import ae_build_inputs as inputs
import ae_sandbox as sandbox


class CandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="ae-builder-fixture-")
        cls.base_root = Path(cls.fixture.name)
        subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(cls.base_root)],
                       check=True, capture_output=True, timeout=120)
        cls.base = json.loads((cls.base_root / "bootstrap.json").read_bytes())

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ae-builder-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "identity"
        shutil.copytree(self.base_root, self.root)
        wall_ms = int(os.environ.get("AE_TEST_BUILD_WALL_MS", "20000"))
        cpu_ms = int(os.environ.get("AE_TEST_BUILD_CPU_MS", "10000"))
        self.job = {"id": "a" * 64, "status": "building", "objective": "Add an explicitly requested reply prefix",
            "baseline": {"slot": "adam", "runtime_instance_id": "fixture", "epoch": 1, "artifact": self.base},
            "attempts": 1, "deadline": time.time_ns() // 1_000_000 + wall_ms * 3,
            "limits": {"total_ms": wall_ms * 3, "build_ms": wall_ms, "cpu_ms": cpu_ms * 3,
                       "memory_bytes": 536870912, "processes": 64, "max_patch_bytes": 262144,
                       "max_diagnostic_bytes": 1024, "disk_reserve_bytes": 1048576}}
        path = "apps/ae_seed/src/seed_agent.erl"
        original = candidate.git(self.root, "show", self.base["source_revision"] + ":" + path).decode()
        changed = original.replace('<<"text">> => Text, <<"event_refs">> => []',
                                   '<<"text">> => <<"authored:", Text/binary>>, <<"event_refs">> => []')
        self.assertNotEqual(original, changed)
        patch = f"diff --git a/{path} b/{path}\n" + "".join(difflib.unified_diff(
            original.splitlines(True), changed.splitlines(True), fromfile="a/" + path, tofile="b/" + path))
        self.proposal = {"attempt": 1, "base_artifact": self.base["digest"], "base_source_revision": self.base["source_revision"],
            "epoch": 1, "patch": patch, "patch_hash": hashlib.sha256(patch.encode()).hexdigest(), "paths": [path]}
        package = os.environ.get("AE_JSX_PACKAGE", str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar"))
        self.config = {"cgroup_root": os.environ.get("AE_TEST_CGROUP_ROOT", "/sys/fs/cgroup"),
            "jsx_package": package, "source_bytes": 2097152, "source_files": 128, "artifact_bytes": 8388608,
            "sandbox_limits": {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": (cpu_ms + 999) // 1000,
                "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
                "output_bytes": 16777216, "wall_ms": wall_ms}}
        self.lease = {"job_id": self.job["id"], "attempt": 1, "kind": "build", "status": "reserved",
                      "cpu_ms": cpu_ms, "wall_ms": wall_ms,
                      "reserved_at_ms": self.job["deadline"] - wall_ms * 3,
                      "expires_at_ms": self.job["deadline"] - wall_ms * 2}

    def prepare(self, proposal=None):
        workspace = Path(tempfile.mkdtemp(dir=self.root / "workspaces"))
        return candidate.prepare(self.root, self.job, proposal or self.proposal, workspace, self.config)

    def test_pinned_source_parent_export_and_reproducible_attempt(self):
        source, revision, tree = self.prepare()
        self.assertIn(b'<<"authored:", Text/binary>>', (source / self.proposal["paths"][0]).read_bytes())
        self.assertFalse((source / ".git").exists())
        self.assertFalse((source / "apps/ae_core").exists())
        self.assertFalse((source / "apps/ae_protocol/test").exists())
        self.assertEqual(candidate.git(self.root, "rev-parse", revision + "^").strip().decode(), self.base["source_revision"])
        ref = f"refs/attempts/{self.job['id']}/1"
        self.assertEqual(candidate.git(self.root, "rev-parse", ref).strip().decode(), revision)
        _, again, same_tree = self.prepare()
        self.assertEqual((again, same_tree), (revision, tree))

    def test_zero_context_patch_is_checked_against_the_pinned_source(self):
        path = self.proposal["paths"][0]
        patch = (f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n"
                 "@@ -1 +1 @@\n--module(seed_agent).\n+-module(seed_agent). % authored\n")
        source, _, _ = self.prepare({**self.proposal, "patch": patch, "patch_hash": hashlib.sha256(patch.encode()).hexdigest()})
        self.assertTrue((source / path).read_text().startswith("-module(seed_agent). % authored\n"))

    def test_wrong_baselines_scope_and_symlinks_are_rejected(self):
        with self.assertRaisesRegex(candidate.BuildError, "stale_build_baseline"):
            self.prepare({**self.proposal, "epoch": 2})
        with self.assertRaisesRegex(candidate.BuildError, "protected_patch"):
            self.prepare({**self.proposal, "paths": ["apps/ae_core/src/ae_store.erl"]})
        path = "apps/ae_seed/src/link.erl"
        patch = (f"diff --git a/{path} b/{path}\nnew file mode 120000\n--- /dev/null\n+++ b/{path}\n"
                 "@@ -0,0 +1 @@\n+/etc/passwd\n")
        with self.assertRaisesRegex(candidate.BuildError, "unsafe_source_tree"):
            self.prepare({**self.proposal, "patch": patch, "paths": [path], "patch_hash": hashlib.sha256(patch.encode()).hexdigest()})
        self.assertFalse(any(p.is_symlink() for p in (self.root / "workspaces").rglob("*")))

    def test_missing_kernel_boundary_never_builds_or_publishes(self):
        fake = Path(self.temporary.name) / "fake-cgroup"
        fake.mkdir()
        before = set((self.root / "artifacts").iterdir())
        with self.assertRaisesRegex(sandbox.Unavailable, "cgroup_v2_required"):
            candidate.build(self.root, self.job, self.proposal, self.lease, {**self.config, "cgroup_root": str(fake)})
        self.assertEqual(set((self.root / "artifacts").iterdir()), before)
        self.assertEqual(list((self.root / "workspaces").iterdir()), [])

    def test_explicit_limits_lease_and_disk_reserve_are_required(self):
        with self.assertRaisesRegex(candidate.BuildError, "build_configuration_required"):
            candidate.validate_config({})
        with self.assertRaisesRegex(candidate.BuildError, "execution_lease_required"):
            candidate.effective_limits(self.config, self.job, {**self.lease, "job_id": "invented"})
        job = copy.deepcopy(self.job)
        job["limits"]["disk_reserve_bytes"] = shutil.disk_usage(self.root).free + 1
        with self.assertRaisesRegex(candidate.BuildError, "disk_reserve_exhausted"):
            candidate.build(self.root, job, self.proposal, self.lease, self.config)
        self.assertEqual(list((self.root / "workspaces").iterdir()), [])

    @unittest.skipUnless(os.getenv("AE_TEST_CGROUP_ROOT"), "requires explicitly delegated cgroup v2 test root")
    def test_restricted_build_retains_exact_release_and_provenance(self):
        manifest = candidate.build(self.root, self.job, self.proposal, self.lease, self.config)
        self.assertEqual(manifest["authoring"], "llm")
        self.assertIsNone(manifest["evaluation"])
        artifact = self.root / "artifacts" / manifest["digest"]
        self.assertEqual(hashlib.sha256((artifact / "seed").read_bytes()).hexdigest(), manifest["digest"])
        self.assertEqual(json.loads((artifact / "manifest.json").read_bytes()), manifest)
        self.assertEqual(manifest["patch_hash"], self.proposal["patch_hash"])
        self.assertEqual(manifest["parent"], self.base["digest"])
        self.assertEqual(candidate.git(self.root, "rev-parse", "refs/generations/" + manifest["digest"]).strip().decode(), manifest["source_revision"])
        self.assertEqual(list((self.root / "workspaces").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
