# Independent candidate evaluation

`ae_eval_sup:start_job(JobId, Config, NotifyPid)` starts a temporary supervised
`ae_evaluator` for a built job in `testing`. It runs the controller-owned Python
judge outside the candidate runtime. The evolution state machine and operator
CLI connect authoring, build, evaluation and staging. Evaluation does not grant deployment
approval. Digest-only manual staging rejects generated releases; trusted
`ae_deployment:stage_evolution/1` requires the specific evaluated job, performs
fresh isolated standby checks, and then waits for explicit bound approval.
That stage reserves its own remaining job CPU allowance before launch and
retains the job's requested resource ceilings and absolute runtime deadline.
Complete aggregate CPU/memory/process enforcement requires the optional cgroup
profile and is deferred to v0.2; the v0.1 host profile uses per-process limits.

## Isolation and durable results

Before starting, the worker verifies the retained baseline and candidate and
reserves a durable evaluation execution lease. The lease pins hashes of the
complete evaluator configuration, judge, source-export helper, sandbox launcher,
and supplementary test recipe. A result must match that lease, job, attempt,
baseline digest and candidate digest, arrive before expiry, and have a valid
bounded scorecard. Unknown reservations cannot silently launch another execution.
The exact private configuration is retained in SQLite with its reservation and
therefore included in consistent backups. Each scorecard retains a fresh trial
seed, allowing an operator to reconstruct its nonce cases from that policy.

Four sequential sandbox process groups share pessimistically reserved CPU
slices: agent tests, baseline runtime, candidate runtime, and predecessor restore.
Unused slices are not refunded. Requested memory/process limits cannot exceed
the job's limits; the whole evaluation also has a deadline. Each process group
uses the mandatory namespace/seccomp boundary and its explicitly configured
resource profile. Aggregate watchdogs require the cgroup profile. Missing
namespace isolation fails closed; selecting cgroups never automatically downgrades.

The judge keeps private cases, expected values, mock tools and synthetic history
in its own process. A runtime receives only its sealed release and IPC socket.
Agent tests receive public source and their selected release, plus the fixed test
recipe in a separate sandbox. No case file, production database, credentials,
live provider endpoint or production broker is mounted or passed to candidates.
Generated archives and BEAM modules are decoded only inside these sandboxes.

The store retains a scorecard and its digest under the attempt. Passing advances
the job to `evaluated`. Failure retains the measurements and uses the original
repair/attempt budget; repair feedback is a fixed public summary without private
inputs, expected answers, replies or child diagnostics. The artifact manifest
stays immutable, including its original null `evaluation` field. The separate
trusted ledger is the authority for evaluation results.

## Checks and measurements

The judge validates authentication, strict bounded frames/schemas, request and
epoch correlation, capabilities, idempotency keys, health, initial and repeated
restore, and the configured behavior. Only mocked `memory_read` and `llm` tools
are available. Duplicate identical tool calls replay a result; conflicting keys,
unknown tools, fabricated event references and stale epochs fail the contract.

Baseline and candidate receive the same independently generated nonce cases.
After stopping the candidate through its sandbox owner's pipe, the judge starts
a fresh predecessor, restores a later synthetic sequence, and tests context that
includes a candidate reply. This is a synthetic compatibility check. The actual
store's completed-effect preservation is tested separately through an actual
generated-candidate promotion/crash/rollback. Successive LLM-authored generations
and full orchestrator recovery still need end-to-end acceptance coverage.

The supplementary recipe compiles agent test modules and runs EUnit and Common
Test suites. A configured minimum module count can require agent tests. Common
Test uses basic HTML logging so it does not need distribution-specific JavaScript
symlinks outside the mounted toolchain. Agent tests cannot replace the outer
judge or weaken its policy.

Scorecards contain absolute baseline/candidate success, objective success,
memory retrieval, tool correctness, required-case failures, crash/timeout-affected trial rate,
latency samples/minimum/mean/maximum, and configured mock-model call/token/cost
totals. Rates include nominal Wilson 95% binomial intervals over synthetic
trials. These intervals do not estimate generalization to real user tasks;
mock token/cost values are explicit fixture measurements, not live billing data.

## Required configuration

Set `AE_EVAL_CONFIG_JSON` to an object containing the required fields below.
Missing or invalid configuration disables the evaluator.

| Field | Meaning |
|---|---|
| `cgroup_root` | Absolute cgroup path; unused by the process profile |
| `resource_limits_mode` | Optional: `process` for v0.1 host execution; omitted values preserve the strict `cgroup` profile |
| `source_bytes`, `source_files`, `artifact_bytes` | Public source/export and release ceilings |
| `sandbox_limits` | All nine resource fields documented in [ISOLATION.md](ISOLATION.md) |
| `startup_ms`, `turn_ms` | Bounded runtime handshake/restore and per-turn deadlines |
| `policy` | Complete trusted policy described below |

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

[test/evaluation/policy.json](../test/evaluation/policy.json) is a small synthetic
test policy, not a production policy or default budget. Judge checks run with
`scripts/test`, including actual restricted host comparisons, supplementary-test
failures and supervised evaluation with the process profile. Set
`AE_TEST_RESOURCE_LIMITS_MODE=cgroup` and `AE_TEST_CGROUP_ROOT` to repeat those
checks with aggregate enforcement. Software-emulated validation can explicitly select
`AE_TEST_EVAL_WALL_MS` and `AE_TEST_EVAL_CPU_MS`; those values do not alter
production configuration.

Validation includes the native controller/integration suite using Bubblewrap
process limits, as well as earlier separate
unprivileged Linux VM runs with delegated cgroups: passing EUnit/Common Test,
deliberately failing suites, accepted and rejected behavioral comparisons,
predecessor restore, and supervised author → build → evaluate. Integration also
checks concurrent conversation service, no synthetic turns in production
history, retained private policy bytes, and fail-closed unavailable isolation.
Software emulation used explicit test allowances of 180000 ms wall/90000 ms CPU
for builds and 600000 ms wall/240000 ms aggregate reserved CPU for evaluations.
An additional VM integration explicitly approves and promotes a fixture-authored
candidate, kills it after an acknowledged reply/tool result, and verifies both
records after rollback under a new epoch. These checks use a fixture provider;
they do not establish live-model authoring quality or authorize a user's production identity.
