#!/usr/bin/env python3
"""Model settings are chat-scoped; history and reset boundaries are topic-scoped."""
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT, Controller, turn
from recovery import run, rehash_backup

CALLS = []


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        CALLS.append(body)
        assert body["model"] in ("first", "second")
        assert "GLOBAL-PRIVATE-FACT" not in json.dumps(body)
        text = body["messages"][-1]["content"]
        data = json.dumps({"done": True, "message": {"content": body["model"] + ":" + text}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    controller = None
    try:
        with tempfile.TemporaryDirectory(prefix="ae-session-routing-") as directory:
            parent = Path(directory)
            root = parent / "identity"
            config = parent / "config.json"
            config.write_text(json.dumps({"default_provider": "one", "providers": {
                name: {"adapter": "ollama", "model": model, "base_url": f"http://127.0.0.1:{server.server_port}"}
                for name, model in (("one", "first"), ("two", "second"))}}))
            settings = {"AE_CONFIG_FILE": str(config)}
            run("publish_seed", "--data-root", root)
            controller = Controller(root, server.server_port, settings)
            a, b, other = "tg:42:100:0", "tg:42:100:99", "tg:42:200:0"
            assert turn(controller, "a1", "remember", a)["text"] == "first:remember"
            changed = controller.command("settings", session_id=b, field="provider", value="two")
            assert changed["effective"]["model"] == "second" and "api_key_env" not in json.dumps(changed)
            assert turn(controller, "b1", "other topic", b)["text"] == "second:other topic"
            assert len(CALLS[-1]["messages"]) == 1
            assert turn(controller, "a2", "recall", a)["text"] == "second:recall"
            assert CALLS[-1]["messages"][0]["content"] == "remember"
            source = next(e["seq"] for e in controller.command("history")["events"] if e["kind"] == "user_message")
            for revision, key, value in ((0, "global-private", "GLOBAL-PRIVATE-FACT"), (1, "tg:42:100:preference", "chat-A-only")):
                assert controller.command("memory_put", origin_ref=key, kind="fact", key=key,
                    value=value, source_event_seqs=[source], expected_revision=revision)["revision"] == revision + 1
            assert controller.command("new", session_id=a) == {"ok": True}
            assert controller.command("settings", session_id=a, field="thinking", value="off")["effective"]["thinking"] == "off"
            acknowledged = turn(controller, "a3", "fresh", a)
            assert acknowledged["text"] == "second:fresh" and CALLS[-1]["think"] is False
            assert len(CALLS[-1]["messages"]) == 2 and CALLS[-1]["messages"][0]["role"] == "system"
            assert "chat-A-only" in CALLS[-1]["messages"][0]["content"]
            assert turn(controller, "c1", "private", other)["text"] == "first:private"
            assert len(CALLS[-1]["messages"]) == 1 and "chat-A-only" not in json.dumps(CALLS[-1])
            controller.close()
            controller = Controller(root, server.server_port, settings)
            assert controller.command("settings", session_id=b)["effective"]["thinking"] == "off"
            count = len(CALLS)
            assert turn(controller, "a3", "fresh", a) == acknowledged and len(CALLS) == count
            controller.close()
            controller = None
            with sqlite3.connect(root / "state/agent.sqlite3") as database:
                pins = {request: json.loads(data) for request, data in database.execute("SELECT request_id,data FROM turn_settings")}
            assert pins["a1"]["model"] == "first" and pins["a2"]["model"] == "second"
            assert pins["a3"]["context_start"] > pins["a1"]["context_start"]
            policy = parent / "backup-policy.json"
            policy.write_text(json.dumps({"schedule": "local session test", "minimum_copies": 1, "rpo_ms": 60000,
                "rto_ms": 60000, "failure_domain": "local test disk", "disk_reserve_bytes": 1048576}))
            saved = run("backup", "--data-root", root, "--backup-root", parent / "backups", "--policy", policy)
            corrupt = parent / "corrupt"
            shutil.copytree(saved["path"], corrupt)
            with sqlite3.connect(corrupt / "data/state/agent.sqlite3") as database:
                database.execute("DELETE FROM turn_settings WHERE request_id='a3'")
            corrupt = rehash_backup(corrupt)
            error = run("restore", "--backup", corrupt["path"], "--data-root", parent / "must-not-restore",
                "--epoch-floor", saved["recovery_point"]["epoch_floor"], "--failure-time-ms", time.time_ns() // 1_000_000, ok=False)
            assert "pin unavailable" in error
        print("Session integration passed: provider pins, chat settings, topic resets, scoped memory, replay and backup validation.")
    finally:
        if controller:
            controller.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
