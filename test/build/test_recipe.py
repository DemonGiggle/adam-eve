"""Rebuild a trusted source fixture under different paths and file timestamps."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

CHECKOUT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CHECKOUT / "scripts"))
import ae_build


class RecipeTests(unittest.TestCase):
    def test_reproducible_source_and_provenance(self):
        with tempfile.TemporaryDirectory(prefix="ae-repro-") as directory:
            root = Path(directory)
            snapshot = root / "snapshot"
            for app in ("ae_seed", "ae_protocol"):
                shutil.copytree(CHECKOUT / "apps" / app, snapshot / "apps" / app,
                    ignore=shutil.ignore_patterns("_build", "*.beam", "__pycache__"))
            subprocess.run(["git", "init", "-q", str(snapshot)], check=True)
            subprocess.run(["git", "-C", str(snapshot), "add", "."], check=True)
            subprocess.run(["git", "-C", str(snapshot), "-c", "user.name=test", "-c", "user.email=test@localhost",
                "commit", "-qm", "reproducible source"], check=True)
            revision = subprocess.check_output(["git", "-C", str(snapshot), "rev-parse", "HEAD"], text=True).strip()
            tree = subprocess.check_output(["git", "-C", str(snapshot), "rev-parse", "HEAD^{tree}"], text=True).strip()
            first, second = root / "first", root / "second"
            for target in (first, second):
                shutil.copytree(snapshot, target, ignore=shutil.ignore_patterns(".git"))
            for path in second.rglob("*"):
                os.utime(path, (2000000000, 2000000000))
            a, b = root / "out-a/seed", root / "out-b/seed"
            ae_build.build_manual(first, revision, tree, None, a, trusted_manual=True)
            ae_build.build_manual(second, revision, tree, None, b, trusted_manual=True)
            self.assertEqual(a.read_bytes(), b.read_bytes())
            # An escript is a ZIP with a small executable header; Python can
            # inspect the trusted fixture without executing any agent code.
            with zipfile.ZipFile(a) as archive:
                metadata = archive.read("ae_seed/provenance/build.term")
                self.assertIn(revision.encode(), metadata)
                self.assertIn(tree.encode(), metadata)
                self.assertIn(ae_build.PACKAGE_SHA256.encode(), metadata)
                self.assertIn("jsx/LICENSE", archive.namelist())
                self.assertIn("ae_seed/ebin/seed_agent.beam", archive.namelist())
                self.assertFalse(any("ae_core" in name for name in archive.namelist()))
                self.assertTrue(all(entry.date_time == (1980, 1, 1, 0, 0, 0) for entry in archive.infolist()))
            # The same code on a different source revision must have a distinct
            # retained executable identity rather than conflicting provenance.
            third = root / "out-c/seed"
            changed_revision = hashlib.sha1(b"other source revision").hexdigest()
            ae_build.build_manual(first, changed_revision, tree, None, third, trusted_manual=True)
            self.assertNotEqual(a.read_bytes(), third.read_bytes())

    def test_no_implicit_host_execution_or_dependency_fallback(self):
        with tempfile.TemporaryDirectory(prefix="ae-recipe-denial-") as directory:
            root = Path(directory)
            output = root / "seed"
            with self.assertRaisesRegex(RuntimeError, "explicit manual trust"):
                ae_build.build_manual(root, "a" * 40, "b" * 40, None, output)
            self.assertFalse(output.exists())
            package = root / "tampered-package.tar"
            package.write_bytes(b"not the locked dependency")
            with patch.dict(os.environ, {"AE_JSX_PACKAGE": str(package)}):
                with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                    with ae_build.pinned_dependency():
                        self.fail("tampered package was accepted")

    def test_source_build_hooks_cannot_replace_fixed_recipe(self):
        with tempfile.TemporaryDirectory(prefix="ae-recipe-hooks-") as directory:
            root = Path(directory)
            source = root / "source"
            for app in ("ae_seed", "ae_protocol"):
                shutil.copytree(CHECKOUT / "apps" / app, source / "apps" / app,
                    ignore=shutil.ignore_patterns("_build", "*.beam", "__pycache__"))
            marker, output = root / "hook-executed", root / "out/seed"
            config = source / "apps/ae_seed/rebar.config"
            config.write_text(config.read_text() + f'\n{{pre_hooks, [{{compile, "touch {marker}"}}]}}.\n')
            with ae_build.pinned_dependency() as dependency:
                arguments = ae_build.recipe_arguments(source, dependency, "a" * 40, "b" * 40, None, output)
                result = subprocess.run(["escript", *arguments], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
