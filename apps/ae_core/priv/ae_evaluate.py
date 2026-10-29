"""Independent release judge. Private cases and mock state stay in this process.

Every release and agent-supplied test runs behind the mandatory kernel sandbox.
Only aggregate measurements and reproducibility metadata leave this program;
raw case inputs, expected values, replies and child diagnostics are never repair feedback.
"""
import argparse
from contextlib import ExitStack
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time

import ae_candidate as candidate
import ae_sandbox as sandbox

HERE = Path(__file__).resolve().parent
MAX_FRAME = 1048576


class EvaluationError(RuntimeError):
    pass


def require(condition, reason):
    if not condition:
        raise EvaluationError(reason)


def text(value, maximum=65536):
    try:
        return isinstance(value, str) and 0 < len(value.encode()) <= maximum
    except UnicodeError:
        return False


def integer(value, low=1, high=2**63 - 1):
    return type(value) is int and low <= value <= high


def exact(value, keys):
    return isinstance(value, dict) and set(value) == set(keys.split())


def messages(value):
    return isinstance(value, list) and len(value) <= 32 and all(
        exact(item, "role content") and item["role"] in ("system", "user", "assistant")
        and text(item["content"]) for item in value)


def fingerprint(value):
    return hashlib.sha256(candidate.canonical(value)).hexdigest()


def validate_policy(policy):
    require(exact(policy, "version repetitions min_success_delta_ppm max_success_regression_ppm "
        "max_latency_ratio_milli max_model_cost_ratio_milli max_model_tokens_ratio_milli max_failure_rate_ppm max_tool_requests mock_input_tokens "
        "mock_output_tokens mock_cost_microunits repair_approval min_agent_test_modules cases"), "evaluation_policy_required")
    require(type(policy["version"]) is int and policy["version"] == 1, "invalid_evaluation_policy")
    require(integer(policy["repetitions"], 1, 32) and integer(policy["max_tool_requests"], 2, 32)
        and all(integer(policy[key], 1, 1000000) for key in
            ("max_latency_ratio_milli", "max_model_cost_ratio_milli", "max_model_tokens_ratio_milli"))
        and integer(policy["min_agent_test_modules"], 0, 128), "invalid_evaluation_policy")
    for key in ("min_success_delta_ppm", "max_success_regression_ppm", "max_failure_rate_ppm"):
        require(integer(policy[key], 0, 1000000), "invalid_evaluation_policy")
    for key in ("mock_input_tokens", "mock_output_tokens", "mock_cost_microunits"):
        require(integer(policy[key], 0), "invalid_evaluation_policy")
    approval = policy["repair_approval"]
    require(approval is None or text(approval, 256), "invalid_repair_approval")
    require(approval is not None or policy["min_success_delta_ppm"] > 0, "improvement_gate_required")
    cases = policy["cases"]
    require(isinstance(cases, list) and 1 <= len(cases) <= 32, "invalid_evaluation_cases")
    identifiers = set()
    for case in cases:
        require(exact(case, "id message history model_result expected_messages expected_type expected_text kind required objective"),
                "invalid_evaluation_case")
        require(text(case["id"], 64) and case["id"] not in identifiers and text(case["message"])
            and messages(case["history"]) and len(case["history"]) <= 16 and messages(case["expected_messages"])
            and case["expected_type"] in ("reply", "failure") and text(case["expected_text"])
            and case["kind"] in ("task", "memory", "tool")
            and type(case["required"]) is bool and type(case["objective"]) is bool, "invalid_evaluation_case")
        result = case["model_result"]
        require((exact(result, "text") and text(result["text"])) or
            (exact(result, "error") and text(result["error"], 256)), "invalid_mock_result")
        identifiers.add(case["id"])
    require(any(case["objective"] for case in cases), "objective_case_required")
    require({case["kind"] for case in cases} == {"task", "memory", "tool"}, "evaluation_categories_required")
    require(any(case["required"] for case in cases), "regression_case_required")
    require(len(candidate.canonical(policy)) <= 262144, "evaluation_policy_limit")
    return policy


def validate_config(config):
    require(exact(config, "cgroup_root source_bytes source_files artifact_bytes sandbox_limits startup_ms turn_ms policy"),
            "evaluation_configuration_required")
    require(text(config["cgroup_root"], 4096) and Path(config["cgroup_root"]).is_absolute(), "invalid_evaluation_path")
    for key in ("source_bytes", "source_files", "artifact_bytes", "startup_ms", "turn_ms"):
        require(integer(config[key]), "invalid_evaluation_limit")
    require(config["startup_ms"] <= 30000 and config["turn_ms"] <= 300000, "invalid_evaluation_limit")
    sandbox.validate_limits(config["sandbox_limits"])
    validate_policy(config["policy"])
    return config


def strict_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def decode(data):
    try:
        return json.loads(data, object_pairs_hook=strict_object,
            parse_constant=lambda _: (_ for _ in ()).throw(EvaluationError("invalid_json_number")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise EvaluationError("invalid_runtime_json") from error


SCHEMAS = {"authenticate": "token", "ready": "generation restored_seq supported_schema_versions",
    "health_status": "request_id status", "tool_request": "request_id epoch tool args idempotency_key",
    "assistant_reply": "request_id text event_refs", "turn_failed": "request_id reason"}


def validate_message(message):
    require(isinstance(message, dict) and type(message.get("protocol_version")) is int
        and message["protocol_version"] == 1, "unsupported_runtime_protocol")
    kind = message.get("type")
    require(isinstance(kind, str) and kind in SCHEMAS and exact(message,
        "protocol_version type " + SCHEMAS[kind]), "invalid_runtime_message")
    for key in ("token", "generation", "request_id", "status", "tool", "idempotency_key", "reason"):
        if key in message:
            require(text(message[key], 256), "invalid_runtime_field")
    if kind == "ready":
        require(integer(message["restored_seq"], 0) and message["supported_schema_versions"] == [1]
            and type(message["supported_schema_versions"][0]) is int, "invalid_runtime_schema")
    if kind == "tool_request":
        require(integer(message["epoch"]) and isinstance(message["args"], dict), "invalid_runtime_tool")
    if kind == "assistant_reply":
        refs = message["event_refs"]
        require(text(message["text"]) and isinstance(refs, list) and all(integer(n, 0) for n in refs), "invalid_runtime_reply")
    return message


class Runtime:
    """T0 socket peer. The subprocess launcher alone executes the selected release."""
    def __init__(self, root, workspace, manifest, config, limits, cpu_ms, deadline, *, watch_parent=False):
        self.directory = Path(tempfile.mkdtemp(prefix="ipc-", dir=workspace))
        self.connection, self.process = None, None
        self.model_calls = 0
        self.deadline, self.watch_parent = deadline, watch_parent
        self.manifest, self.config = manifest, config
        self.token, self.epoch = secrets.token_hex(32), secrets.randbelow(1000000) + 1
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.listener.bind(str(self.directory / "ipc"))
            self.listener.listen(1)
            runtime = root / "artifacts" / manifest["digest"] / "seed"
            self.process = subprocess.Popen(["/usr/bin/python3", str(HERE / "ae_sandbox.py"),
                "--cgroup-root", config["cgroup_root"], "--limits-json", json.dumps(limits),
                "--runtime", str(runtime), "--digest", manifest["digest"], "--ipc-dir", str(self.directory),
                "--token", self.token, "--cpu-budget-ms", str(cpu_ms)],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env=candidate.ENV, close_fds=True)
            startup = min(deadline, time.monotonic() + config["startup_ms"] / 1000)
            self.wait(self.listener, startup)
            self.connection, _ = self.listener.accept()
            require(self.recv(startup) == {"protocol_version": 1, "type": "authenticate", "token": self.token},
                    "runtime_authentication_failed")
            self.send("hello", slot="adam", runtime_instance_id=secrets.token_hex(16),
                generation=manifest["digest"], capabilities=manifest["capabilities"])
            self.restore(secrets.randbelow(10000) + 1, startup)
            self.health(startup)
        except BaseException:
            self.close()
            raise

    def wait(self, stream, deadline):
        while True:
            require(time.monotonic() < min(self.deadline, deadline), "evaluation_runtime_timeout")
            sources = [stream]
            if self.watch_parent:
                sources.append(sys.stdin.buffer)
            ready, _, _ = select.select(sources, [], [], min(0.05, max(0, deadline - time.monotonic())))
            if self.watch_parent and sys.stdin.buffer in ready:
                require(os.read(sys.stdin.fileno(), 65536), "evaluation_owner_lost")
            if stream in ready:
                return
            require(self.process.poll() is None, "evaluation_runtime_exited")

    def read(self, size, deadline):
        data = bytearray()
        while len(data) < size:
            self.wait(self.connection, deadline)
            chunk = self.connection.recv(size - len(data))
            require(chunk, "evaluation_runtime_disconnected")
            data.extend(chunk)
        return bytes(data)

    def recv(self, deadline):
        length, = struct.unpack("!I", self.read(4, deadline))
        require(0 < length <= MAX_FRAME, "runtime_frame_limit")
        return validate_message(decode(self.read(length, deadline)))

    def send(self, kind, **fields):
        data = json.dumps({"protocol_version": 1, "type": kind, **fields}, separators=(",", ":")).encode()
        require(len(data) <= MAX_FRAME, "judge_frame_limit")
        self.connection.settimeout(max(0.001, min(self.deadline - time.monotonic(), self.config["turn_ms"] / 1000)))
        self.connection.sendall(struct.pack("!I", len(data)) + data)

    def restore(self, sequence, deadline=None):
        self.sequence = sequence
        self.send("restore", checkpoint_id=secrets.token_hex(16), state_schema_version=1, last_event_seq=sequence)
        ready = self.recv(deadline or min(self.deadline, time.monotonic() + self.config["startup_ms"] / 1000))
        require(ready == {"protocol_version": 1, "type": "ready", "generation": self.manifest["digest"],
            "restored_seq": sequence, "supported_schema_versions": [1]}, "runtime_restore_failed")

    def health(self, deadline=None):
        request = secrets.token_hex(16)
        self.send("health_check", request_id=request)
        require(self.recv(deadline or min(self.deadline, time.monotonic() + self.config["turn_ms"] / 1000)) ==
            {"protocol_version": 1, "type": "health_status", "request_id": request, "status": "ok"}, "runtime_health_failed")

    def turn(self, case, policy):
        started = time.monotonic_ns()
        deadline = min(self.deadline, time.monotonic() + self.config["turn_ms"] / 1000)
        request, cache = secrets.token_hex(16), {}
        memory = case["history"] + [{"role": "user", "content": case["message"]}]
        self.send("user_turn", request_id=request, session_id=secrets.token_hex(16), epoch=self.epoch,
            message=case["message"], memory_cursor=self.sequence)
        calls, reads, correct = 0, 0, True
        for _ in range(policy["max_tool_requests"] + 1):
            message = self.recv(deadline)
            require(message.get("request_id") == request, "runtime_request_correlation")
            kind = message["type"]
            if kind in ("assistant_reply", "turn_failed"):
                reply = message.get("text", message.get("reason"))
                expected = "reply" if kind == "assistant_reply" else "failure"
                require(message.get("event_refs", []) == [], "fabricated_event_reference")
                return {"success": expected == case["expected_type"] and reply == case["expected_text"] and correct and reads > 0 and calls > 0,
                    "memory_correct": correct and reads > 0, "tool_correct": calls > 0,
                    "calls": calls, "latency_us": (time.monotonic_ns() - started) // 1000,
                    "reply": reply, "outcome": expected}
            require(kind == "tool_request" and message["epoch"] == self.epoch, "runtime_epoch_violation")
            tool, args, key = message["tool"], message["args"], message["idempotency_key"]
            require(tool in ("memory_read", "llm") and tool in self.manifest["capabilities"], "runtime_capability_violation")
            if key in cache:
                old_tool, old_args, result = cache[key]
                require((old_tool, old_args) == (tool, args), "runtime_idempotency_conflict")
            else:
                if tool == "memory_read":
                    require(args == {}, "invalid_memory_request")
                    result, reads = {"messages": memory}, reads + 1
                else:
                    require(exact(args, "messages") and messages(args["messages"]), "invalid_model_request")
                    correct = correct and args["messages"] == case["expected_messages"]
                    result, calls = case["model_result"], calls + 1
                    self.model_calls += 1
                cache[key] = (tool, args, result)
            self.send("tool_result", request_id=request, idempotency_key=key, result=result)
        raise EvaluationError("runtime_tool_request_limit")

    def close(self):
        # Closing only the owner's pipe simulates launcher loss without granting
        # any process-control capability to the candidate. The helper kills its
        # entire cgroup, including descendants, before it exits.
        if self.process is not None:
            if self.process.stdin and not self.process.stdin.closed:
                self.process.stdin.close()
            self.process.wait(timeout=15)
        if self.connection is not None:
            self.connection.close()
        self.listener.close()


def instantiate(value, nonce):
    if isinstance(value, str):
        return value.replace("${nonce}", nonce)
    if isinstance(value, list):
        return [instantiate(item, nonce) for item in value]
    if isinstance(value, dict):
        return {key: instantiate(item, nonce) for key, item in value.items()}
    return value


def proportion(passed, total):
    if not total:
        return {"passed": 0, "total": 0, "rate_ppm": 0, "wilson95_ppm": [0, 1000000]}
    p, z = passed / total, 1.959963984540054
    center = (p + z*z / (2*total)) / (1 + z*z/total)
    radius = z * math.sqrt(p*(1-p)/total + z*z/(4*total*total)) / (1 + z*z/total)
    return {"passed": passed, "total": total, "rate_ppm": passed * 1000000 // total,
        "wilson95_ppm": [max(0, math.floor((center-radius)*1000000)), min(1000000, math.ceil((center+radius)*1000000))]}


def summarize(cases, results, policy):
    def score(predicate, field="success"):
        selected = [result for case, result in zip(cases, results) if predicate(case)]
        return proportion(sum(bool(result[field]) for result in selected), len(selected))
    latencies = [result["latency_us"] for result in results]
    calls = sum(result["calls"] for result in results)
    return {"success": score(lambda _: True), "objective": score(lambda c: c["objective"]),
        "task_success": score(lambda c: c["kind"] == "task"),
        "memory_retrieval": score(lambda _: True, "memory_correct"),
        "tool_correctness": score(lambda _: True, "tool_correct"),
        "required_failed": sum(case["required"] and not result["success"] for case, result in zip(cases, results)),
        "crash_timeout": proportion(sum(result.get("runtime_failed", False) for result in results), len(results)),
        "latency_us": {"samples": len(latencies), "mean": sum(latencies)//len(latencies),
            "min": min(latencies), "max": max(latencies)},
        "mock_model": {"calls": calls, "input_tokens": calls * policy["mock_input_tokens"],
            "output_tokens": calls * policy["mock_output_tokens"], "cost_microunits": calls * policy["mock_cost_microunits"]}}


def quality_gate(baseline, proposed, policy, gates):
    delta = proposed["objective"]["rate_ppm"] - baseline["objective"]["rate_ppm"]
    def within_model_budget(key, ratio):
        return proposed["mock_model"][key] * 1000 <= baseline["mock_model"][key] * policy[ratio]
    return (all(gates.values()) and proposed["required_failed"] == 0
        and proposed["success"]["rate_ppm"] + policy["max_success_regression_ppm"] >= baseline["success"]["rate_ppm"]
        and proposed["crash_timeout"]["rate_ppm"] <= policy["max_failure_rate_ppm"]
        and proposed["latency_us"]["mean"] * 1000 <= max(1, baseline["latency_us"]["mean"]) * policy["max_latency_ratio_milli"]
        and within_model_budget("cost_microunits", "max_model_cost_ratio_milli")
        and all(within_model_budget(key, "max_model_tokens_ratio_milli") for key in ("input_tokens", "output_tokens"))
        and (delta >= policy["min_success_delta_ppm"] or policy["repair_approval"] is not None))


def verify_manifest(root, manifest, cap):
    require(isinstance(manifest, dict) and candidate.HEX64.fullmatch(manifest.get("digest", ""))
        and candidate.HEX40.fullmatch(manifest.get("source_revision", ""))
        and candidate.HEX40.fullmatch(manifest.get("source_tree", "")), "invalid_evaluation_artifact")
    artifact = root / "artifacts" / manifest["digest"]
    require(decode((artifact / "manifest.json").read_bytes()) == manifest, "evaluation_manifest_changed")
    with sandbox.sealed_release(artifact / "seed", manifest["digest"], cap):
        pass
    require(candidate.git(root, "rev-parse", "--verify", "refs/generations/" + manifest["digest"]).strip().decode()
        == manifest["source_revision"] and candidate.git(root, "rev-parse", "--verify",
        manifest["source_revision"] + "^{tree}").strip().decode() == manifest["source_tree"], "evaluation_source_changed")


def effective_limits(config, job, lease):
    fields = "id job_id attempt kind status cpu_ms wall_ms reserved_at_ms expires_at_ms"
    require((exact(lease, fields) or exact(lease, fields + " evaluation_binding evaluation_configuration"))
        and lease["job_id"] == job["id"] and lease["attempt"] == job["attempts"]
        and lease["kind"] == "evaluate" and lease["status"] == "reserved"
        and job["status"] == "testing", "evaluation_lease_required")
    now = time.time_ns() // 1000000
    require(integer(lease["cpu_ms"], 4) and integer(lease["wall_ms"])
        and lease["expires_at_ms"] == lease["reserved_at_ms"] + lease["wall_ms"]
        and lease["reserved_at_ms"] <= now < lease["expires_at_ms"] <= job["deadline"]
        and lease["wall_ms"] <= job["limits"]["evaluation_ms"]
        and lease["cpu_ms"] <= job["limits"]["cpu_ms"], "invalid_evaluation_lease")
    limits = dict(config["sandbox_limits"])
    limits["memory_bytes"] = min(limits["memory_bytes"], job["limits"]["memory_bytes"])
    limits["pids"] = min(limits["pids"], job["limits"]["processes"])
    # Four sequential process groups: supplementary tests, baseline, candidate,
    # predecessor restore. Never refund an unused slice or exceed the total lease.
    cpu = min(lease["cpu_ms"] // 4, limits["cpu_seconds"] * 1000)
    limits["cpu_seconds"] = max(1, (cpu + 999)//1000)
    limits["wall_ms"] = min(limits["wall_ms"], lease["expires_at_ms"] - now)
    return limits, cpu, time.monotonic() + (lease["expires_at_ms"] - now)/1000


def evaluate(root, job, lease, config, *, watch_parent=False, configuration_hash=None):
    validate_config(config)
    root = Path(root).absolute()
    require(root.is_dir() and not root.is_symlink() and root.stat().st_uid == os.getuid()
        and root.stat().st_mode & 0o077 == 0, "private_data_root_required")
    require(all((root / name).is_dir() and not (root / name).is_symlink()
        for name in ("source.git", "artifacts", "workspaces")), "invalid_data_root")
    limits, cpu_ms, deadline = effective_limits(config, job, lease)
    require(isinstance(job.get("id"), str) and candidate.HEX64.fullmatch(job["id"]), "invalid_evaluation_job")
    base, proposed, policy = job["baseline"]["artifact"], job["built_artifact"], config["policy"]
    require(proposed.get("producing_job") == job["id"] and proposed.get("producing_attempt") == job["attempts"]
        and proposed.get("parent") == base["digest"] and proposed.get("capabilities") == base["capabilities"]
        and proposed.get("state_schema_versions") == base["state_schema_versions"] == [1], "evaluation_lineage_mismatch")
    verify_manifest(root, base, config["artifact_bytes"])
    verify_manifest(root, proposed, config["artifact_bytes"])
    candidate.reserve(root, config["source_bytes"] + config["artifact_bytes"], job)
    seed = secrets.token_hex(32)
    cases = [instantiate(case, hashlib.sha256(bytes.fromhex(seed) + index.to_bytes(4, "big")).hexdigest()[:32])
        for index, case in enumerate(policy["cases"] * policy["repetitions"])]
    gates = {"isolation": True, "candidate_tests": False, "baseline_contract": False,
             "candidate_contract": False, "rollback_restore": False}
    with tempfile.TemporaryDirectory(prefix="eval-" + job["id"][:12] + "-", dir=root / "workspaces") as directory:
        workspace = Path(directory)
        source = workspace / "source"
        source.mkdir()
        candidate.export_tree(root, proposed["source_revision"], source, config)
        script = HERE / "test_seed.escript"
        with ExitStack() as stack:
            release = stack.enter_context(sandbox.sealed_release(root / "artifacts" / proposed["digest"] / "seed",
                proposed["digest"], config["artifact_bytes"]))
            recipe = stack.enter_context(sandbox.sealed_release(script, hashlib.sha256(script.read_bytes()).hexdigest(), 1048576))
            code, output, reason = sandbox.run(config["cgroup_root"], limits,
                ["/usr/bin/escript", "/judge/tests", str(policy["min_agent_test_modules"])],
                readonly=[(source, "/source")], data_files=[(release, "/agent/seed"), (recipe, "/judge/tests")],
                writable_tmp=["/work"], watch_parent=watch_parent, cpu_budget_ms=cpu_ms)
            gates["candidate_tests"] = code == 0 and reason is None and b"AE_TESTS_V1 " in output
        measurements, retained = [], []
        for manifest, gate in ((base, "baseline_contract"), (proposed, "candidate_contract")):
            results = []
            runtime = None
            try:
                current_limits = {**limits, "wall_ms": max(1, min(limits["wall_ms"], int((deadline-time.monotonic())*1000)))}
                runtime = Runtime(root, workspace, manifest, config, current_limits, cpu_ms, deadline, watch_parent=watch_parent)
                for case in cases:
                    results.append(runtime.turn(case, policy))
                runtime.restore(runtime.sequence + len(results) * 3)
                runtime.health()
                gates[gate] = True
            except (EvaluationError, OSError, subprocess.SubprocessError):
                pass  # Fixed aggregate failure only; no private case diagnostics.
            finally:
                if runtime is not None:
                    runtime.close()
            unreported_calls = max(0, (runtime.model_calls if runtime is not None else 0) - sum(result["calls"] for result in results))
            while len(results) < len(cases):
                results.append({"success": False, "memory_correct": False, "tool_correct": False,
                    "calls": unreported_calls, "latency_us": config["turn_ms"] * 1000, "runtime_failed": True})
                unreported_calls = 0
            measurements.append(summarize(cases, results, policy))
            retained.append(results)
        # Simulate the failed candidate's already-committed conversation and tool
        # result in T0 memory, then restore the predecessor through that sequence.
        latest = next((r for r in reversed(retained[1]) if r.get("outcome") == "reply"), None)
        if latest is not None and gates["baseline_contract"]:
            history = [{"role": "user", "content": "synthetic committed work " + secrets.token_hex(16)},
                {"role": "assistant", "content": latest["reply"]}]
            rollback = {**cases[0], "history": history,
                "expected_messages": history + [{"role": "user", "content": cases[0]["message"]}],
                "expected_text": retained[0][0].get("reply", ""), "expected_type": retained[0][0].get("outcome", "reply")}
            runtime = None
            try:
                current_limits = {**limits, "wall_ms": max(1, min(limits["wall_ms"], int((deadline-time.monotonic())*1000)))}
                runtime = Runtime(root, workspace, base, config, current_limits, cpu_ms, deadline, watch_parent=watch_parent)
                runtime.restore(runtime.sequence + len(cases) * 3 + 1)
                gates["rollback_restore"] = runtime.turn(rollback, policy)["success"]
                runtime.health()
            except (EvaluationError, OSError, subprocess.SubprocessError):
                pass
            finally:
                if runtime is not None:
                    runtime.close()
    return {"version": 1, "job_id": job["id"], "attempt": job["attempts"], "execution_id": lease["id"],
        "baseline_digest": base["digest"], "candidate_digest": proposed["digest"],
        "trial_seed": seed,
        "policy_hash": fingerprint(policy), "harness_hash": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "configuration_hash": configuration_hash or fingerprint(config),
        "source_helper_hash": hashlib.sha256((HERE / "ae_candidate.py").read_bytes()).hexdigest(),
        "test_recipe_hash": hashlib.sha256((HERE / "test_seed.escript").read_bytes()).hexdigest(),
        "sandbox_hash": hashlib.sha256((HERE / "ae_sandbox.py").read_bytes()).hexdigest(),
        "gates": gates, "baseline": measurements[0], "candidate": measurements[1],
        "passed": quality_gate(*measurements, policy, gates), "measured_at_ms": time.time_ns()//1000000,
        "measurement_scope": "synthetic_mock_tools", "uncertainty": "wilson95_binomial; latency_min_mean_max; fixtures_only"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--watch-parent", action="store_true")
    args = parser.parse_args()
    try:
        request, raw_config = decode(args.request.read_bytes()), args.config.read_bytes()
        config = decode(raw_config)
        if "evaluation_binding" in request["lease"]:
            require(request["lease"].get("evaluation_configuration") == raw_config.decode()
                and request["lease"]["evaluation_binding"]["configuration_hash"] == hashlib.sha256(raw_config).hexdigest(),
                "evaluation_configuration_changed")
        result = evaluate(args.data_root, request["job"], request["lease"], config, watch_parent=args.watch_parent,
            configuration_hash=hashlib.sha256(raw_config).hexdigest())
        print(json.dumps({"ok": True, "scorecard": result}, separators=(",", ":")))
    except (EvaluationError, candidate.BuildError, sandbox.Unavailable, OSError, ValueError, KeyError,
            TypeError, subprocess.SubprocessError) as error:
        reason = str(error) if isinstance(error, (EvaluationError, candidate.BuildError, sandbox.Unavailable)) else "evaluation_failed"
        print(json.dumps({"ok": False, "error": reason}, separators=(",", ":")))
        sys.exit(1)


if __name__ == "__main__":
    main()
