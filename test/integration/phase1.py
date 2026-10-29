#!/usr/bin/env python3
"""Real dual-slot handoffs with independent mock staging and crash injection."""
import difflib
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from phase0 import CALLS, CHECKOUT, Controller, Provider, turn

SETTINGS = {"AE_APPROVAL_TTL_MS": "60000", "AE_OBSERVE_MS": "3000",
            "AE_HEALTH_INTERVAL_MS": "50", "AE_QUIESCE_TIMEOUT_MS": "1000"}


def publish(root, transform, name):
    with sqlite3.connect(root / "state/agent.sqlite3") as connection:
        base = json.loads(connection.execute("SELECT data FROM routing").fetchone()[0])["artifact"]
    path = "apps/ae_seed/src/seed_agent.erl"
    original = subprocess.check_output(["git", "--git-dir", str(root / "source.git"),
        "show", base["source_revision"] + ":" + path]).decode()
    changed = transform(original)
    assert changed != original
    patch = root / (name + ".patch")
    patch.write_text("".join(difflib.unified_diff(original.splitlines(True), changed.splitlines(True),
        fromfile="a/" + path, tofile="b/" + path)))
    result = subprocess.run([str(CHECKOUT / "scripts/publish_candidate"), "--data-root", str(root),
        "--patch", str(patch), "--objective", name], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    manifest = json.loads(result.stdout.splitlines()[-1])
    assert manifest["parent"] == base["digest"]
    parent = subprocess.check_output(["git", "--git-dir", str(root / "source.git"),
        "rev-parse", manifest["source_revision"] + "^"]).decode().strip()
    assert parent == base["source_revision"]
    return manifest


def stage(controller, manifest):
    before = len(CALLS)
    result = controller.command("stage", artifact_digest=manifest["digest"])
    assert "deployment_id" in result, result
    assert result["evaluation"]["production_tools"] is False
    assert len(CALLS) == before, "staging invoked the production LLM"
    return result


def approve(controller, staged):
    result = controller.command("approve", deployment_id=staged["deployment_id"],
        approval_binding=staged["approval_binding"])
    assert result.get("ok") is True, result
    return result["routing"]


def await_job(controller, deployment, status):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        job = controller.command("deployment", deployment_id=deployment)
        if job.get("status") == status:
            return job
        time.sleep(0.05)
    raise AssertionError(f"deployment did not reach {status}: {job}")


def await_slot(controller, slot, old_epoch):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = controller.command("status")
        route = result.get("routing", {})
        if route.get("epoch", 0) > old_epoch and route.get("slot") == slot and result.get("runtime_health") == "ok":
            return result
        time.sleep(0.05)
    raise AssertionError(f"slot {slot} did not recover: {result}")


def main():
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    controller = None
    with tempfile.TemporaryDirectory(prefix="ae-phase1-") as directory:
        root = Path(directory)
        try:
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True)
            controller = Controller(root, provider.server_port, SETTINGS)
            first = controller.command("status")
            seed = first["routing"]["artifact"]
            assert first["routing"]["slot"] == "adam"
            assert turn(controller, "remember", "remember saffron", "memory")["committed"] is True

            g2 = publish(root, lambda s: s.replace('<<"text">> => Text, <<"event_refs">> => []',
                '<<"text">> => <<"g2:", Text/binary>>, <<"event_refs">> => []'), "manual-g2")
            bad = publish(root, lambda s: s.replace('<<"supported_schema_versions">> => [1]',
                '<<"supported_schema_versions">> => [2]'), "incompatible-schema")
            before = controller.command("status")["routing"]
            assert controller.command("stage", artifact_digest=bad["digest"])["error"] == "staging_failed"
            assert controller.command("status")["routing"] == before

            staged = stage(controller, g2)
            assert staged["standby_os_pid"] != first["os_pid"]
            assert controller.command("status")["routing"] == before
            assert turn(controller, "while-pending", "active serves while approval waits")["text"].startswith("reply:")
            mismatch = controller.command("approve", deployment_id=staged["deployment_id"], approval_binding="different")
            assert mismatch["error"] == "approval_mismatch"
            assert controller.command("reject", deployment_id=staged["deployment_id"]) == {"ok": True}

            staged = stage(controller, g2)
            os.kill(staged["standby_os_pid"], signal.SIGKILL)
            await_job(controller, staged["deployment_id"], "rejected")
            assert controller.command("status")["routing"] == before

            # Exact contents must still match at promotion, even if a process is already staged.
            staged = stage(controller, g2)
            executable = root / "artifacts" / g2["digest"] / "seed"
            contents = executable.read_bytes()
            executable.chmod(0o644)
            executable.write_bytes(contents + b"altered after staging")
            result = controller.command("approve", deployment_id=staged["deployment_id"],
                approval_binding=staged["approval_binding"])
            assert result["error"] == "promotion_failed"
            assert controller.command("status")["routing"] == before
            executable.write_bytes(contents)
            executable.chmod(0o444)

            # Active replacement invalidates the staged approval, even for the same code.
            staged = stage(controller, g2)
            os.kill(controller.command("status")["os_pid"], signal.SIGKILL)
            replaced = await_slot(controller, "adam", before["epoch"])
            await_job(controller, staged["deployment_id"], "rejected")
            assert replaced["routing"]["artifact"] == seed

            staged = stage(controller, g2)
            eve = approve(controller, staged)
            assert eve["slot"] == "eve" and eve["epoch"] > replaced["routing"]["epoch"]
            assert turn(controller, "eve-recall", "recall", "memory")["text"] == "g2:reply:saffron"
            await_job(controller, staged["deployment_id"], "completed")

            g3 = publish(root, lambda s: s.replace('<<"g2:", Text/binary>>',
                '<<"g3:g2:", Text/binary>>'), "manual-g3")
            staged = stage(controller, g3)
            adam = approve(controller, staged)
            assert adam["slot"] == "adam" and adam["epoch"] > eve["epoch"]
            assert turn(controller, "adam-recall", "recall", "memory")["text"] == "g3:g2:reply:saffron"
            await_job(controller, staged["deployment_id"], "completed")

            controller.close()
            shutil.rmtree(root / "workspaces")
            (root / "bootstrap.json").unlink()
            controller = Controller(root, provider.server_port, SETTINGS)
            restored = controller.command("status")
            assert restored["routing"]["artifact"] == g3
            assert turn(controller, "adam-recall", "recall", "memory")["text"] == "g3:g2:reply:saffron"

            g4 = publish(root, lambda s: s.replace('<<"g3:g2:", Text/binary>>',
                '<<"g4:g3:g2:", Text/binary>>'), "manual-g4")
            staged = stage(controller, g4)
            switched = approve(controller, staged)
            assert switched["slot"] == "eve"
            candidate_reply = turn(controller, "observed-reply", "retained through rollback")
            assert candidate_reply["text"] == "g4:g3:g2:reply:retained through rollback"
            calls = len(CALLS)
            os.kill(controller.command("status")["os_pid"], signal.SIGKILL)
            await_job(controller, staged["deployment_id"], "rolled_back")
            rollback = await_slot(controller, "adam", switched["epoch"])
            assert rollback["routing"]["artifact"] == g3
            assert turn(controller, "observed-reply", "retained through rollback") == candidate_reply
            assert len(CALLS) == calls

            # A committed promotion interrupted during observation rolls back on boot,
            # through the latest conversation and pending task ledger, not an old snapshot.
            staged = stage(controller, g4)
            switched = approve(controller, staged)
            reply = turn(controller, "before-reboot", "acknowledged by candidate")
            assert "error" in turn(controller, "pending-before-reboot", "unavailable")
            calls = len(CALLS)
            controller.process.kill()
            controller.process.wait(5)
            controller.close()
            controller = Controller(root, provider.server_port, SETTINGS)
            rollback = await_slot(controller, "adam", switched["epoch"])
            job = await_job(controller, staged["deployment_id"], "rolled_back")
            assert job["reason"] == "controller_restarted_during_observation"
            assert rollback["routing"]["artifact"] == g3
            assert turn(controller, "before-reboot", "acknowledged by candidate") == reply
            assert "error" in turn(controller, "pending-before-reboot", "unavailable")
            assert len(CALLS) == calls
            assert controller.command("cancel", request_id="pending-before-reboot") == {"ok": True}

            staged = stage(controller, g4)
            before = controller.command("status")["routing"]
            controller.process.kill()
            controller.process.wait(5)
            controller.close()
            controller = Controller(root, provider.server_port, SETTINGS)
            current = await_slot(controller, "adam", before["epoch"])
            assert current["routing"]["artifact"] == g3
            await_job(controller, staged["deployment_id"], "rejected")
            assert controller.command("approve", deployment_id=staged["deployment_id"],
                approval_binding=staged["approval_binding"])["error"] == "invalid_deployment_state"

            controller.close()
            controller = Controller(root, provider.server_port, {**SETTINGS, "AE_APPROVAL_TTL_MS": "1500"})
            before = controller.command("status")["routing"]
            staged = stage(controller, g4)
            await_job(controller, staged["deployment_id"], "rejected")
            assert controller.command("status")["routing"] == before

            # Exhaust the bounded runner restart policy. The trusted controller
            # must remain available for inspection and explicit recovery.
            for failure in range(4):
                before = controller.command("status")
                os.kill(before["os_pid"], signal.SIGKILL)
                if failure < 3:
                    await_slot(controller, "adam", before["routing"]["epoch"])
                else:
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        state = controller.command("status")
                        if state.get("runtime_health") == "degraded":
                            break
                        time.sleep(0.05)
                    assert state["runtime_health"] == "degraded", state
                    assert state["routing"]["admission"] == "closed"
                    assert controller.process.poll() is None
                    assert "events" in controller.command("history")
            assert controller.command("restart") == {"ok": True}
            assert controller.command("status")["runtime_health"] == "ok"

            with sqlite3.connect(root / "state/agent.sqlite3") as connection:
                assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                assert connection.execute("SELECT COUNT(*) FROM turns WHERE request_id='observed-reply'").fetchone() == (1,)
                assert connection.execute("SELECT COUNT(*) FROM tools WHERE request_id='observed-reply' AND status='completed'").fetchone() == (1,)
                assert connection.execute("SELECT COUNT(*) FROM checkpoints").fetchone()[0] >= 5
                good = json.loads(connection.execute("SELECT data FROM control WHERE name='last_known_good'").fetchone()[0])
                assert good["artifact"] == g3
            for manifest in (seed, g2, g3, g4):
                assert (root / "artifacts" / manifest["digest"] / "seed").exists()
                subprocess.run(["git", "--git-dir", str(root / "source.git"), "cat-file", "-e",
                    "refs/generations/" + manifest["digest"]], check=True)
            controller.close()
            result = subprocess.run(["escript", str(CHECKOUT / "test/integration/controller_faults.escript"),
                g4["digest"]], cwd=CHECKOUT, capture_output=True, text=True,
                env={**os.environ, **SETTINGS, "AE_QUIESCE_TIMEOUT_MS": "5000", "AE_DATA_ROOT": str(root),
                     "AE_LLM_MODEL": "fixture", "AE_LLM_URL": f"http://127.0.0.1:{provider.server_port}/api/chat"},
                timeout=30)
            assert result.returncode == 0, result.stdout + result.stderr
            # Valid retained bytes can still contain code that cannot boot. That
            # must not take down the trusted controller's inspection interface.
            fault_root = root / "broken-identity"
            fault_root.mkdir(mode=0o700)
            shutil.copytree(root / "source.git", fault_root / "source.git")
            bad_release = root / "artifacts" / bad["digest"]
            shutil.copytree(bad_release, fault_root / "artifacts" / bad["digest"])
            (fault_root / "bootstrap.json").write_text(json.dumps(bad))
            broken = Controller(fault_root, provider.server_port, SETTINGS)
            try:
                assert broken.command("status")["runtime_health"] == "degraded"
                assert turn(broken, "cannot-serve", "hello")["error"] == "runtime_unavailable"
                assert "events" in broken.command("history")
                assert broken.process.poll() is None
            finally:
                broken.close()
            print("Phase 1 integration passed: Adam -> Eve -> Adam, approvals, retained lineage, crash/restart rollback")
        finally:
            if controller:
                controller.close()
            provider.shutdown()
            provider.server_close()


if __name__ == "__main__":
    main()
