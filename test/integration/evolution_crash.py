#!/usr/bin/env python3
"""SIGKILL the controller around durable generated-deployment boundaries."""
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

from authoring import Provider
from phase0 import CHECKOUT, Controller, turn

ARRIVED = threading.Event()
RELEASE = threading.Event()


class CrashProvider(Provider):
    block = False

    def do_POST(self):
        if self.block:
            data = self.rfile.read(int(self.headers["Content-Length"]))
            self.rfile = io.BytesIO(data)
            if isinstance(json.loads(data).get("format"), dict):
                ARRIVED.set()
                assert RELEASE.wait(60), "test did not release the reserved model call"
        try:
            super().do_POST()
        except (BrokenPipeError, ConnectionResetError):
            pass  # The requesting controller was deliberately killed.


def wait(controller, inspect, predicate, seconds=180):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = inspect()
        if predicate(value):
            return value
        assert controller.process.poll() is None, "controller exited while recovering"
        time.sleep(0.05)
    raise AssertionError(f"controller state timed out: {value}")


def ready(controller):
    return wait(controller, lambda: controller.command("evolution"),
        lambda status: status["state"] not in ("recovering", "rollback"))


def job_at(controller, identity, status):
    def reached(job):
        assert job["status"] not in {"cancelled", "rejected", "degraded", "rolled_back"} - {status}, job
        return job["status"] == status
    return wait(controller, lambda: controller.command("evolution", job_id=identity), reached)


def kill(controller):
    controller.process.kill()
    controller.process.wait(10)
    controller.close()


def settings():
    mode = os.environ.get("AE_TEST_RESOURCE_LIMITS_MODE", "process")
    cgroup = os.environ.get("AE_TEST_CGROUP_ROOT", "/sys/fs/cgroup")
    sandbox = {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": 20,
        "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
        "output_bytes": 16777216, "wall_ms": 60000}
    builder = {"cgroup_root": cgroup, "resource_limits_mode": mode,
        "jsx_package": os.environ.get("AE_JSX_PACKAGE", str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar")),
        "source_bytes": 2097152, "source_files": 128, "artifact_bytes": 8388608, "sandbox_limits": sandbox}
    limits = {"max_attempts": 2, "total_ms": 600000, "max_llm_calls": 4,
        "tokens_per_call": 32768, "max_tokens": 131072, "max_cost_microunits": 0,
        "cost_per_call_microunits": 0, "max_patch_bytes": 65536, "max_diagnostic_bytes": 4096,
        "max_source_calls": 10, "max_source_bytes": 65536, "source_page_bytes": 16384,
        "build_ms": 60000, "evaluation_ms": 180000, "cpu_ms": 240000,
        "memory_bytes": 536870912, "processes": 64, "disk_reserve_bytes": 1048576}
    import sys
    sys.path.insert(0, str(CHECKOUT / "test/evaluation"))
    import test_evaluate
    evaluation = {key: value for key, value in builder.items() if key != "jsx_package"}
    evaluation.update({"startup_ms": 30000, "turn_ms": 15000, "policy": test_evaluate.policy(),
        "sandbox_limits": {**sandbox, "wall_ms": 180000, "cpu_seconds": 30}})
    return {"AE_RUNTIME_ISOLATION": "bubblewrap", "AE_RESOURCE_LIMITS_MODE": mode,
        "AE_CGROUP_ROOT": cgroup, "AE_SANDBOX_LIMITS_JSON": json.dumps({**sandbox,
            "cpu_seconds": 240, "wall_ms": 600000, "output_bytes": 65536}),
        "AE_EVOLUTION_ENABLED": "true", "AE_EVOLUTION_LIMITS_JSON": json.dumps(limits),
        "AE_BUILD_CONFIG_JSON": json.dumps(builder), "AE_EVAL_CONFIG_JSON": json.dumps(evaluation),
        "AE_RETENTION_POLICY_JSON": json.dumps({"promoted_generations": "all", "rejected_attempts": "all", "audit": "all"}),
        "AE_APPROVAL_TTL_MS": "120000", "AE_OBSERVE_MS": "60000", "AE_HEALTH_INTERVAL_MS": "100",
        "AE_QUIESCE_TIMEOUT_MS": "5000"}


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), CrashProvider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="ae-evolution-crash-") as directory:
            parent = Path(directory)
            seed = parent / "seed"
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(seed)],
                check=True, capture_output=True)
            config = settings()
            for phase in ("authoring", "awaiting_approval", "observing"):
                print("Controller crash boundary: " + phase, flush=True)
                root = parent / phase
                shutil.copytree(seed, root)
                root.chmod(0o700)
                CrashProvider.scenario = "deployment-rollback"
                CrashProvider.requests = []
                CrashProvider.conversation_requests = 0
                CrashProvider.block = phase == "authoring"
                ARRIVED.clear()
                RELEASE.clear()
                controller = Controller(root, server.server_port, config)
                try:
                    ready(controller)
                    before = controller.command("status")["routing"]
                    acknowledged = turn(controller, "baseline-ack", "hello")
                    assert acknowledged["committed"] and acknowledged["text"] == "conversation still works"
                    objective = "Improve the greeting; preserve existing behavior."
                    job = controller.command("evolve", origin_ref=phase, objective=objective)
                    identity = job["id"]
                    if phase == "authoring":
                        assert ARRIVED.wait(15), "model reservation did not reach HTTP"
                        job = controller.command("evolution", job_id=identity)
                        assert job["llm_calls"] == 1 and job["reserved_tokens"] == 32768
                        with sqlite3.connect(root / "state/agent.sqlite3") as database:
                            calls = [json.loads(row[0]) for row in database.execute("SELECT data FROM evolution_llm_calls")]
                        assert len(calls) == 1 and calls[0]["status"] == "reserved", calls
                    else:
                        job = job_at(controller, identity, "awaiting_approval")
                        assert all(job["evaluations"]["1"]["scorecard"]["gates"].values())
                        assert controller.command("status")["routing"]["artifact"] == before["artifact"]
                        if phase == "observing":
                            approval = controller.command("approve", deployment_id=job["deployment_id"],
                                approval_binding=job["approval_binding"])
                            assert approval["ok"] and approval["routing"]["slot"] == "eve", approval
                            job = job_at(controller, identity, "observing")
                            acknowledged = turn(controller, "candidate-ack", "hello")
                            assert acknowledged["committed"] and acknowledged["text"] == "authored:conversation still works"
                    tokens, cpu = job["reserved_tokens"], job.get("reserved_cpu_ms", 0)
                    previous_epoch = controller.command("status")["routing"]["epoch"]
                    kill(controller)
                    RELEASE.set()
                    wait_deadline = time.monotonic() + 5
                    while phase == "authoring" and not CrashProvider.requests and time.monotonic() < wait_deadline:
                        time.sleep(0.01)
                    author_calls = len(CrashProvider.requests)
                    controller = Controller(root, server.server_port, config)
                    ready(controller)
                    expected = {"authoring": "cancelled", "awaiting_approval": "rejected", "observing": "rolled_back"}[phase]
                    recovered = job_at(controller, identity, expected)
                    assert recovered["reserved_tokens"] == tokens and recovered.get("reserved_cpu_ms", 0) == cpu
                    assert len(CrashProvider.requests) == author_calls, "restart reissued model authoring"
                    route = controller.command("status")["routing"]
                    assert route["artifact"] == before["artifact"] and route["epoch"] > previous_epoch
                    request = "candidate-ack" if phase == "observing" else "baseline-ack"
                    count = CrashProvider.conversation_requests
                    assert turn(controller, request, "hello") == acknowledged
                    assert CrashProvider.conversation_requests == count, "acknowledged turn was reissued"
                    assert turn(controller, "post-recovery", "hello")["text"] == "conversation still works"
                    assert controller.command("evolve", origin_ref=phase, objective=objective)["id"] == identity
                    if phase != "authoring":
                        assert controller.command("approve", deployment_id=job["deployment_id"],
                            approval_binding=job["approval_binding"]).get("error"), "old approval was reused"
                        artifact = job["built_artifact"]
                        assert (root / "artifacts" / artifact["digest"] / "seed").is_file()
                        revision = subprocess.check_output(["git", "--git-dir", str(root / "source.git"),
                            "rev-parse", "refs/generations/" + artifact["digest"]], text=True).strip()
                        assert revision == artifact["source_revision"]
                finally:
                    RELEASE.set()
                    controller.close()
    finally:
        RELEASE.set()
        server.shutdown()
        server.server_close()
    print("Controller crash recovery passed: unknown authoring is not reissued; pending approval is rejected; observed promotion rolls back without losing acknowledged work or retained code.")


if __name__ == "__main__":
    main()
