#!/usr/bin/env python3
"""Versioned semantic memory survives context eviction, handoff, rollback and backup."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from contextlib import ExitStack
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

from phase0 import CHECKOUT, Controller, turn
from phase1 import SETTINGS, approve, await_job, await_slot, publish, stage
from recovery import backup, rehash_backup, restore


class Provider(BaseHTTPRequestHandler):
    calls = 0

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        type(self).calls += 1
        message = body["messages"][-1]["content"]
        if message == "recall-memory":
            assert not any(m["role"] == "user" and m["content"] == "remember saffron" for m in body["messages"])
            memory = next(m["content"] for m in body["messages"] if m["role"] == "system")
            snapshot = json.loads(memory[memory.index("{"):])
            entry = next(entry for entry in snapshot["entries"] if entry["key"] == "favorite-color")
            assert entry["source_event_seqs"] and entry["kind"] == "preference"
            text = "memory:" + entry["value"]
        else:
            text = "reply:" + message
        encoded = json.dumps({"done": True, "message": {"content": text}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_):
        pass


def source_event(controller, request):
    return next(event["seq"] for event in controller.command("history")["events"]
                if event["kind"] == "user_message" and event["data"]["request_id"] == request)


def main():
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    limits = {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": 600,
        "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
        "output_bytes": 65536, "wall_ms": 1800000}
    settings = {**SETTINGS, "AE_OBSERVE_MS": "10000", "AE_RUNTIME_ISOLATION": "bubblewrap",
        "AE_RESOURCE_LIMITS_MODE": "process", "AE_SANDBOX_LIMITS_JSON": json.dumps(limits)}
    controller = None
    def close_controller():
        nonlocal controller
        if controller is not None:
            controller.close()
            controller = None
    try:
        with tempfile.TemporaryDirectory(prefix="ae-semantic-memory-") as directory, ExitStack() as cleanup:
            cleanup.callback(close_controller)
            parent = Path(directory)
            root, restored, backups = (parent / name for name in ("source", "restored", "backups"))
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True, capture_output=True)
            controller = Controller(root, provider.server_port, settings)
            assert turn(controller, "source", "remember saffron")["committed"]
            seq = source_event(controller, "source")
            first = controller.command("memory_put", origin_ref="color-1", kind="preference", key="favorite-color",
                value="saffron", source_event_seqs=[seq], expected_revision=0)
            assert first["revision"] == 1, first
            summary = controller.command("memory_put", origin_ref="summary-1", kind="summary", key="context",
                value="The user discussed favorite colors.", source_event_seqs=[seq], expected_revision=1)
            assert summary["revision"] == 2, summary
            for number in range(10):
                assert turn(controller, f"history-{number}", f"ordinary-{number}")["committed"]
            assert turn(controller, "recall-old", "recall-memory")["text"] == "memory:saffron"
            controller.close()
            controller = Controller(root, provider.server_port, settings)
            assert turn(controller, "recall-restart", "recall-memory")["text"] == "memory:saffron"
            assert controller.command("memory_get", kind="preference", key="favorite-color", revision=1) == first
            candidate = publish(root, lambda source: source.replace('<<"text">> => Text, <<"event_refs">> => []',
                '<<"text">> => <<"candidate:", Text/binary>>, <<"event_refs">> => []'), "memory-candidate")
            before = Provider.calls
            staged = stage(controller, candidate)
            assert Provider.calls == before
            route = approve(controller, staged)
            assert route["slot"] == "eve"
            assert turn(controller, "blue-source", "new preference blue")["committed"]
            blue_seq = source_event(controller, "blue-source")
            updated = controller.command("memory_put", origin_ref="color-2", kind="preference", key="favorite-color",
                value="blue", source_event_seqs=[blue_seq], expected_revision=2)
            assert updated["revision"] == 3
            acknowledged = turn(controller, "candidate-memory", "recall-memory")
            assert acknowledged["text"] == "candidate:memory:blue"
            os.kill(controller.command("status")["os_pid"], signal.SIGKILL)
            state = await_slot(controller, "adam", route["epoch"])
            await_job(controller, staged["deployment_id"], "rolled_back")
            before = Provider.calls
            assert turn(controller, "candidate-memory", "recall-memory") == acknowledged
            assert Provider.calls == before
            assert turn(controller, "after-rollback", "recall-memory")["text"] == "memory:blue"
            with sqlite3.connect(root / "state/agent.sqlite3") as connection:
                checkpoint = json.loads(connection.execute("SELECT data FROM checkpoints WHERE id=?",
                    (state["routing"]["checkpoint_id"],)).fetchone()[0])
            assert checkpoint["memory_revision"] == 3 and checkpoint["context_summary_ref"] == "memory-summary:2"
            policy = parent / "policy.json"
            policy.write_text(json.dumps({"schedule": "manual semantic memory drill", "minimum_copies": 2,
                "rpo_ms": 60000, "rto_ms": 60000, "failure_domain": "local disposable test disk",
                "disk_reserve_bytes": 1048576}))
            saved = backup(root, backups, policy)
            failed_at = time.time_ns() // 1000000
            floor = state["routing"]["epoch"] + 100
            controller.close()
            controller = None
            bad = parent / "corrupt" / saved["backup_id"]
            bad.parent.mkdir(mode=0o700)
            shutil.copytree(saved["path"], bad)
            connection = sqlite3.connect(bad / "data/state/agent.sqlite3")
            try:
                record = json.loads(connection.execute("SELECT data FROM memory_versions WHERE revision=3").fetchone()[0])
                record["source_event_seqs"] = [999999]
                connection.execute("UPDATE memory_versions SET data=? WHERE revision=3", (json.dumps(record),))
                connection.execute("UPDATE events SET data=? WHERE seq=?", (json.dumps({k: v for k, v in record.items()
                    if k != "event_seq"}), record["event_seq"]))
                connection.commit()
            finally:
                connection.close()
            corrupt = rehash_backup(bad)
            assert restore(corrupt, parent / "must-not-publish", floor, failed_at, ok=False)
            assert not (parent / "must-not-publish").exists()
            restore(saved, restored, floor, failed_at)
            controller = Controller(restored, provider.server_port, settings)
            assert controller.command("memory")["revision"] == 3
            denied = controller.command("memory_put", origin_ref="fenced", kind="fact", key="blocked",
                value="must wait", source_event_seqs=[seq], expected_revision=3)
            assert denied == {"error": "restore_verification_required"}
            assert controller.command("restore_ready", backup_id=saved["backup_id"], origin_ref="memory-restore") == {"ok": True}
            assert turn(controller, "after-restore", "recall-memory")["text"] == "memory:blue"
            assert controller.command("memory_get", kind="preference", key="favorite-color", revision=1) == first
            assert controller.command("memory_get", kind="preference", key="favorite-color", revision=3) == updated
        print("Semantic memory integration passed: context eviction, restart, handoff, rollback and verified fenced restore.")
    finally:
        close_controller()
        provider.shutdown()
        provider.server_close()


if __name__ == "__main__":
    main()
