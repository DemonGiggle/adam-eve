#!/usr/bin/env python3
"""Missing retention disables evolution; disk pressure rejects it before spending."""
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import time
import sys

from phase0 import CALLS, CHECKOUT, Controller, Provider, turn

sys.path.insert(0, str(CHECKOUT / "test/evaluation"))
from test_evaluate import policy


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sandbox = {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": 60,
        "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
        "output_bytes": 65536, "wall_ms": 600000}
    builder = {"cgroup_root": "/sys/fs/cgroup", "resource_limits_mode": "process",
        "jsx_package": "/unused-for-preflight", "source_bytes": 2097152, "source_files": 128,
        "artifact_bytes": 8388608, "sandbox_limits": sandbox}
    evaluator = {key: value for key, value in builder.items() if key != "jsx_package"}
    evaluator.update({"startup_ms": 5000, "turn_ms": 5000, "policy": policy()})
    limits = {"max_attempts": 2, "total_ms": 600000, "max_llm_calls": 4, "tokens_per_call": 32768,
        "max_tokens": 131072, "max_cost_microunits": 0, "cost_per_call_microunits": 0,
        "max_patch_bytes": 4096, "max_diagnostic_bytes": 1024, "max_source_calls": 10,
        "max_source_bytes": 40960, "source_page_bytes": 4096, "build_ms": 20000,
        "evaluation_ms": 180000, "cpu_ms": 300000, "memory_bytes": 536870912,
        "processes": 64, "disk_reserve_bytes": 1 << 62}
    retention = {"promoted_generations": "all", "rejected_attempts": "all", "audit": "all"}
    settings = {"AE_RUNTIME_ISOLATION": "bubblewrap", "AE_RESOURCE_LIMITS_MODE": "process",
        "AE_SANDBOX_LIMITS_JSON": json.dumps(sandbox), "AE_EVOLUTION_ENABLED": "true",
        "AE_EVOLUTION_LIMITS_JSON": json.dumps(limits), "AE_BUILD_CONFIG_JSON": json.dumps(builder),
        "AE_EVAL_CONFIG_JSON": json.dumps(evaluator), "AE_APPROVAL_TTL_MS": "60000", "AE_OBSERVE_MS": "1000",
        "AE_HEALTH_INTERVAL_MS": "50", "AE_QUIESCE_TIMEOUT_MS": "1000"}
    try:
        with tempfile.TemporaryDirectory(prefix="ae-storage-policy-") as directory:
            root = Path(directory)
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True, capture_output=True)
            for label, selected in (("missing", {}), ("invalid", {**retention, "audit": 0}), ("all", retention)):
                controller = Controller(root, server.server_port, {**settings, "AE_RETENTION_POLICY_JSON": json.dumps(selected)})
                try:
                    until = time.monotonic() + 5
                    while True:
                        state = controller.command("evolution")
                        if state["state"] != "recovering":
                            break
                        assert time.monotonic() < until
                        time.sleep(0.02)
                    assert state["enabled"] is (label == "all"), state
                    before = len(CALLS)
                    result = controller.command("evolve", origin_ref="pressure-" + label, objective="must not spend")
                    assert result == {"error": "storage_pressure" if label == "all" else "evolution_disabled"}, result
                    assert len(CALLS) == before
                    assert turn(controller, "service-" + label, "hello")["text"] == "reply:hello"
                    with sqlite3.connect(root / "state/agent.sqlite3") as connection:
                        assert connection.execute("SELECT COUNT(*) FROM evolution_jobs").fetchone()[0] == 0
                    assert not list((root / "workspaces").iterdir())
                finally:
                    controller.close()
            with sqlite3.connect(root / "state/agent.sqlite3") as connection:
                saved = json.loads(connection.execute("SELECT data FROM control WHERE name='retention_policy'").fetchone()[0])
                assert saved == retention
    finally:
        server.shutdown()
        server.server_close()
    print("Storage policy passed: explicit retention, persisted policy, no spending under pressure and continuing service.")


if __name__ == "__main__":
    main()
