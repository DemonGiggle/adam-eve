# Independent candidate evaluation

The supervised Erlang evaluator compares a retained baseline and candidate using
synthetic conversations, then records a scorecard for the specific job,
attempt, artifacts, and evaluation configuration. A passing score does not grant
approval: staging and explicit operator approval are separate steps.

The evaluator and generated processes run on the host as the controller user.
Separate BEAM processes and synthetic inputs do not prevent candidate code from
reading or modifying host resources. See [Host execution](HOST_EXECUTION.md).

Before evaluation, the controller reserves a durable execution lease and binds
the configuration and hashes of the evaluator, runtime peer, source exporter,
and supplementary test recipe. The store validates the scorecard against that
lease and retains it with its digest. Existing scorecards with the historical
`isolation` gate remain readable; new scorecards report `host_execution`.
Interrupted reservations are not silently reissued or refunded.

The evaluator runs the candidate's EUnit/Common Test modules in a separate host
BEAM, then runs paired synthetic cases against separate baseline and candidate
runtimes. It validates the framed protocol, request and epoch correlation,
capabilities, idempotency, restore, health, and expected mocked tool behavior. A
further predecessor run checks restoration of synthetic context containing an
acknowledged candidate reply. The evaluator sends mock responses and does not
intentionally call the configured live provider for these cases.

Scores include success, objective success, memory and tool correctness, required
failures, crash/timeout rate, latency, and configured mock-model token/cost
counts. Rates include nominal Wilson 95% binomial intervals. These are fixture
measurements, not estimates of general user-task quality or live billing.
Failed evaluations retain their scorecard and return a bounded public summary for
repair. Candidate tests and generated code can access the host directly, so
private policy and host data must not be treated as protected against them.

## Required configuration

Set `AE_EVAL_CONFIG_JSON` to an object containing these fields. Missing or
invalid configuration disables the evaluator.

| Field | Meaning |
|---|---|
| `source_bytes`, `source_files`, `artifact_bytes` | Retained source and release size ceilings |
| `output_bytes` | Maximum captured output from supplementary tests |
| `cpu_ms` | Pessimistic job-budget reservation; not an enforced CPU limit |
| `wall_ms` | Evaluation lease and worker deadline |
| `startup_ms`, `turn_ms` | Runtime handshake/restore and per-turn deadlines |
| `policy` | Complete evaluation policy described below |

Legacy configuration objects are accepted for retained records and existing
setups, but their cgroup and sandbox fields do not enforce isolation.

Policy version 1 requires `version`, `repetitions`, `min_success_delta_ppm`,
`max_success_regression_ppm`, `max_latency_ratio_milli`,
`max_model_cost_ratio_milli`, `max_model_tokens_ratio_milli`,
`max_failure_rate_ppm`, `max_tool_requests`, `mock_input_tokens`,
`mock_output_tokens`, `mock_cost_microunits`, `repair_approval`,
`min_agent_test_modules`, and `cases`. There are no implicit thresholds.
Parts per million express rates; a ratio of 1000 means the candidate may use at
most the baseline quantity. A non-null repair approval must be an explicit
operator reference; otherwise a positive objective-success improvement is
mandatory. Production promotion still needs its own artifact-bound approval.

Each case requires `id`, `message`, `history`, `model_result`,
`expected_messages`, `expected_type`, `expected_text`, `kind`, `required`, and
`objective`. Histories and expected model messages use role/content objects;
the model result is either a text or error object. Kinds must cover task, memory
and tool cases, with at least one required regression and one objective case.
`${nonce}` in strings receives the same fresh value for each paired trial.

The candidate must pass hard gates and every required case, stay within all
configured regression/latency/model-budget/failure thresholds, and meet the
objective improvement threshold or explicit repair exception. Passing these
tests is not a claim of general intelligence improvement.

[test/evaluation/policy.json](../test/evaluation/policy.json) is a synthetic
fixture policy, not a default production policy. The host integration suite
covers successful and failing EUnit/Common Test cases, baseline/candidate
comparisons, synthetic rollback, and the full author-to-promotion path.
