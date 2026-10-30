#!/usr/bin/env python3
"""Online WAL backup, clean restore, effect fencing and acknowledged replay drill."""
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer

from phase0 import CHECKOUT, CALLS, IN_FLIGHT, RELEASE, Controller, Provider, turn
from phase1 import SETTINGS, publish, stage, approve


def run(name, *arguments, ok=True):
    result = subprocess.run([str(CHECKOUT / "scripts" / name), *map(str, arguments)],
                            text=True, capture_output=True, timeout=60)
    assert (result.returncode == 0) == ok, result.stderr
    if not ok:
        return result.stderr
    return json.loads(result.stdout) if name != "publish_seed" else result.stdout


def backup(root, backups, policy):
    return run("backup", "--data-root", root, "--backup-root", backups, "--policy", policy)


def restore(saved, root, floor, failure_time, ok=True):
    return run("restore", "--backup", saved["path"], "--data-root", root,
               "--epoch-floor", floor, "--failure-time-ms", failure_time, ok=ok)


def rehash_backup(root):
    """Give a deliberately incomplete set valid transport checksums, not valid closure."""
    manifest = root / "manifest.json"
    record = json.loads(manifest.read_bytes())
    record["files"] = {p.relative_to(root / "data").as_posix(): {
        "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
        for p in (root / "data").rglob("*") if p.is_file()}
    encoded = (json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    manifest.write_bytes(encoded)
    renamed = root.parent / hashlib.sha256(encoded).hexdigest()
    root.rename(renamed)
    return {"path": str(renamed)}


def main():
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    controller = None
    with tempfile.TemporaryDirectory(prefix="ae-recovery-") as directory:
        parent = Path(directory)
        source, target, backups = (parent / name for name in ("source", "restored", "backups"))
        source.mkdir(mode=0o700)
        policy = parent / "policy.json"
        policy.write_text(json.dumps({"schedule": "manual integration drill", "minimum_copies": 2,
            "rpo_ms": 60000, "rto_ms": 60000, "failure_domain": "local disposable test disk",
            "disk_reserve_bytes": 1024 * 1024}))
        run("publish_seed", "--data-root", source)
        controller = Controller(source, provider.server_port, {"AE_RETENTION_POLICY_JSON": json.dumps({
            "promoted_generations": "all", "rejected_attempts": "all", "audit": "all"})})
        try:
            original = controller.command("status")
            assert turn(controller, "committed", "remember saffron")["committed"] is True
            partial = source / "artifacts/.publishing-drillxxx"
            partial.mkdir(mode=0o700)
            (partial / "seed").write_bytes(b"interrupted publication")
            assert run("cleanup", "--data-root", source)["remaining_publications"] == [partial.name]
            cleaned = run("cleanup", "--data-root", source, "--apply")
            assert cleaned["remaining_publications"] == [] and not partial.exists()
            controller.send({"op": "turn", "request_id": "unknown", "session_id": "main", "message": "pause"})
            assert IN_FLIGHT.wait(10)
            # The live WAL contains both an acknowledged reply and a reserved effect.
            assert (source / "state/agent.sqlite3-wal").stat().st_size > 0
            saved = backup(source, backups, policy)
            failure_time = time.time_ns() // 1_000_000
            floor = original["routing"]["epoch"] + 100
            # No automatic failover: stop the original identity before enabling a copy.
            controller.process.kill()
            controller.process.wait(5)
            controller.close()
            controller = None
            RELEASE.set()
            count = len(CALLS)

            # Environment policy is mandatory; reserve failures leave no complete set.
            invalid_policy = parent / "invalid-policy.json"
            invalid_policy.write_text("{}")
            run("backup", "--data-root", source, "--backup-root", backups,
                "--policy", invalid_policy, ok=False)
            record = json.loads(policy.read_text())
            invalid_policy.write_text(json.dumps({**record,
                "disk_reserve_bytes": shutil.disk_usage(parent).free + 1}))
            run("backup", "--data-root", source, "--backup-root", backups,
                "--policy", invalid_policy, ok=False)
            assert sorted(p.name for p in backups.iterdir()) == [saved["backup_id"]]

            for bad_floor, bad_time, name in ((0, failure_time, "bad-floor"),
                    (floor, failure_time + 60001, "bad-rpo")):
                assert restore(saved, parent / name, bad_floor, bad_time, ok=False)
                assert not (parent / name).exists()
            existing = parent / "existing"
            existing.mkdir(mode=0o700)
            (existing / "keep").write_text("must survive")
            restore(saved, existing, floor, failure_time, ok=False)
            assert (existing / "keep").read_text() == "must survive"

            # Hash or link corruption is refused before any new identity is published.
            corrupt = parent / "corrupt" / saved["backup_id"]
            corrupt.parent.mkdir(mode=0o700)
            shutil.copytree(saved["path"], corrupt)
            artifact = next((corrupt / "data/artifacts").glob("*/seed"))
            artifact.write_bytes(artifact.read_bytes() + b"corrupt")
            restore({**saved, "path": str(corrupt)}, parent / "bad-copy", floor, failure_time, ok=False)
            assert not (parent / "bad-copy").exists()
            artifact.unlink()
            artifact.symlink_to("/etc/passwd")
            restore({**saved, "path": str(corrupt)}, parent / "bad-link", floor, failure_time, ok=False)
            assert not (parent / "bad-link").exists()

            incomplete = corrupt.parent / "incomplete"
            shutil.copytree(saved["path"], incomplete)
            subprocess.run(["git", "--git-dir", str(incomplete / "data/source.git"), "update-ref",
                "-d", "refs/generations/" + original["routing"]["artifact"]["digest"]], check=True)
            incomplete_saved = rehash_backup(incomplete)
            restore(incomplete_saved, parent / "bad-source", floor, failure_time, ok=False)
            assert not (parent / "bad-source").exists()

            started = time.monotonic()
            restored = restore(saved, target, floor, failure_time)
            assert restored["verification_required"] is True
            assert not (target / "workspaces").exists()
            controller = Controller(target, provider.server_port)
            state = controller.command("status")
            assert state["runtime_health"] == "ok", state
            assert state["recovery"]["pending"] is True
            assert state["routing"]["epoch"] > floor
            assert state["routing"]["artifact"] == original["routing"]["artifact"]
            assert state["routing"]["admission"] == "closed"
            assert turn(controller, "new", "must wait")["error"] == "restore_verification_required"
            assert turn(controller, "committed", "remember saffron")["error"] == "restore_verification_required"
            assert controller.command("restore_ready", backup_id="wrong", origin_ref="drill")["error"] == "backup_mismatch"
            assert len(CALLS) == count
            # The pending fence survives another process start and checkpoint restore.
            controller.close()
            controller = Controller(target, provider.server_port)
            assert controller.command("status")["recovery"]["pending"] is True
            assert controller.command("restore_ready", backup_id=saved["backup_id"],
                origin_ref="drill: original stopped; outstanding effects reconciled") == {"ok": True}
            assert controller.command("restore_ready", backup_id=saved["backup_id"], origin_ref="repeat") == {"ok": True}
            assert turn(controller, "committed", "remember saffron")["text"] == "reply:remember saffron"
            assert turn(controller, "unknown", "pause")["error"] == "tool_outcome_unknown"
            assert len(CALLS) == count
            assert controller.command("cancel", request_id="unknown") == {"ok": True}
            assert turn(controller, "recall", "recall")["text"] == "reply:saffron"
            elapsed = int((time.monotonic() - started) * 1000)
            assert elapsed <= restored["rto_budget_ms"], elapsed
            history = controller.command("history")["events"]
            assert any(e["seq"] == saved["recovery_point"]["event_seq"] for e in history)
            assert sum(e["kind"] == "restore_verified" for e in history) == 1
            assert sum(e["kind"] == "storage_cleanup_completed" and
                e["data"]["id"] == cleaned["cleanup_id"] for e in history) == 1
            assert sum(e["kind"] == "assistant_reply" and e["data"]["request_id"] == "committed" for e in history) == 1
            # A restored identity can itself be backed up without losing its audit/floor.
            again = backup(target, backups, policy)
            assert again["recovery_point"]["routing"]["epoch"] > floor
            controller.close()
            controller = None
            with sqlite3.connect(target / "state/agent.sqlite3") as connection:
                assert connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)]
            print(f"Recovery drill passed: online WAL snapshot, source/artifact integrity, fenced replay; RPO {restored['rpo_ms']} ms, service RTO {elapsed} ms (local test policy).")

            # A snapshot made during observation restores the predecessor code,
            # with all replies committed by the candidate, and remains fenced.
            settings = {**SETTINGS, "AE_OBSERVE_MS": "60000"}
            controller = Controller(target, provider.server_port, settings)
            base = controller.command("status")["routing"]
            candidate = publish(target, lambda s: s.replace('<<"text">> => Text, <<"event_refs">> => []',
                '<<"text">> => <<"candidate:", Text/binary>>, <<"event_refs">> => []'), "backup-observing")
            staged = stage(controller, candidate)
            promoted = approve(controller, staged)
            assert turn(controller, "by-candidate", "recall")["text"] == "candidate:reply:saffron"
            during_observation = backup(target, backups, policy)
            failure_time = time.time_ns() // 1_000_000
            controller.close()
            controller = None
            count = len(CALLS)
            observed_target = parent / "observation-restored"
            restore(during_observation, observed_target, promoted["epoch"] + 100, failure_time)
            controller = Controller(observed_target, provider.server_port, settings)
            state = controller.command("status")
            assert state["runtime_health"] == "ok", state
            assert state["routing"]["artifact"] == base["artifact"]
            assert state["routing"]["slot"] == base["slot"]
            assert state["routing"]["epoch"] > promoted["epoch"] + 100
            assert state["routing"]["admission"] == "closed"
            assert state["recovery"]["pending"] is True
            assert controller.command("deployment", deployment_id=staged["deployment_id"])["status"] == "rolled_back"
            assert controller.command("restore_ready", backup_id=during_observation["backup_id"],
                origin_ref="observation drill: original stopped and effects reconciled") == {"ok": True}
            assert turn(controller, "by-candidate", "recall")["text"] == "candidate:reply:saffron"
            assert len(CALLS) == count
            assert turn(controller, "after-rollback", "recall")["text"] == "reply:saffron"
            controller.close()
            controller = None
            print("Observation restore drill passed: predecessor code, candidate-committed reply and a new fenced epoch.")
        finally:
            RELEASE.set()
            if controller:
                controller.close()
            provider.shutdown()
            provider.server_close()


if __name__ == "__main__":
    main()
