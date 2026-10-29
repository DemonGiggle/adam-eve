#!/usr/bin/env python3
"""Exercise real BEAM processes, SQLite, retained code, and the HTTP broker boundary."""
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHECKOUT = Path(__file__).resolve().parents[2]
CALLS = []
IN_FLIGHT = threading.Event()
RELEASE = threading.Event()


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/api/chat"
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert body["stream"] is False
        assert body["model"] == "fixture"
        CALLS.append(body)
        messages = body["messages"]
        text = messages[-1]["content"]
        if text == "drain-pause":
            time.sleep(0.7)
        if text == "pause":
            IN_FLIGHT.set()
            assert RELEASE.wait(10), "test did not release provider"
        if text == "unavailable":
            self.send_error(503)
            return
        if text == "recall":
            assert any(m["content"] == "remember saffron" for m in messages)
            assert any(m["role"] == "assistant" for m in messages)
            text = "saffron"
        data = json.dumps({"done": True, "message": {"content": "reply:" + text}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass  # Expected when crash injection kills the requesting controller.

    def log_message(self, *_):
        pass


class Controller:
    def __init__(self, root, port, settings=None):
        self.errors = tempfile.TemporaryFile(mode="w+")
        self.process = subprocess.Popen([str(CHECKOUT / "scripts/ae")], cwd=CHECKOUT,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors, text=True,
            env={**os.environ, "AE_DATA_ROOT": str(root), "AE_LLM_MODEL": "fixture",
                 "AE_LLM_URL": f"http://127.0.0.1:{port}/api/chat",
                 "AE_TEST_SECRET": "must-stay-in-controller", **(settings or {})})

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def receive(self):
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            assert selector.select(25), "controller response timed out"
            line = self.process.stdout.readline()
            if not line:
                self.errors.seek(0)
                raise AssertionError("controller exited: " + self.errors.read())
            try:
                return json.loads(line)
            except json.JSONDecodeError as error:
                self.errors.seek(0)
                raise AssertionError(f"Non-JSON output: {line!r}; stderr: {self.errors.read()}") from error
        finally:
            selector.close()

    def command(self, op, **fields):
        self.send({"op": op, **fields})
        return self.receive()

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(5)
        self.process.stdout.close()
        self.errors.close()


def turn(controller, request, message, session="main"):
    return controller.command("turn", request_id=request, session_id=session, message=message)


def await_epoch(controller, old):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        result = controller.command("status")
        if result.get("routing", {}).get("epoch", 0) > old:
            return result
        time.sleep(0.1)
    raise AssertionError("runtime did not recover with a new epoch")


def main():
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    port = provider.server_port
    with tempfile.TemporaryDirectory(prefix="ae-phase0-") as directory:
        root = Path(directory)
        subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True)
        manifest = json.loads((root / "bootstrap.json").read_text())
        artifact = root / "artifacts" / manifest["digest"] / "seed"
        assert artifact.is_file()
        assert not list((root / "workspaces").iterdir())
        controller = Controller(root, port)
        try:
            first = controller.command("status")
            assert first["evolution_enabled"] is False
            assert first["runtime_health"] == "ok"
            assert first["os_pid"] != controller.process.pid
            child_env = Path(f"/proc/{first['os_pid']}/environ").read_bytes()
            assert b"AE_TEST_SECRET" not in child_env
            assert b"AE_DATA_ROOT" not in child_env
            assert turn(controller, "r1", "remember saffron")["text"] == "reply:remember saffron"
            assert turn(controller, "r1", "remember saffron")["committed"] is True
            assert len(CALLS) == 1
            assert turn(controller, "r1", "changed")["error"] == "request_conflict"
            assert turn(controller, "other", "new session", "other")["committed"] is True
            assert len(CALLS[-1]["messages"]) == 1
            assert controller.command("restart") == {"ok": True}
            second = controller.command("status")
            assert second["routing"]["epoch"] > first["routing"]["epoch"]
            assert second["os_pid"] != first["os_pid"]
            assert turn(controller, "r2", "recall")["text"] == "reply:saffron"
            os.kill(second["os_pid"], signal.SIGKILL)
            third = await_epoch(controller, second["routing"]["epoch"])
            assert turn(controller, "r2", "recall")["text"] == "reply:saffron"
            assert len(CALLS) == 3

            # Kill the seed while its LLM request is in progress. The controller
            # saves the result independently, so replay need not bill the provider again.
            controller.send({"op": "turn", "request_id": "r3", "session_id": "main", "message": "pause"})
            assert IN_FLIGHT.wait(10)
            os.kill(third["os_pid"], signal.SIGKILL)
            RELEASE.set()
            assert "error" in controller.receive()
            fourth = await_epoch(controller, third["routing"]["epoch"])
            assert turn(controller, "r3", "pause")["text"] == "reply:pause"
            assert len(CALLS) == 4

            # Failed provider calls stay pending, explicit retries have durable limits.
            for attempt in range(3):
                assert "error" in turn(controller, "failed", "unavailable")
                assert controller.command("retry", request_id="failed") == {"ok": True}
                if attempt == 0:
                    assert controller.command("restart") == {"ok": True}
            before = len(CALLS)
            assert turn(controller, "failed", "unavailable")["error"] == "attempt_limit"
            assert len(CALLS) == before
            assert controller.command("cancel", request_id="failed") == {"ok": True}

            # Simulate controller loss; its accepted replies and source/executable
            # remain sufficient even when the provisioning input is removed.
            controller.process.kill()
            controller.process.wait(5)
            controller.close()
            shutil.rmtree(root / "workspaces")
            (root / "bootstrap.json").unlink()
            controller = Controller(root, port)
            restored = controller.command("status")
            assert restored["routing"]["epoch"] > fourth["routing"]["epoch"]
            assert turn(controller, "r3", "pause")["text"] == "reply:pause"
            assert len(CALLS) == before
            assert turn(controller, "r4", "recall")["text"] == "reply:saffron"

            # If the controller dies before saving the provider result, recovery
            # must preserve the reservation and require an operator decision.
            IN_FLIGHT.clear()
            RELEASE.clear()
            controller.send({"op": "turn", "request_id": "unknown", "session_id": "main", "message": "pause"})
            assert IN_FLIGHT.wait(10)
            controller.process.kill()
            controller.process.wait(5)
            controller.close()
            RELEASE.set()
            controller = Controller(root, port)
            assert turn(controller, "unknown", "pause")["error"] == "tool_outcome_unknown"
            count = len(CALLS)
            assert controller.command("retry", request_id="unknown") == {"ok": True}
            assert turn(controller, "unknown", "pause")["text"] == "reply:pause"
            assert len(CALLS) == count + 1
            history = controller.command("history")["events"]
            for request in ("r1", "r2", "r3", "r4", "other", "unknown"):
                assert sum(e["kind"] == "user_message" and e["data"]["request_id"] == request for e in history) == 1
                assert sum(e["kind"] == "assistant_reply" and e["data"]["request_id"] == request for e in history) == 1
            controller.close()
            database = root / "state/agent.sqlite3"
            with sqlite3.connect(database) as connection:
                assert connection.execute("PRAGMA integrity_check").fetchone() == ("ok",)
                epoch = json.loads(connection.execute("SELECT data FROM routing").fetchone()[0])["epoch"]

            # Altered executable contents fail startup before an epoch is activated.
            original = artifact.read_bytes()
            artifact.chmod(0o644)
            artifact.write_bytes(original + b"tampered")
            controller = Controller(root, port)
            assert controller.receive() == {"error": "controller_start_failed"}
            controller.process.wait(10)
            assert controller.process.returncode == 1
            with sqlite3.connect(database) as connection:
                assert json.loads(connection.execute("SELECT data FROM routing").fetchone()[0])["epoch"] == epoch
            controller.close()
            artifact.write_bytes(original)
            artifact.chmod(0o444)

            # Source retention is independently required; an intact executable
            # cannot hide a missing protected source reference.
            reference = "refs/generations/" + manifest["digest"]
            subprocess.run(["git", "--git-dir", str(root / "source.git"),
                            "update-ref", "-d", reference], check=True)
            controller = Controller(root, port)
            assert controller.receive() == {"error": "controller_start_failed"}
            controller.process.wait(10)
            assert controller.process.returncode == 1
        finally:
            controller.close()
    provider.shutdown()
    provider.server_close()
    print("Phase 0 integration passed: restart, crash recovery, replay, fencing, retry limits, artifact integrity")


if __name__ == "__main__":
    main()
