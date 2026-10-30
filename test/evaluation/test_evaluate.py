"""Judge tests and optional actual-kernel baseline/candidate comparison."""
import copy
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import unittest
from unittest import mock

CHECKOUT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(CHECKOUT / "apps/ae_core/priv"))
import ae_evaluate as judge


def policy(prefix="authored:"):
    result = json.loads((Path(__file__).with_name("policy.json")).read_bytes())
    for case in result["cases"]:
        if case["expected_type"] == "reply":
            case["expected_text"] = case["expected_text"].replace("authored:", prefix, 1)
    return result


class Conversation(judge.Runtime):
    """Fixed data peer for testing the judge; no release executes on this path."""
    def __init__(self, incoming):
        self.incoming, self.sent = iter(incoming), []
        self.deadline, self.config = time.monotonic() + 5, {"turn_ms": 1000}
        self.manifest, self.epoch, self.sequence = {"capabilities": ["memory_read", "llm"]}, 42, 12
        self.model_calls = 0

    def send(self, kind, **fields):
        self.sent.append({"type": kind, **fields})

    def recv(self, _):
        return judge.validate_message(next(self.incoming))


def envelope(kind, **fields):
    return {"protocol_version": 1, "type": kind, "request_id": "request", **fields}


def tool(name, args, key=None):
    return envelope("tool_request", epoch=42, tool=name, args=args, idempotency_key=key or name)


class JudgeTests(unittest.TestCase):
    def setUp(self):
        self.policy = policy()
        self.case = judge.instantiate(self.policy["cases"][0], "private-nonce")
        self.incoming = [tool("memory_read", {}), tool("llm", {"messages": self.case["expected_messages"]}),
            envelope("assistant_reply", text=self.case["expected_text"], event_refs=[])]

    def run_turn(self, incoming=None):
        runtime = Conversation(self.incoming if incoming is None else incoming)
        with mock.patch.object(judge.secrets, "token_hex", return_value="request"):
            result = runtime.turn(self.case, self.policy)
        return result, runtime

    def test_policy_requires_explicit_comparison_and_private_categories(self):
        self.assertEqual(judge.validate_policy(self.policy), self.policy)
        for changed in ({}, {**self.policy, "min_success_delta_ppm": 0},
                        {**self.policy, "cases": self.policy["cases"][:1]},
                        {**self.policy, "mock_input_tokens": True}):
            with self.assertRaises(judge.EvaluationError):
                judge.validate_policy(changed)
        self.assertEqual(judge.validate_policy({**self.policy, "min_success_delta_ppm": 0,
            "repair_approval": "operator-approved-repair"})["min_success_delta_ppm"], 0)

    def test_nonce_memory_tool_correlation_and_idempotent_replay(self):
        self.incoming.insert(2, copy.deepcopy(self.incoming[1]))
        result, runtime = self.run_turn()
        self.assertTrue(result["success"])
        self.assertEqual(result["calls"], 1)
        self.assertEqual(runtime.sent[1]["result"]["messages"][-1]["content"], self.case["message"])
        self.assertNotIn("expected_text", json.dumps(runtime.sent))

    def test_wrong_context_cannot_pass_with_the_expected_reply(self):
        self.incoming[1]["args"]["messages"] = [{"role": "user", "content": "hardcoded"}]
        result, _ = self.run_turn()
        self.assertFalse(result["success"])
        self.assertFalse(result["memory_correct"])

    def test_completed_model_call_is_counted_before_a_protocol_failure(self):
        runtime = Conversation(self.incoming[:2] + [{**self.incoming[2], "event_refs": "invalid"}])
        with mock.patch.object(judge.secrets, "token_hex", return_value="request"), self.assertRaises(judge.EvaluationError):
            runtime.turn(self.case, self.policy)
        self.assertEqual(runtime.model_calls, 1)

    def test_stale_epoch_privilege_escalation_and_conflicting_keys_fail(self):
        bad_messages = [tool("shell", {"command": "id"}),
            {**tool("memory_read", {}), "epoch": 41},
            envelope("assistant_reply", text=self.case["expected_text"], event_refs=[1]),
            {**tool("memory_read", {}), "request_id": "other"}]
        for bad in bad_messages:
            with self.subTest(message=bad), self.assertRaises(judge.EvaluationError):
                self.run_turn([bad])
        with self.assertRaisesRegex(judge.EvaluationError, "idempotency_conflict"):
            self.run_turn([tool("memory_read", {}), tool("llm", {"messages": []}, "memory_read")])

    def test_strict_frames_and_schema(self):
        for data in (b'{"type":1,"type":2}', b'{"value":NaN}', b'{"a":'):
            with self.assertRaises(judge.EvaluationError):
                judge.decode(data)
        for message in ({**self.incoming[0], "epoch": True}, {**self.incoming[0], "extra": "leak"},
                        {**self.incoming[0], "protocol_version": True}, {**self.incoming[0], "request_id": "\ud800"}):
            with self.assertRaises(judge.EvaluationError):
                judge.validate_message(message)
        connection, peer = socket.socketpair()
        self.addCleanup(connection.close)
        self.addCleanup(peer.close)
        runtime = judge.Runtime.__new__(judge.Runtime)
        runtime.connection = connection
        runtime.read = lambda size, _: peer.recv(size)
        connection.sendall(struct.pack("!I", judge.MAX_FRAME + 1))
        with self.assertRaisesRegex(judge.EvaluationError, "frame_limit"):
            runtime.recv(time.monotonic() + 1)

    def test_quality_gate_blocks_safety_regression_cost_and_no_improvement(self):
        results = [{"success": True, "memory_correct": True, "tool_correct": True,
            "calls": 1, "latency_us": 100} for _ in self.policy["cases"]]
        baseline_results = copy.deepcopy(results)
        baseline_results[0]["success"] = False
        baseline = judge.summarize(self.policy["cases"], baseline_results, self.policy)
        proposed = judge.summarize(self.policy["cases"], results, self.policy)
        self.assertTrue(judge.quality_gate(baseline, proposed, self.policy, {"contract": True}))
        self.assertFalse(judge.quality_gate(baseline, proposed, self.policy, {"contract": False}))
        self.assertFalse(judge.quality_gate(proposed, proposed, self.policy, {"contract": True}))
        for field, value in (("required_failed", 1), ("mock_model", {**proposed["mock_model"], "cost_microunits": 4})):
            self.assertFalse(judge.quality_gate(baseline, {**proposed, field: value}, self.policy, {"contract": True}))
        interval = proposed["success"]["wilson95_ppm"]
        self.assertLess(interval[0], 1000000)
        self.assertEqual(interval[1], 1000000)


@unittest.skipUnless(os.getenv("AE_TEST_RESOURCE_LIMITS_MODE", "process") == "process" or os.getenv("AE_TEST_CGROUP_ROOT"),
    "strict cgroup profile requires delegation")
class RestrictedEvaluationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(CHECKOUT / "test/build"))
        import test_candidate
        cls.fixture_class = test_candidate.CandidateTests
        cls.fixture_class.setUpClass()

    @classmethod
    def tearDownClass(cls):
        cls.fixture_class.tearDownClass()

    def test_independent_comparison_and_rollback_restore(self):
        fixture = self.fixture_class()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        tests = {
            "apps/ae_seed/test/seed_tests.erl": '-module(seed_tests).\n-include_lib("eunit/include/eunit.hrl").\n'
                'protocol_test() -> ?assertEqual(ok, ae_protocol:validate(#{<<"protocol_version">> => 1, '
                '<<"type">> => <<"health_check">>, <<"request_id">> => <<"unit">>})).\n',
            "apps/ae_seed/test/seed_SUITE.erl": '-module(seed_SUITE).\n-export([all/0, protocol/1]).\n'
                'all() -> [protocol].\nprotocol(_) -> ok = ae_protocol:validate(#{<<"protocol_version">> => 1, '
                '<<"type">> => <<"health_check">>, <<"request_id">> => <<"ct">>}), ok.\n'}
        extra = ""
        for path, content in tests.items():
            extra += f"diff --git a/{path} b/{path}\nnew file mode 100644\n--- /dev/null\n+++ b/{path}\n@@ -0,0 +1,{len(content.splitlines())} @@\n"
            extra += "".join("+" + line for line in content.splitlines(True))
        patch = fixture.proposal["patch"] + extra
        fixture.proposal.update({"patch": patch, "patch_hash": judge.hashlib.sha256(patch.encode()).hexdigest(),
            "paths": fixture.proposal["paths"] + list(tests)})
        proposed = judge.candidate.build(fixture.root, fixture.job, fixture.proposal, fixture.lease, fixture.config)
        wall = int(os.environ.get("AE_TEST_EVAL_WALL_MS", "180000"))
        cpu = int(os.environ.get("AE_TEST_EVAL_CPU_MS", "60000"))
        job = {**fixture.job, "status": "testing", "built_artifact": proposed,
            "deadline": time.time_ns()//1000000 + wall * 3,
            "limits": {**fixture.job["limits"], "evaluation_ms": wall, "cpu_ms": cpu * 3}}
        config = {k: fixture.config[k] for k in ("cgroup_root", "source_bytes", "source_files", "artifact_bytes", "resource_limits_mode")}
        config.update({"startup_ms": 30000, "turn_ms": 15000, "policy": policy(),
            "sandbox_limits": {**fixture.config["sandbox_limits"], "wall_ms": wall, "cpu_seconds": (cpu+3999)//4000}})
        for prefix, expected in (("authored:", True), ("", False)):
            started = time.time_ns()//1000000
            lease = {"id": os.urandom(32).hex(), "job_id": job["id"], "attempt": 1,
                "kind": "evaluate", "status": "reserved", "cpu_ms": cpu, "wall_ms": wall,
                "reserved_at_ms": started, "expires_at_ms": started + wall}
            config["policy"] = policy(prefix)
            config["policy"]["min_agent_test_modules"] = 2
            scorecard = judge.evaluate(fixture.root, job, lease, config)
            self.assertEqual(scorecard["passed"], expected, scorecard)
            self.assertTrue(all(scorecard["gates"].values()), scorecard)
            self.assertEqual(scorecard["candidate_digest"], proposed["digest"])
            self.assertEqual(scorecard["candidate"]["mock_model"]["calls"], 6)
            self.assertNotIn("answer ", json.dumps(scorecard))
            self.assertEqual(list((fixture.root / "workspaces").iterdir()), [])
        self.assertIsNone(json.loads((fixture.root / "artifacts" / proposed["digest"] / "manifest.json").read_bytes())["evaluation"])

    def test_failing_eunit_and_common_test_are_blocking(self):
        import tempfile
        config = {"memory_bytes": 536870912, "pids": 64, "cpu_percent": 100, "cpu_seconds": 60,
            "address_space_bytes": 1073741824, "file_bytes": 33554432, "open_files": 128,
            "output_bytes": 1048576, "wall_ms": 180000}
        root, base = self.fixture_class.base_root, self.fixture_class.base
        for name, content, marker in (
            ("bad_tests", '-module(bad_tests).\n-include_lib("eunit/include/eunit.hrl").\nfail_test() -> error(expected_unit_failure).\n', b"expected_unit_failure"),
            ("bad_SUITE", '-module(bad_SUITE).\n-export([all/0, fail/1]).\nall() -> [fail].\nfail(_) -> ct:fail(expected_ct_failure).\n', b"expected_ct_failure")):
            with self.subTest(name=name), tempfile.TemporaryDirectory(dir=root / "workspaces") as directory:
                source = Path(directory)
                test_path = source / "apps/ae_seed/test"
                test_path.mkdir(parents=True)
                (test_path / (name + ".erl")).write_text(content)
                recipe = judge.HERE / "test_seed.escript"
                with judge.sandbox.sealed_release(root / "artifacts" / base["digest"] / "seed", base["digest"], 8388608) as release, \
                        judge.sandbox.sealed_release(recipe, judge.hashlib.sha256(recipe.read_bytes()).hexdigest(), 1048576) as script:
                    code, output, reason = judge.sandbox.run(os.environ.get("AE_TEST_CGROUP_ROOT", "/sys/fs/cgroup"), config,
                        ["/usr/bin/escript", "/judge/tests", "1"], readonly=[(source, "/source")],
                        data_files=[(release, "/agent/seed"), (script, "/judge/tests")], writable_tmp=["/work"],
                        resource_limits_mode=os.getenv("AE_TEST_RESOURCE_LIMITS_MODE", "process"))
                    self.assertNotEqual(code, 0)
                    self.assertIsNone(reason)
                    self.assertIn(marker, output)


if __name__ == "__main__":
    unittest.main()
