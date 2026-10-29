#!/usr/bin/env python3
"""Exercise seed authoring; optional delegated-cgroup cases build and evaluate patches."""
import difflib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from phase0 import CHECKOUT


class Provider(BaseHTTPRequestHandler):
    scenario = None
    requests = []
    conversation_requests = 0
    patch = ("diff --git a/apps/ae_seed/src/seed_agent.erl b/apps/ae_seed/src/seed_agent.erl\n"
             "--- a/apps/ae_seed/src/seed_agent.erl\n+++ b/apps/ae_seed/src/seed_agent.erl\n"
             "@@ -1 +1 @@\n--module(seed_agent).\n+-module(seed_agent). % authored\n")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/api/chat" and body["stream"] is False and body["model"] == "fixture"
        authoring = isinstance(body.get("format"), dict)
        if not authoring:
            type(self).conversation_requests += 1
            content = "conversation still works"
        else:
            self.requests.append(body)
            assert "num_ctx" in body["options"] and body["options"]["num_predict"] > 0
            assert body["options"]["temperature"] == 0
            actions = body["format"]["oneOf"]
            assert {action["properties"]["action"]["const"] for action in actions} == {
                "source_list", "source_read", "proposal"}
            assert all(action["additionalProperties"] is False and
                set(action["required"]) == set(action["properties"]) for action in actions)
            last = body["messages"][-1]["content"]
            if self.scenario != "cache":
                last = json.loads(last)
            step = (len(self.requests) - 1) % 3 + 1 if self.scenario in ("repair", "orchestrated-rollback") else len(self.requests)
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
                patch = self.patch
                if self.scenario == "orchestrated-rollback" and len(self.requests) == 3:
                    patch = ("diff --git a/apps/ae_seed/src/seed_agent.erl b/apps/ae_seed/src/seed_agent.erl\n"
                        "--- a/apps/ae_seed/src/seed_agent.erl\n+++ b/apps/ae_seed/src/seed_agent.erl\n"
                        "@@ -1 +1 @@\n--module(seed_agent).\n+-module(seed_agent). invalid_erlang\n")
                action = {"action": "proposal", "patch": patch, "hypothesis": "clearer greeting",
                          "expected_benefit": "friendlier response", "risks": ["regression"],
                          "requested_tests": ["contract", "replay"]}
            else:
                raise AssertionError("unbounded authoring")
            content = json.dumps(action)
            if self.scenario == "invalid":
                content = "This is a prose-only suggestion, not a patch."
        response = {"done": True, "message": {"content": content}, "prompt_eval_count": 80, "eval_count": 100}
        if authoring:
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
            scenarios = ["success", "protected", "budget", "invalid", "missing-usage", "over-budget", "cache", "repair", "builder-unavailable"]
            if os.environ.get("AE_TEST_CGROUP_ROOT"):
                scenarios.extend(["builder-success", "evaluator-success", "evaluator-unavailable", "deployment-rollback", "orchestrated-rollback"])
            if os.environ.get("AE_TEST_AUTHORING_SCENARIOS"):
                scenarios = os.environ["AE_TEST_AUTHORING_SCENARIOS"].split(",")
                assert all(s in {"success", "protected", "budget", "invalid", "missing-usage", "over-budget", "cache", "repair", "builder-unavailable", "builder-success", "evaluator-success", "evaluator-unavailable", "deployment-rollback", "orchestrated-rollback"} for s in scenarios)
            original_patch = Provider.patch
            for scenario in scenarios:
                print("Authoring scenario: " + scenario, flush=True)
                Provider.scenario = scenario
                Provider.requests = []
                Provider.conversation_requests = 0
                Provider.patch = original_patch
                if scenario.startswith(("evaluator-", "deployment-", "orchestrated-")):
                    path = "apps/ae_seed/src/seed_agent.erl"
                    source = (CHECKOUT / path).read_text()
                    changed = source.replace('<<"text">> => Text, <<"event_refs">> => []',
                        '<<"text">> => <<"authored:", Text/binary>>, <<"event_refs">> => []')
                    assert source != changed
                    Provider.patch = f"diff --git a/{path} b/{path}\n" + "".join(difflib.unified_diff(
                        source.splitlines(True), changed.splitlines(True), fromfile="a/" + path, tofile="b/" + path))
                policy = {**limits, "max_llm_calls": 1} if scenario == "budget" else limits
                if scenario in ("repair", "orchestrated-rollback"):
                    policy = {**limits, "max_llm_calls": 8, "max_tokens": 262144}
                if scenario in ("builder-success", "evaluator-success", "evaluator-unavailable", "deployment-rollback", "orchestrated-rollback"):
                    wall_ms = int(os.environ.get("AE_TEST_BUILD_WALL_MS", "20000"))
                    cpu_ms = int(os.environ.get("AE_TEST_BUILD_CPU_MS", "10000"))
                    policy = {**limits, "total_ms": wall_ms * 3, "build_ms": wall_ms, "cpu_ms": cpu_ms * 3}
                if scenario.startswith(("evaluator-", "deployment-", "orchestrated-")):
                    evaluation_wall = int(os.environ.get("AE_TEST_EVAL_WALL_MS", "180000"))
                    evaluation_cpu = int(os.environ.get("AE_TEST_EVAL_CPU_MS", "60000"))
                    policy.update({"total_ms": wall_ms * 2 + evaluation_wall * 2,
                        "evaluation_ms": evaluation_wall, "cpu_ms": cpu_ms + evaluation_cpu * 2})
                if scenario == "orchestrated-rollback":
                    policy.update({"max_llm_calls": 8, "max_tokens": 262144})
                limit_file = root / "limits.json"
                limit_file.write_text(json.dumps(policy))
                extra_env = {}
                if scenario in ("builder-unavailable", "builder-success", "evaluator-success", "evaluator-unavailable", "deployment-rollback", "orchestrated-rollback"):
                    if scenario == "builder-unavailable":
                        fake = root / "fake-cgroup"
                        fake.mkdir()
                        wall_ms, cpu_ms = 5000, 1000
                    else:
                        fake = Path(os.environ["AE_TEST_CGROUP_ROOT"])
                    package = os.environ.get("AE_JSX_PACKAGE", str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar"))
                    extra_env["AE_BUILD_CONFIG_JSON"] = json.dumps({"cgroup_root": str(fake), "jsx_package": package,
                        "source_bytes": 2097152, "source_files": 128, "artifact_bytes": 8388608,
                        "sandbox_limits": {"memory_bytes": 536870912, "pids": 32, "cpu_percent": 100,
                            "cpu_seconds": (cpu_ms + 999) // 1000, "address_space_bytes": 1073741824, "file_bytes": 33554432,
                            "open_files": 128, "output_bytes": 16777216, "wall_ms": wall_ms}})
                if scenario.startswith(("evaluator-", "deployment-", "orchestrated-")):
                    sys.path.insert(0, str(CHECKOUT / "test/evaluation"))
                    import test_evaluate
                    evaluation = json.loads(extra_env["AE_BUILD_CONFIG_JSON"])
                    del evaluation["jsx_package"]
                    evaluation.update({"startup_ms": 30000, "turn_ms": 15000, "policy": test_evaluate.policy(),
                        "sandbox_limits": {**evaluation["sandbox_limits"], "wall_ms": evaluation_wall,
                            "cpu_seconds": (evaluation_cpu + 3999)//4000}})
                    if scenario == "evaluator-unavailable":
                        fake_evaluation = root / "fake-evaluation-cgroup"
                        fake_evaluation.mkdir()
                        evaluation["cgroup_root"] = str(fake_evaluation)
                    extra_env["AE_EVAL_CONFIG_JSON"] = json.dumps(evaluation)
                if scenario in ("deployment-rollback", "orchestrated-rollback"):
                    extra_env.update({"AE_APPROVAL_TTL_MS": "120000", "AE_OBSERVE_MS": "60000",
                        "AE_HEALTH_INTERVAL_MS": "250", "AE_QUIESCE_TIMEOUT_MS": "5000"})
                if scenario == "orchestrated-rollback":
                    extra_env.update({"AE_EVOLUTION_ENABLED": "true", "AE_EVOLUTION_LIMITS_JSON": json.dumps(policy)})
                result = subprocess.run(["escript", str(CHECKOUT / "test/integration/authoring.escript"), scenario, str(limit_file)],
                    cwd=CHECKOUT, env={**os.environ, "AE_DATA_ROOT": str(root), "AE_LLM_MODEL": "fixture",
                        "AE_LLM_URL": f"http://127.0.0.1:{server.server_port}/api/chat", **extra_env},
                    text=True, capture_output=True, timeout=policy["total_ms"] / 1000 + 30)
                assert result.returncode == 0, result.stdout + result.stderr
                output = json.loads(result.stdout.splitlines()[0])
                assert output["conversation"]["ok"] == "conversation still works", output
                assert Provider.conversation_requests == (4 if scenario in ("deployment-rollback", "orchestrated-rollback") else 2 if scenario.startswith("evaluator-") else 1)
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
                elif scenario == "builder-unavailable":
                    assert output["result"]["error"] == "cgroup_v2_required", output
                    assert job["reserved_cpu_ms"] == 1000 and job["status"] == "proposing"
                    assert job["attempts"] == 1
                    assert next(iter(job["executions"].values()))["status"] == "failed"
                elif scenario == "builder-success":
                    manifest = output["result"]["ok"]
                    assert manifest["authoring"] == "llm" and manifest["evaluation"] is None
                    assert job["status"] == "testing" and job["attempts"] == 1 and job["reserved_cpu_ms"] == cpu_ms
                    assert job["built_artifact"] == manifest
                    assert next(iter(job["executions"].values()))["status"] == "completed"
                    assert (root / "artifacts" / manifest["digest"] / "seed").is_file()
                elif scenario.startswith(("evaluator-", "deployment-", "orchestrated-")):
                    assert job["reserved_cpu_ms"] == (policy["cpu_ms"] if scenario in ("deployment-rollback", "orchestrated-rollback") else cpu_ms + evaluation_cpu), output
                    if scenario in ("deployment-rollback", "orchestrated-rollback"):
                        stage = job["executions"][str(job["attempts"]) + ":stage"]
                        assert stage["status"] == "completed" and stage["cpu_ms"] == policy["cpu_ms"] - cpu_ms * job["attempts"] - evaluation_cpu
                        assert stage["runtime_limits"]["pids"] <= policy["processes"]
                        assert stage["runtime_limits"]["memory_bytes"] <= policy["memory_bytes"]
                        assert stage["expires_at_ms"] <= job["deadline"]
                    if scenario in ("evaluator-success", "deployment-rollback", "orchestrated-rollback"):
                        assert job["status"] == ("rolled_back" if scenario in ("deployment-rollback", "orchestrated-rollback") else "evaluated"), output
                        scorecard = job["evaluations"][str(job["attempts"])]["scorecard"]
                        assert scorecard["passed"] is True and all(scorecard["gates"].values()), scorecard
                        assert scorecard["baseline"]["objective"]["rate_ppm"] == 0
                        assert scorecard["candidate"]["objective"]["rate_ppm"] == 1000000
                        assert scorecard["configuration_hash"] == job["executions"][str(job["attempts"]) + ":evaluate"]["evaluation_binding"]["configuration_hash"]
                        assert json.loads(job["executions"][str(job["attempts"]) + ":evaluate"]["evaluation_configuration"]) == evaluation
                        assert job["built_artifact"]["evaluation"] is None
                        assert len(Provider.requests) == (6 if scenario == "orchestrated-rollback" else 3), "Evaluator must not contact the live provider"
                    else:
                        assert output["result"]["error"] == "cgroup_v2_required", output
                        assert job["status"] == "proposing" and job["executions"][str(job["attempts"]) + ":evaluate"]["status"] == "failed", output
                else:
                    expected = {"protected": "protected_source", "budget": "budget_exhausted",
                        "invalid": "invalid_authoring_response", "missing-usage": "provider_usage_missing",
                        "over-budget": "provider_budget_violation"}[scenario]
                    assert output["result"]["error"] == expected, output
                    assert job["attempts"] == 0
                if scenario == "orchestrated-rollback":
                    assert job["attempts"] == 2 and job["executions"]["1:build"]["status"] == "failed", job
                    restarted = subprocess.run(["escript", str(CHECKOUT / "test/integration/evolution_restart.escript"), job["id"]],
                        cwd=CHECKOUT, env={**os.environ, "AE_DATA_ROOT": str(root), "AE_LLM_MODEL": "fixture",
                            "AE_LLM_URL": f"http://127.0.0.1:{server.server_port}/api/chat", **extra_env},
                        text=True, capture_output=True, timeout=120)
                    assert restarted.returncode == 0, restarted.stdout + restarted.stderr
                    assert Provider.conversation_requests == 5
                assert not list((root / "workspaces").iterdir())
                with sqlite3.connect(root / "state/agent.sqlite3") as database:
                    turns = database.execute("SELECT request_id,message,reply,status FROM turns").fetchall()
                assert turns and all(message == "hello" and status == "completed" and reply ==
                    ("authored:conversation still works" if request == "candidate-ack" else "conversation still works")
                    for request, message, reply, status in turns), turns
            print("Authoring integration passed: scoped source, budgeted patches/repairs, dedupe, denial and usable conversation; generated releases require an explicit test-operator approval.")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
