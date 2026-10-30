#!/usr/bin/env python3
"""Cancel an actual in-flight HTTP call without waiting for the model timeout."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT

RELEASE = threading.Event()
CALLS = []
MARKER = None


class Provider(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        text = body["messages"][-1]["content"]
        CALLS.append(text)
        if text == "pause":
            MARKER.touch()
            RELEASE.wait(20)
        data = json.dumps({"done": True, "message": {"content": "reply:" + text}}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def main():
    global MARKER
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="ae-cancellation-") as directory:
            root = Path(directory)
            MARKER = root / "http-arrived"
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)],
                cwd=CHECKOUT, check=True, capture_output=True)
            result = subprocess.run(["escript", str(CHECKOUT / "test/integration/cancellation.escript"), str(MARKER)],
                cwd=CHECKOUT, env={**os.environ, "AE_DATA_ROOT": str(root), "AE_LLM_MODEL": "fixture",
                    "AE_LLM_URL": f"http://127.0.0.1:{server.server_port}/api/chat"},
                capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, result.stdout + result.stderr
            assert json.loads(result.stdout)["cancelled"] and CALLS == ["pause", "after"], CALLS
            print("Cancellation passed: active HTTP request stopped promptly; subsequent conversation remains usable.")
    finally:
        RELEASE.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
