#!/usr/bin/env python3
"""Opt-in real-Ollama host-execution Phase 2 acceptance demonstration.

The caller explicitly supplies a local inference service and a new private data
root. Generated code runs as the controller user. Outputs remain for inspection.
This is never part of the fixture-only default suite.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from phase0 import CHECKOUT, Controller


class LiveController(Controller):
    response_timeout = 350


def comparison(generation):
    policy = json.loads((CHECKOUT / "test/evaluation/policy.json").read_bytes())
    policy["cases"] = []

    def reply(name, model_text, expected, kind="task", objective=False, history=None):
        message = f"Independent {name} ${{nonce}}"
        history = history or []
        policy["cases"].append({"id": name, "message": message, "history": history,
            "model_result": {"text": model_text}, "expected_messages": history + [{"role": "user", "content": message}],
            "expected_type": "reply", "expected_text": expected, "kind": kind,
            "required": not objective, "objective": objective})

    reply("hello", "hello:${nonce}", "Hello, ${nonce}", objective=generation == 1)
    if generation == 2:
        reply("goodbye", "bye:${nonce}", "Goodbye, ${nonce}", objective=True)
    reply("context", "unchanged ${nonce}", "unchanged ${nonce}", kind="memory", history=[
        {"role": "user", "content": "Remember ${nonce}"}, {"role": "assistant", "content": "Saved ${nonce}"}])
    message = "Independent provider failure ${nonce}"
    policy["cases"].append({"id": "provider-denial", "message": message, "history": [],
        "model_result": {"error": "provider_unavailable"}, "expected_messages": [{"role": "user", "content": message}],
        "expected_type": "failure", "expected_text": "provider_unavailable", "kind": "tool",
        "required": True, "objective": False})
    return policy


def persist(root, name, value):
    (root / name).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def wait_job(controller, identity, wanted, root, seconds=1800):
    deadline, previous = time.monotonic() + seconds, None
    while time.monotonic() < deadline:
        job = controller.command("evolution", job_id=identity)
        state = job.get("status")
        if state != previous:
            print(f"Job {identity[:12]}: {state}", flush=True)
            persist(root, "job-" + identity + ".json", job)
            previous = state
        if state in wanted:
            return job
        assert state not in ("rejected", "cancelled", "degraded", "rolled_back"), job
        time.sleep(0.25)
    raise AssertionError("evolution job timed out")


def wait_engine(controller):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        status = controller.command("evolution")
        if status["state"] != "recovering":
            assert status["enabled"], status
            return
        time.sleep(0.05)
    raise AssertionError("evolution did not finish startup reconciliation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path, required=True)
    args = parser.parse_args()
    root = args.data_root.absolute()
    assert not root.exists(), "demonstration requires a new identity"
    assert os.environ.get("AE_RUNTIME_ISOLATION", "host") in ("host", "development")
    model = os.environ["AE_LIVE_LLM_MODEL"]
    assert model != "fixture"
    model_digest = os.environ["AE_LIVE_MODEL_DIGEST"]
    assert len(model_digest) == 64 and all(character in "0123456789abcdef" for character in model_digest)
    url = os.environ.get("AE_LIVE_LLM_URL", "http://127.0.0.1:11434/api/chat")
    package = os.environ.get("AE_JSX_PACKAGE", str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar"))
    builder = {"jsx_package": package, "source_bytes": 2097152, "source_files": 128,
        "artifact_bytes": 8388608, "output_bytes": 16777216, "cpu_ms": 90000, "wall_ms": 180000}
    limits = {"max_attempts": 3, "total_ms": 2100000, "max_llm_calls": 16,
        "tokens_per_call": 32768, "max_tokens": 524288, "cost_per_call_microunits": 0,
        "max_cost_microunits": 0, "max_patch_bytes": 65536, "max_diagnostic_bytes": 4096,
        "max_source_calls": 24, "max_source_bytes": 131072, "source_page_bytes": 16384,
        "build_ms": 180000, "evaluation_ms": 600000, "cpu_ms": 1200000,
        "memory_bytes": 536870912, "processes": 64, "disk_reserve_bytes": 16777216}
    settings = {"AE_LLM_MODEL": model, "AE_LLM_URL": url, "AE_LLM_TIMEOUT_MS": "300000",
        "AE_EVOLUTION_LLM_TIMEOUT_MS": os.environ.get("AE_EVOLUTION_LLM_TIMEOUT_MS", "900000"),
        "AE_RETENTION_POLICY_JSON": json.dumps({"promoted_generations": "all", "rejected_attempts": "all", "audit": "all"}),
        "AE_RUNTIME_ISOLATION": "host",
        "AE_EVOLUTION_ENABLED": "true", "AE_EVOLUTION_LIMITS_JSON": json.dumps(limits),
        "AE_BUILD_CONFIG_JSON": json.dumps(builder), "AE_APPROVAL_TTL_MS": "120000",
        "AE_OBSERVE_MS": "10000", "AE_HEALTH_INTERVAL_MS": "250", "AE_QUIESCE_TIMEOUT_MS": "5000"}
    subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True)
    baseline = json.loads((root / "bootstrap.json").read_bytes())
    evidence = {"model": model, "model_digest": model_digest,
        "execution_mode": "host",
        "controller_revision": os.environ.get("AE_LIVE_CONTROLLER_REVISION"),
        "baseline": baseline, "generations": []}
    persist(root, "live-demonstration.json", evidence)
    for generation in (1, 2):
        evaluation = {key: value for key, value in builder.items() if key != "jsx_package"}
        evaluation.update({"startup_ms": 30000, "turn_ms": 15000, "policy": comparison(generation),
            "wall_ms": 600000, "cpu_ms": 240000})
        settings["AE_EVAL_CONFIG_JSON"] = json.dumps(evaluation)
        controller = LiveController(root, 0, settings)
        try:
            wait_engine(controller)
            before = controller.command("status")
            expected = baseline if generation == 1 else evidence["generations"][0]["built_artifact"]
            assert before["routing"]["artifact"] == expected
            transform = "hello:" if generation == 1 else "bye:"
            replacement = "Hello, " if generation == 1 else "Goodbye, "
            objective = (f"Add a deterministic reply formatting behavior: when the broker returns LLM text starting with "
                f"the literal '{transform}', replace only that initial marker with the literal '{replacement}' and preserve "
                "all remaining UTF-8 text. All other LLM text must be returned unchanged. Preserve all existing reply "
                "formatting, conversation, memory and error behavior. Keep exactly the existing memory_read and llm "
                "broker calls, protocol fields, capabilities and state schema. Read the complete seed_agent.erl and "
                "the public protocol, then prefer an exact-text edit against this current baseline.")
            job = controller.command("evolve", origin_ref=f"live-generation-{generation}", objective=objective)
            assert "id" in job, job
            identity = job["id"]
            staged = wait_job(controller, identity, {"awaiting_approval"}, root)
            score = staged["evaluations"][str(staged["attempts"])]["scorecard"]
            assert score["passed"] and all(score["gates"].values()), score
            assert score["baseline"]["objective"]["rate_ppm"] == 0
            assert score["candidate"]["objective"]["rate_ppm"] == 1000000
            assert score["candidate"]["required_failed"] == 0
            assert staged["baseline"]["artifact"] == expected
            assert controller.command("status")["routing"]["artifact"] == expected
            persist(root, f"generation-{generation}-review.json", staged)
            # This opt-in test is the explicit test operator. No automatic
            # policy in the application authorizes this transition.
            approved = controller.command("approve", deployment_id=staged["deployment_id"],
                approval_binding=staged["approval_binding"])
            assert approved.get("ok") is True, approved
            promoted = approved["routing"]
            assert promoted["slot"] == ("eve" if generation == 1 else "adam")
            assert promoted["epoch"] > before["routing"]["epoch"]
            request = f"live-ack-{generation}"
            committed = controller.command("turn", request_id=request, session_id="live", message="Reply with the single word acknowledged.")
            assert committed.get("committed") is True, committed
            completed = wait_job(controller, identity, {"completed"}, root, seconds=120)
            completed["acknowledged_turn"] = committed
            evidence["generations"].append(completed)
            persist(root, "live-demonstration.json", evidence)
        finally:
            controller.close()
    # Full controller and both runtimes have stopped. Verify retained bytes and
    # source ancestry, then restart the exact promoted release without rebuild.
    for artifact in (baseline, *(job["built_artifact"] for job in evidence["generations"])):
        digest = artifact["digest"]
        assert hashlib.sha256((root / "artifacts" / digest / "seed").read_bytes()).hexdigest() == digest
        revision = subprocess.check_output(["git", "--git-dir", str(root / "source.git"),
            "rev-parse", "refs/generations/" + digest], text=True).strip()
        assert revision == artifact["source_revision"]
    controller = LiveController(root, 0, settings)
    try:
        wait_engine(controller)
        status = controller.command("status")
        assert status["routing"]["artifact"] == evidence["generations"][1]["built_artifact"]
        for generation, job in enumerate(evidence["generations"], 1):
            saved = controller.command("turn", request_id=f"live-ack-{generation}", session_id="live",
                message="Reply with the single word acknowledged.")
            assert saved == job["acknowledged_turn"]
        evidence["restart_verified"] = status
        persist(root, "live-demonstration.json", evidence)
    finally:
        controller.close()
    print("Two successive live-LLM-authored, independently evaluated and explicitly approved generations survived full restart.", flush=True)


if __name__ == "__main__":
    main()
