"""Kill the Erlang publisher at its durable publication boundaries."""
import base64
import hashlib
import json
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import unittest

CHECKOUT = Path(__file__).resolve().parents[2]
DRIVER = CHECKOUT / "test/build/publication_probe.escript"


class PublicationTests(unittest.TestCase):
    def test_sigkill_preserves_baseline_and_only_exposes_complete_releases(self):
        with tempfile.TemporaryDirectory(prefix="ae-native-publication-") as directory:
            root = Path(directory) / "identity"
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True, capture_output=True)
            baseline = json.loads((root / "bootstrap.json").read_bytes())
            original = (root / "artifacts" / baseline["digest"] / "seed").read_bytes()
            repo = root / "source.git"
            revision = subprocess.check_output(["git", "--git-dir", str(repo), "-c", "user.name=fixture",
                "-c", "user.email=fixture@localhost", "commit-tree", baseline["source_tree"], "-p",
                baseline["source_revision"], "-m", "publication fixture"], text=True).strip()
            job = {"id": hashlib.sha256(b"publication job").hexdigest(), "limits": {"disk_reserve_bytes": 1048576}}
            for boundary in ("source_synced", "seed_written", "manifest_synced", "before_rename", "after_rename", "parent_synced"):
                with self.subTest(boundary=boundary):
                    executable = original + b"\n" + boundary.encode()
                    digest = hashlib.sha256(executable).hexdigest()
                    manifest = {**baseline, "digest": digest, "source_revision": revision,
                        "parent": baseline["digest"], "authoring": "llm", "producing_job": job["id"],
                        "producing_attempt": 1, "evaluation": None}
                    request = {"manifest": manifest, "executable": base64.b64encode(executable).decode(), "job": job}
                    path = Path(directory) / "request.json"
                    path.write_text(json.dumps(request))
                    child = subprocess.Popen(["escript", str(DRIVER), str(root), "interrupt", str(path), boundary],
                        cwd=CHECKOUT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        with selectors.DefaultSelector() as selector:
                            selector.register(child.stdout, selectors.EVENT_READ)
                            self.assertTrue(selector.select(20), "publisher did not reach its boundary")
                            self.assertEqual(json.loads(child.stdout.readline()), {"boundary": boundary})
                        child.kill()
                        child.wait(5)
                        self.assertEqual(child.returncode, -signal.SIGKILL)
                    finally:
                        if child.poll() is None:
                            child.kill()
                            child.wait(5)
                        child.stdout.close()
                        child.stderr.close()
                    visible = boundary in ("after_rename", "parent_synced")
                    target = root / "artifacts" / digest
                    self.assertEqual(target.exists(), visible)
                    probe = subprocess.check_output(["escript", str(DRIVER), str(root), "probe", digest], cwd=CHECKOUT, text=True)
                    self.assertEqual(json.loads(probe), {"baseline_verified": True, "available": visible})
                    self.assertEqual((root / "artifacts" / baseline["digest"] / "seed").read_bytes(), original)
                    result = subprocess.check_output(["escript", str(DRIVER), str(root), "recover", str(path), "none"], cwd=CHECKOUT, text=True)
                    self.assertEqual(json.loads(result), {"published": True})
                    self.assertEqual((target / "seed").read_bytes(), executable)
                    self.assertEqual(json.loads((target / "manifest.json").read_bytes()), manifest)
                    request["manifest"] = {**manifest, "objective": "conflicting identity"}
                    path.write_text(json.dumps(request))
                    conflict = subprocess.run(["escript", str(DRIVER), str(root), "recover", str(path), "none"],
                        cwd=CHECKOUT, capture_output=True, text=True)
                    self.assertNotEqual(conflict.returncode, 0)
                    self.assertEqual(json.loads(conflict.stdout), {"error": "artifact_conflict"})
                    self.assertEqual(json.loads((target / "manifest.json").read_bytes()), manifest)


if __name__ == "__main__":
    unittest.main()
