#!/usr/bin/env python3
"""Opt-in test transport for a networkless VM to a private host Ollama server.

Run `host --queue PATH --url http://127.0.0.1:PORT/api/chat` on the inference
host, and `guest --queue MOUNTED_PATH` inside the VM. Bodies and usage counts
are forwarded unchanged; request/response files retain the inference evidence.
Host-executed generated code can access this queue if its user has permission.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import time
import urllib.error
import urllib.request
import uuid


def atomic(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_bytes(data)
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("host", "guest"))
    parser.add_argument("--queue", type=Path, required=True)
    parser.add_argument("--url", default="http://127.0.0.1:11435/api/chat")
    parser.add_argument("--port", type=int, default=11434)
    args = parser.parse_args()
    queue = args.queue.absolute()
    queue.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.mode == "host":
        while True:
            for request in sorted(queue.glob("*.request")):
                response = request.with_suffix(".response")
                if response.exists():
                    continue
                body = request.read_bytes()
                assert 0 < len(body) <= 1048576
                try:
                    with urllib.request.urlopen(urllib.request.Request(args.url, body,
                            {"Content-Type": "application/json"}), timeout=310) as upstream:
                        status, data = upstream.status, upstream.read(1048577)
                    assert len(data) <= 1048576
                except urllib.error.HTTPError as error:
                    status, data = error.code, error.read(1048576)
                except Exception:
                    status, data = 502, b'{"error":"inference_transport_failed"}'
                atomic(response, json.dumps({"status": status, "body_base64": base64.b64encode(data).decode()}).encode())
                result = json.loads(data) if status == 200 else {}
                print(f"{request.stem}: HTTP {status}; prompt={result.get('prompt_eval_count')}; output={result.get('eval_count')}", flush=True)
            time.sleep(0.1)
    else:
        class Relay(BaseHTTPRequestHandler):
            def do_POST(self):
                assert self.path == "/api/chat"
                size = int(self.headers["Content-Length"])
                assert 0 < size <= 1048576
                identity = uuid.uuid4().hex
                request, response = queue / (identity + ".request"), queue / (identity + ".response")
                atomic(request, self.rfile.read(size))
                deadline = time.monotonic() + 320
                while not response.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if not response.exists():
                    self.send_error(504)
                    return
                result = json.loads(response.read_bytes())
                data = base64.b64decode(result["body_base64"], validate=True)
                self.send_response(result["status"])
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                try:
                    self.wfile.write(data)
                except BrokenPipeError:
                    pass

            def log_message(self, *_):
                pass
        ThreadingHTTPServer(("127.0.0.1", args.port), Relay).serve_forever()


if __name__ == "__main__":
    main()
