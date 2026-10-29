#!/usr/bin/env python3
"""Exercise real seed authoring and budgeted provider transport without executing patches."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT


class Provider(BaseHTTPRequestHandler):
    scenario = None
    requests = []
    patch = ("diff --git a/apps/ae_seed/src/seed_agent.erl b/apps/ae_seed/src/seed_agent.erl\n"
             "--- a/apps/ae_seed/src/seed_agent.erl\n+++ b/apps/ae_seed/src/seed_agent.erl\n"
             "@@ -1 +1 @@\n--module(seed_agent).\n+-module(seed_agent). % authored\n")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/api/chat" and body["stream"] is False and body["model"] == "fixture"
        if body.get("format") != "json":
            content = "conversation still works"
        else:
            self.requests.append(body)
            assert "num_ctx" in body["options"] and body["options"]["num_predict"] > 0
            last = body["messages"][-1]["content"]
            if self.scenario != "cache":
                last = json.loads(last)
            step = (len(self.requests) - 1) % 3 + 1 if self.scenario == "repair" else len(self.requests)
            if self.scenario == "cache":
                assert len(self.requests) == 1 and last == "cache-test"
                action = {"cache": "fixture result"}
            elif step == 1:
                assert last["status"] == "proposing" and "deadline" in last
                if self.scenario == "repair" and len(self.requests) == 4:
                    assert last["attempts"] == 1 and last["public_diagnostics"] == "public compiler diagnostic"
                    assert any('"evolution_feedback"' in m["content"] for m in body["messages"])
                action = {"action": "source_list", "offset": 0, "count": 2}
            elif step == 2:
                assert len(last["entries"]) == 2 and last["eof"] is False
                action = {"action": "source_read", "path": "apps/ae_seed/src/seed_agent.erl", "offset": 0, "bytes": 512}
                if self.scenario == "protected":
                    action["path"] = "apps/ae_core/src/ae_store.erl"
            elif step == 3:
                assert "-module(seed_agent)." in last["content_utf8"] and last["eof"] is False
                assert "job_id" in last and "base_source_revision" in last
                action = {"action": "proposal", "patch": self.patch, "hypothesis": "clearer greeting",
                          "expected_benefit": "friendlier response", "risks": ["regression"],
                          "requested_tests": ["contract", "replay"]}
            else:
                raise AssertionError("unbounded authoring")
            content = json.dumps(action)
            if self.scenario == "invalid":
                content = "This is a prose-only suggestion, not a patch."
        response = {"done": True, "message": {"content": content}, "prompt_eval_count": 80, "eval_count": 100}
        if body.get("format") == "json":
            if self.scenario == "missing-usage":
                del response["prompt_eval_count"]
            if self.scenario == "over-budget":
                response["eval_count"] = body["options"]["num_predict"] + 1
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_):
        pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="ae-authoring-") as directory:
        root = Path(directory)
        subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)],
                       cwd=CHECKOUT, check=True, capture_output=True)
        limits = {"max_attempts": 2, "total_ms": 60000, "max_llm_calls": 4,
            "tokens_per_call": 32768, "max_tokens": 131072, "max_cost_microunits": 0,
            "cost_per_call_microunits": 0, "max_patch_bytes": 4096, "max_diagnostic_bytes": 1024,
            "max_source_calls": 10, "max_source_bytes": 40960, "source_page_bytes": 4096,
            "build_ms": 5000, "evaluation_ms": 5000, "cpu_ms": 5000, "memory_bytes": 536870912,
            "processes": 32, "disk_reserve_bytes": 1048576}
        try:
            for scenario in ("success", "protected", "budget", "invalid", "missing-usage", "over-budget", "cache", "repair"):
                Provider.scenario = scenario
                Provider.requests = []
                policy = {**limits, "max_llm_calls": 1} if scenario == "budget" else limits
                if scenario == "repair":
                    policy = {**limits, "max_llm_calls": 8, "max_tokens": 262144}
                limit_file = root / "limits.json"
                limit_file.write_text(json.dumps(policy))
                result = subprocess.run(["escript", str(CHECKOUT / "test/integration/authoring.escript"), scenario, str(limit_file)],
                    cwd=CHECKOUT, env={**os.environ, "AE_DATA_ROOT": str(root), "AE_LLM_MODEL": "fixture",
                        "AE_LLM_URL": f"http://127.0.0.1:{server.server_port}/api/chat"},
                    text=True, capture_output=True, timeout=30)
                assert result.returncode == 0, result.stdout + result.stderr
                output = json.loads(result.stdout.splitlines()[0])
                assert output["conversation"]["ok"] == "conversation still works", output
                assert output["status"]["evolution_enabled"] is False
                job = output["job"]
                assert job["reserved_tokens"] == job["llm_calls"] * policy["tokens_per_call"]
                assert job["llm_calls"] <= policy["max_llm_calls"]
                if scenario in ("success", "repair"):
                    assert "ok" in output["result"], output
                    assert output["result"]["ok"]["patch"] == Provider.patch
                    attempts = 2 if scenario == "repair" else 1
                    assert output["duplicate_reused"] is True and job["status"] == "building" and job["attempts"] == attempts
                    assert len(Provider.requests) == 3 * attempts and job["source_calls"] == 2 * attempts
                elif scenario == "cache":
                    assert output["result"]["ok"] == {"cached": True, "unknown_not_reissued": True}
                    assert len(Provider.requests) == 1 and job["llm_calls"] == 2
                else:
                    expected = {"protected": "protected_source", "budget": "budget_exhausted",
                        "invalid": "invalid_authoring_response", "missing-usage": "provider_usage_missing",
                        "over-budget": "provider_budget_violation"}[scenario]
                    assert output["result"]["error"] == expected, output
                    assert job["attempts"] == 0
                assert not list((root / "workspaces").iterdir())
            print("Authoring integration passed: job-scoped paginated source, budgeted LLM patch, dedupe, denial and usable conversation; no patch execution.")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
