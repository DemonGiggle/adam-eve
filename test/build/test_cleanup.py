"""Partial collection must preserve pins, respect publishers and survive SIGKILL."""
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

CHECKOUT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CHECKOUT / "scripts"))
sys.path.insert(0, str(CHECKOUT / "test/integration"))
import ae_cleanup as collector
from ae_publish import publication_lock
from phase0 import Controller


def kill_after_removal(root):
    original = collector.shutil.rmtree
    def remove(path):
        original(path)
        os.kill(os.getpid(), signal.SIGKILL)
    with mock.patch.object(collector.shutil, "rmtree", remove):
        collector.cleanup(root, apply=True)


class CleanupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory(prefix="ae-cleanup-fixture-")
        cls.base = Path(cls.fixture.name)
        subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(cls.base)],
            check=True, capture_output=True)
        controller = Controller(cls.base, 0, {"AE_RUNTIME_ISOLATION": "development",
            "AE_RETENTION_POLICY_JSON": json.dumps(collector.PRESERVE)})
        try:
            cls.manifest = controller.command("status")["routing"]["artifact"]
        finally:
            controller.close()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ae-cleanup-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "identity"
        shutil.copytree(self.base, self.root)
        self.root.chmod(0o700)

    def connection(self):
        import sqlite3
        return sqlite3.connect(self.root / "state/agent.sqlite3")

    def orphan(self, suffix="aaaaaaaa"):
        path = self.root / "artifacts" / (".publishing-" + suffix)
        path.mkdir(mode=0o700)
        (path / "seed").write_bytes(b"partial executable")
        return path

    def test_plan_collects_only_partials_and_preserves_all_complete_versions_and_refs(self):
        partial = self.orphan()
        other = self.orphan("bbbbbbbb")
        # Even a complete version absent from the registry remains retained.
        unregistered = self.root / "artifacts" / ("f" * 64)
        shutil.copytree(self.root / "artifacts" / self.manifest["digest"], unregistered)
        collector.git(self.root / "source.git", "update-ref", "refs/attempts/retained/1", self.manifest["source_revision"])
        before = collector.git(self.root / "source.git", "for-each-ref")
        plan = collector.cleanup(self.root)
        self.assertEqual(plan["publications"], [partial.name, other.name])
        self.assertEqual(plan["preserved_complete_artifacts"], 2)
        self.assertTrue(partial.exists())
        applied = collector.cleanup(self.root, apply=True)
        self.assertEqual(applied["remaining_publications"], [])
        self.assertTrue(unregistered.is_dir())
        self.assertEqual(collector.git(self.root / "source.git", "for-each-ref"), before)
        self.assertEqual(collector.checksum(self.root / "artifacts" / self.manifest["digest"] / "seed"), self.manifest["digest"])
        with self.connection() as database:
            self.assertEqual([row[0] for row in database.execute("SELECT kind FROM events WHERE kind LIKE 'storage_cleanup_%' ORDER BY seq")],
                ["storage_cleanup_started", "storage_cleanup_completed"])

    def test_publisher_and_unrecovered_jobs_fence_cleanup(self):
        partial = self.orphan()
        with publication_lock(self.root), self.assertRaisesRegex(ValueError, "publication is in progress"):
            collector.cleanup(self.root, apply=True)
        with self.connection() as database:
            database.execute("INSERT INTO evolution_jobs VALUES(?,?,?,?)", ("a" * 64, "unfinished", "building", '{"status":"building"}'))
        with self.assertRaisesRegex(ValueError, "job recovery is unfinished"):
            collector.cleanup(self.root, apply=True)
        self.assertTrue(partial.exists())
        with self.connection() as database:
            database.execute("UPDATE evolution_jobs SET status='cancelled',data=?", ('{"status":"cancelled"}',))
        self.assertFalse(collector.cleanup(self.root, apply=True)["remaining_publications"])

    def test_missing_pins_and_unexpected_files_refuse_before_removal(self):
        first = self.orphan()
        unsafe = self.orphan("zzzzzzzz")
        outside = self.root / "keep"
        outside.write_bytes(b"keep")
        (unsafe / "manifest.json").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "unknown partial publication contents"):
            collector.cleanup(self.root, apply=True)
        self.assertTrue(first.exists())
        self.assertEqual(outside.read_bytes(), b"keep")
        (unsafe / "manifest.json").unlink()
        collector.git(self.root / "source.git", "update-ref", "-d", "refs/generations/" + self.manifest["digest"])
        with self.assertRaisesRegex(ValueError, "pinned source reference mismatch"):
            collector.cleanup(self.root, apply=True)
        self.assertTrue(first.exists())

    def test_sigkill_after_deletion_resumes_durable_intent(self):
        paths = [self.orphan(), self.orphan("bbbbbbbb")]
        child = multiprocessing.get_context("fork").Process(target=kill_after_removal, args=(str(self.root),))
        child.start()
        child.join(15)
        if child.is_alive():
            child.kill()
            child.join(5)
            self.fail("cleanup fault injection did not finish")
        self.assertEqual(child.exitcode, -signal.SIGKILL)
        self.assertEqual(sum(path.exists() for path in paths), 1)
        with self.connection() as database:
            intent = collector.control(database, "storage_cleanup")
            self.assertEqual(intent["status"], "pending")
        result = collector.cleanup(self.root, apply=True)
        self.assertTrue(result["resuming"])
        self.assertEqual(result["cleanup_id"], intent["id"])
        self.assertFalse(any(path.exists() for path in paths))
        with self.connection() as database:
            self.assertEqual(collector.control(database, "storage_cleanup")["status"], "completed")
            self.assertEqual(database.execute("SELECT COUNT(*) FROM events WHERE kind LIKE 'storage_cleanup_%'").fetchone()[0], 2)
        self.assertEqual(collector.cleanup(self.root)["publications"], [])

    def test_policy_and_restore_recovery_are_required(self):
        partial = self.orphan()
        with self.connection() as database:
            database.execute("DELETE FROM control WHERE name='retention_policy'")
        with self.assertRaisesRegex(ValueError, "preservation policy is required"):
            collector.cleanup(self.root, apply=True)
        with self.connection() as database:
            database.execute("INSERT INTO control VALUES('retention_policy',?)", (json.dumps(collector.PRESERVE),))
            database.execute("INSERT INTO control VALUES('restore',?)", ('{"pending":true}',))
        with self.assertRaisesRegex(ValueError, "restore recovery is unfinished"):
            collector.cleanup(self.root, apply=True)
        self.assertTrue(partial.exists())
