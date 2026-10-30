#!/usr/bin/env python3
"""Run the controller against a local Telegram and Ollama HTTP fixture."""
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT, Controller
from recovery import run

UPDATES = []
SENT = []
MODEL = []
TYPING = []
LOCK = threading.Lock()
RELEASE = threading.Event()


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/tags":
            data = json.dumps({"models": [{"name": "first"}, {"name": "second"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        assert self.path.endswith("/photos/test.png")
        data = b"\x89PNG\r\n\x1a\nfixture"
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        method = self.path.rsplit("/", 1)[-1]
        if self.path == "/api/chat":
            MODEL.append(body)
            if body["messages"][-1]["content"] == "pause":
                RELEASE.wait(20)
            result = {"done": True, "message": {"content": body["model"] + ":" + body["messages"][-1]["content"]}}
        elif method == "getMe":
            result = {"ok": True, "result": {"id": 42, "is_bot": True, "username": "example_bot"}}
        elif method == "getUpdates":
            with LOCK:
                updates = [u for u in UPDATES if u["update_id"] >= body["offset"]][:body["limit"]]
            result = {"ok": True, "result": updates}
        elif method == "sendMessage":
            SENT.append(body)
            result = {"ok": True, "result": {"message_id": len(SENT)}}
        elif method == "getFile":
            result = {"ok": True, "result": {"file_path": "photos/test.png", "file_size": 15}}
        elif method == "sendChatAction":
            TYPING.append(body)
            result = {"ok": True, "result": True}
        else:
            result = {"ok": True, "result": True}
        data = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def message(identity, chat, user, text, topic=0, kind="private"):
    return {"update_id": identity, "message": {"message_id": identity, "message_thread_id": topic,
        "chat": {"id": chat, "type": kind}, "from": {"id": user, "is_bot": False}, "text": text}}


def wait(predicate, description):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(description)


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    controller = None
    try:
        with tempfile.TemporaryDirectory(prefix="ae-telegram-") as directory:
            root = Path(directory) / "identity"
            config = Path(directory) / "config.json"
            url = f"http://127.0.0.1:{server.server_port}"
            config.write_text(json.dumps({"default_provider": "one", "providers": {
                "one": {"adapter": "ollama", "model": "first", "base_url": url},
                "two": {"adapter": "ollama", "model": "second", "base_url": url}},
                "telegram": {"enabled": True, "base_url": url, "token_env": "AE_TEST_BOT_TOKEN",
                    "allowed_users": [101], "allowed_groups": [-100], "admin_user_ids": [101], "poll_timeout_seconds": 0}}))
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True, capture_output=True)
            settings = {"AE_CONFIG_FILE": str(config), "AE_TEST_BOT_TOKEN": "123:fixture"}
            controller = Controller(root, server.server_port, settings)
            controller.command("status")
            with LOCK:
                UPDATES.extend([message(1, 202, 202, "secret"), message(2, -100, 303, "not addressed", kind="group"),
                    message(3, 101, 101, "hello"), message(4, -100, 303, "@example_bot group hello", 12, "group")])
            wait(lambda: len(MODEL) == 2 and len(SENT) >= 2, "authorized messages were not delivered")
            assert all("secret" not in json.dumps(m) and "not addressed" not in json.dumps(m) for m in MODEL)
            assert any(m.get("message_thread_id") == 12 and "group hello" in m["text"] for m in SENT)
            with LOCK:
                UPDATES.extend([message(5, 101, 101, "/provider two"), message(6, 101, 101, "after switch")])
            wait(lambda: any('"second"' in m["text"] for m in SENT), "provider switch failed")
            wait(lambda: any(m["model"] == "second" and m["messages"][-1]["content"] == "after switch" for m in MODEL), "new provider not used")
            wait(lambda: any("second:after switch" in m["text"] for m in SENT), "switched reply not delivered")
            photo = message(7, 101, 101, "photo caption")
            photo["message"]["photo"] = [{"file_id": "fixture-photo", "width": 20, "height": 20}]
            with LOCK:
                UPDATES.append(photo)
            wait(lambda: any(m["messages"][-1].get("images") for m in MODEL), "photo was not sent to the model")
            wait(lambda: any("second:photo caption" in m["text"] for m in SENT), "photo reply not delivered")
            source = next(e["seq"] for e in controller.command("history")["events"] if e["kind"] == "user_message")
            for revision, key, value in ((0, "global-private", "secret-global"), (1, "tg:42:101:note", "chat-note")):
                assert controller.command("memory_put", origin_ref=key, kind="fact", key=key,
                    value=value, source_event_seqs=[source], expected_revision=revision)["revision"] == revision + 1
            with LOCK:
                UPDATES.append(message(8, 101, 101, "/memory"))
            wait(lambda: any("chat-note" in m["text"] for m in SENT), "scoped memory not shown")
            assert all("secret-global" not in m["text"] for m in SENT)
            with LOCK:
                UPDATES.append(message(9, 101, 101, "/forget"))
            wait(lambda: any("Chat memory cleared" in m["text"] for m in SENT), "scoped memory not cleared")
            assert controller.command("memory_get", kind="fact", key="tg:42:101:note", revision=None)["deleted"] is True
            with LOCK:
                UPDATES.append(message(10, 101, 101, "pause"))
            wait(lambda: any(m["messages"][-1]["content"] == "pause" for m in MODEL), "in-flight request not started")
            with LOCK:
                UPDATES.extend([message(11, 101, 101, "/status"), message(12, 101, 101, "/cancel")])
            wait(lambda: any("Request cancelled" in m["text"] for m in SENT), "in-flight request not cancelled")
            RELEASE.set()
            with LOCK:
                UPDATES.extend([message(13, 101, 101, "/models"), message(14, 101, 101, "/new"),
                    message(15, 101, 101, "fresh topic")])
            wait(lambda: any('"metadata"' in m["text"] and '"first"' in m["text"] for m in SENT), "model listing failed")
            wait(lambda: any(m["messages"][-1]["content"] == "fresh topic" for m in MODEL), "new topic request missing")
            fresh = next(m for m in MODEL if m["messages"][-1]["content"] == "fresh topic")
            assert len(fresh["messages"]) == 1 and fresh["model"] == "second"
            wait(lambda: any("second:fresh topic" in m["text"] for m in SENT), "fresh topic reply missing")
            RELEASE.clear()
            controller.send({"op": "turn", "request_id": "cli-pause", "session_id": "main", "message": "pause"})
            wait(lambda: sum(m["messages"][-1]["content"] == "pause" for m in MODEL) == 2, "CLI request not started")
            typing_before = len(TYPING)
            with LOCK:
                UPDATES.append(message(16, 101, 101, "queued behind CLI"))
            def queued():
                with sqlite3.connect(root / "state/agent.sqlite3") as database:
                    return database.execute("SELECT status FROM telegram_inbox WHERE id=16").fetchone() == ("queued",)
            wait(lambda: len(TYPING) > typing_before and queued(), "Telegram message was not deferred while CLI was busy")
            RELEASE.set()
            assert controller.receive()["committed"] is True
            wait(lambda: any("second:queued behind CLI" in m["text"] for m in SENT), "deferred Telegram request did not complete")
            before = len(MODEL)
            controller.close()
            controller = Controller(root, server.server_port, settings)
            controller.command("status")
            time.sleep(1)
            assert len(MODEL) == before, "restart replayed delivered updates"
            with sqlite3.connect(root / "state/agent.sqlite3") as database:
                rows = database.execute("SELECT id,status FROM telegram_inbox ORDER BY id").fetchall()
                assert rows == [(i, "cancelled" if i == 10 else "done") for i in range(3, 17)], rows
                assert database.execute("SELECT count(*) FROM telegram_outbox WHERE status='delivered'").fetchone()[0] >= 11
            controller.close()
            controller = None
            policy = Path(directory) / "backup.json"
            policy.write_text(json.dumps({"schedule": "fixture", "minimum_copies": 1, "rpo_ms": 60000,
                "rto_ms": 60000, "failure_domain": "local fixture", "disk_reserve_bytes": 1048576}))
            run("backup", "--data-root", root, "--backup-root", Path(directory) / "backups", "--policy", policy)
            print("Telegram integration passed: access lists, group addressing, topics, provider settings, durable offsets and restart deduplication.")
    finally:
        RELEASE.set()
        if controller:
            controller.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
