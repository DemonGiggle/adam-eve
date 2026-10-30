#!/usr/bin/env python3
"""Real HTTP adapters with synthetic credentials; no paid inference or bot sends."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT


class Provider(BaseHTTPRequestHandler):
    adapter = None
    wire = None
    variant = "ok"
    calls = []

    def do_GET(self):
        self.calls.append((self.path, None))
        self.reply({"data": [{"id": "fixture"}]})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        body = json.loads(raw)
        self.calls.append((self.path, body))
        assert body["model"] == "fixture"
        if self.adapter == "anthropic":
            assert self.headers["x-api-key"] == "fixture-key" and self.headers["anthropic-version"] == "2023-06-01"
        else:
            assert self.headers["Authorization"] == "Bearer fixture-key"
        if self.adapter == "opencode-go":
            assert self.headers["User-Agent"] == "adam-eve/0.1"
            assert len(self.headers["x-opencode-session"]) == 36
        assert body["stream"] is False
        if self.wire == "responses":
            assert self.path == "/v1/responses" and body["store"] is False
            assert body["max_output_tokens"] in (512, 4096)
            self.reply(self.response_body())
        elif self.wire == "chat_completions":
            assert self.path == "/v1/chat/completions" and body["max_completion_tokens"] in (512, 4096)
            self.reply({"choices": [{"message": {"content": "fixture reply"}, "finish_reason": "stop"}],
                "usage": self.usage({"prompt_tokens": 80, "completion_tokens": 20})})
        else:
            assert self.path == "/v1/messages" and body["system"] == "Return JSON when requested."
            self.reply({"content": [{"type": "thinking", "thinking": "private"}, {"type": "text", "text": "fixture reply"}],
                "stop_reason": "end_turn", "usage": self.usage({"input_tokens": 80, "output_tokens": 20})})

    def usage(self, value):
        if self.variant == "missing-usage":
            return {}
        if self.variant == "over-budget":
            return {key: 99999 for key in value}
        return value

    def response_body(self):
        return {"status": "completed" if self.variant != "incomplete" else "incomplete",
            "output": [{"type": "reasoning", "summary": []}, {"type": "message", "content": [{"type": "output_text", "text": "fixture reply"}]}],
            "usage": self.usage({"input_tokens": 80, "output_tokens": 20})}

    def reply(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="ae-providers-") as directory:
            root = Path(directory)
            for adapter, wire in (("openai", "responses"), ("openai", "chat_completions"), ("opencode-go", "responses"), ("anthropic", "messages")):
                Provider.adapter, Provider.wire, Provider.variant, Provider.calls = adapter, wire, "ok", []
                profile = {"adapter": adapter, "model": "fixture", "wire": wire,
                    "base_url": f"http://127.0.0.1:{server.server_port}/v1"}
                profile["api_key_env"] = "AE_FIXTURE_KEY"
                document = root / "config.json"
                document.write_text(json.dumps({"default_provider": "fixture", "providers": {"fixture": profile}}))
                def call(mode):
                    result = subprocess.run(["escript", str(CHECKOUT / "test/integration/providers.escript"), mode],
                        cwd=CHECKOUT, env={**os.environ, "AE_CONFIG_FILE": str(document), "AE_FIXTURE_KEY": "fixture-key"},
                        capture_output=True, text=True, timeout=20)
                    assert result.returncode == 0, result.stdout + result.stderr
                    return json.loads(result.stdout)
                assert call("complete")["ok"]["text"] == "fixture reply"
                assert call("models")["ok"][0]["id"] == "fixture"
                assert call("budget")["ok"] == {"text": "fixture reply", "input_tokens": 80, "output_tokens": 20}
                Provider.variant = "missing-usage"
                assert call("budget") == {"error": "provider_usage_missing"}
                Provider.variant = "over-budget"
                assert call("budget") == {"error": "provider_budget_violation"}
                if wire == "responses":
                    Provider.variant = "incomplete"
                    assert call("complete") == {"error": "invalid_provider_response"}
                print("Provider adapter passed:", adapter, wire, flush=True)
    finally:
        server.shutdown()
        server.server_close()
    print("Provider integration passed: credential isolation, model listing, native wire formats and usage bounds.")


if __name__ == "__main__":
    main()
