"""Actual restricted seed recovery on the host or optional delegated cgroups."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

CHECKOUT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(os.getenv("AE_TEST_RESOURCE_LIMITS_MODE", "process") == "process" or os.getenv("AE_TEST_CGROUP_ROOT"),
    "strict cgroup profile requires delegation")
class RestrictedRuntimeTests(unittest.TestCase):
    def test_real_runtime_crash_recovery_and_checkpoint_restore(self):
        with tempfile.TemporaryDirectory(prefix="ae-restricted-runtime-") as directory:
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", directory],
                           cwd=CHECKOUT, capture_output=True, check=True, timeout=120)
            limits = {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": 360,
                "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
                "output_bytes": 65536, "wall_ms": 600000}
            result = subprocess.run(["escript", str(CHECKOUT / "test/sandbox/restricted_runtime.escript")],
                cwd=CHECKOUT, capture_output=True, text=True, timeout=180,
                env={**os.environ, "AE_DATA_ROOT": directory, "AE_LLM_MODEL": "unused-no-provider-calls",
                     "AE_RUNTIME_ISOLATION": "bubblewrap", "AE_CGROUP_ROOT": os.environ.get("AE_TEST_CGROUP_ROOT", "/sys/fs/cgroup"),
                     "AE_RESOURCE_LIMITS_MODE": os.environ.get("AE_TEST_RESOURCE_LIMITS_MODE", "process"),
                     "AE_SANDBOX_LIMITS_JSON": json.dumps(limits)})
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Restricted runtime recovery passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
