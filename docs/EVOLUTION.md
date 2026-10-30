# Controlled evolution

The durable authoring ledger, source reader, patch policy and an agent-side
`seed_evolver` are implemented. An internal `ae_router:author/1` exchanges a
controller-authorized job with the active runtime. The source/status and budgeted
LLM broker capabilities are available only during that exchange, bound to its
job, generation, authenticated runtime and epoch. The supervised `ae_evolution`
state machine drives authoring, bounded repair, build, independent evaluation,
and staging, then waits for explicit operator approval. Evolution is disabled by
default. Publication/retention recovery coverage and successive live-model
generations remain required before the Phase 2 exit criterion can be claimed.
The fixed reproducible seed recipe is available separately; see [BUILD.md](BUILD.md).
That guide also describes the supervised isolated builder, durable execution
leases, and the gate that keeps its unevaluated output out of production.
Operator backup/restore and its local recovery drill are in [RECOVERY.md](RECOVERY.md).
The supervised independent evaluator and durable scorecards are implemented;
see [EVALUATION.md](EVALUATION.md). They do not enable deployment by themselves.
An evaluated job can now be passed to `ae_deployment:stage_evolution/1` by trusted
controller code. Staging combines its immutable scorecard with fresh standby
checks; the operator must explicitly approve the resulting artifact/baseline/
evaluation binding. The digest-only manual staging path still rejects generated
releases. Every linked deployment transition updates the evolution job inside
the routing/store transaction, including observation completion and rollback.
Approval expiry is capped by the job deadline, and promotion must leave enough
budget for observation. Authoring remains bound to the original author, even
after the candidate has become active.
Before staging, the store reserves the lesser of the remaining aggregate job
CPU budget and the configured runtime CPU ceiling. The reservation survives
restart and is never refunded. Memory/process limits are clamped to job limits;
startup and the sandbox watchdog share the absolute lease deadline. Approval and
observation cannot outlive that runtime lease. Promotion does not relax these
limits: the same process retains its lease, and any later ordinary recovery uses
fresh runtime limits under a new epoch. Aggregate lifetime CPU enforcement
requires the cgroup profile; the v0.1 host process profile retains pessimistic
reservations, per-process limits, and the absolute wall deadline without claiming
aggregate CPU/memory/process enforcement.

## Operator commands and recovery

Enabling requires `AE_EVOLUTION_ENABLED=true`, complete
`AE_EVOLUTION_LIMITS_JSON`, `AE_BUILD_CONFIG_JSON` ([BUILD.md](BUILD.md)),
`AE_EVAL_CONFIG_JSON` ([EVALUATION.md](EVALUATION.md)), and all four handoff
timeouts (`AE_APPROVAL_TTL_MS`, `AE_OBSERVE_MS`, `AE_HEALTH_INTERVAL_MS`,
`AE_QUIESCE_TIMEOUT_MS`). An explicit `AE_RETENTION_POLICY_JSON` is also required;
the supported preservation policy and disk-pressure gate are documented in
[RETENTION.md](RETENTION.md). The runtime must use Bubblewrap and explicit sandbox
limits as documented in [ISOLATION.md](ISOLATION.md). For v0.1 host execution,
select `AE_RESOURCE_LIMITS_MODE=process` and `resource_limits_mode: process` in
both builder/evaluator JSON configurations. Delegated cgroups are optional for
the stronger profile and are no longer an MVP prerequisite.
Missing or invalid evolution configuration leaves ordinary service available
and makes a trigger return `evolution_disabled`; an operator enable request
returns `evolution_not_configured`. There is no generated-code host fallback.

The operator CLI accepts:

```jsonl
{"op":"evolve","origin_ref":"operator-change-1","objective":"Describe the bounded behavioral improvement."}
{"op":"evolution"}
{"op":"evolution","job_id":"<returned id>"}
{"op":"evolution_cancel","job_id":"<job id>"}
{"op":"evolution_enable","enabled":false}
{"op":"evolution_enable","enabled":true}
```

The trigger returns the durable job. Reusing its origin with the same objective
and limits returns that job, including after a terminal outcome, runtime fencing,
or restart; changed objective/limits return `origin_conflict`. Use a new origin
for a new improvement. Only one job or manual deployment can own the identity.
Job inspection includes the current attempt's complete proposal (source patch,
hypothesis, expected benefit, risks, and requested tests), lineage, exact artifact manifest,
independent scorecard and rollback gate. Once standby checks pass, it also
includes `deployment_id` and `approval_binding`. Inspect those and the retained
source diff, then use the existing explicit approval command:

```jsonl
{"op":"approve","deployment_id":"<deployment_id>","approval_binding":"<approval_binding>"}
```

An ordinary turn may return busy during the bounded authoring exchange. The
active runtime serves while separate build/evaluation workers run and while
approval is pending. Approval does not reset any budget or lease deadline.

Disable persists in SQLite across restart and requires an explicit re-enable.
It stops further evolution reservations/approvals and cancels the active job.
Before promotion this rejects standby output; during observation it closes
candidate admission before restoring the predecessor under a fresh epoch.
Ordinary service continues after cleanup, with acknowledged replies/results
retained. Cancellation is asynchronous; inspect the job until its terminal
outcome. A failed rollback leaves closed admission and a degraded job for
operator inspection.

On orchestrator restart, an unlinked job is cancelled without refund or automatic
reissue of unknown work, surviving supervised workers are stopped, and an active
author exchange is interrupted and fenced. Linked deployments are reconciled
with the deployment manager: uncommitted promotions are rejected, incomplete
observations roll back. Promotion restore and rollback intent are durable before
checkpoint/replay. Retrying an already committed rollback does not stop the
restored active runtime. `test/integration/evolution_crash.py` kills the whole
controller during a reserved model call, pending generated approval, and
observation after a candidate acknowledges a reply. Real restricted runtimes
recover with fresh epochs, retain reservations and code, refuse stale approvals,
and replay acknowledged replies without another provider call. Unknown authoring
is not reissued; precommit approval is rejected; unobserved committed code rolls
back. A test-only boundary driver additionally pauses coordinators after the real
author/build/evaluate/stage path, then drives the same trusted store APIs to stop
exactly after approval, quiescing, preparation for promotion, routing commit
before activation, rollback intent, and rollback commit before activation. The
parent kills the whole BEAM and verifies recovery, preserved reservations and
acknowledged work, and stale-approval refusal at each boundary. These are
deterministic transaction-boundary checks, without production fault hooks or
scheduler-dependent timing claims.

## Authoring path

Newly published seeds declare `source_list`, `source_read`, `evolution_status`,
`evolution_llm` and `evolution_propose` in their capability manifest. Earlier
conversation-only releases still boot, but cannot be sent an authoring job.
Adding capabilities to an existing identity requires the normal explicit manual
deployment approval, bound to that manifest. No job or agent request changes the
manifest or creates a controller-authorized objective on its own.

`seed_evolver` asks the broker for public job status, then asks the configured
Ollama adapter for a JSON source-list/read action, an exact-text edit, or a complete
unified patch with structured rationale. Source reads support paginated paths and byte ranges;
the strategy keeps bounded recent authoring context instead of requiring the
whole repository in one prompt. Proposal identities include the durable job and
attempt number, and all repairs remain against the original pinned baseline.
The first model request explicitly asks for source discovery before proposing.
The preferred `edit` action supplies `edits, hypothesis, expected_benefit, risks,
requested_tests`. Its `edits` list contains 1–32 `{path, old_text, new_text}`
replacements applied in list order. A single replacement at the top level is
also supported. Each replacement must match one unique, nonempty exact source
span. One action submits a complete proposal immediately: disjoint call-site
changes and new helper definitions must appear together in that list. The agent caches
contiguous source reads starting at offset zero within the job's source budget;
only a complete file can be edited. It constructs whole-file unified diffs from
the original immutable bytes, including final-newline markers, and submits one
ordinary proposal within a shared patch budget. An invalid replacement rejects
the entire batch without changing the cache. Missing/incomplete source, ambiguous text and oversized patches return
public feedback within the same call/deadline budget. Direct proposals remain
available for multiple files, new files and edits exceeding the whole-file diff
budget. The controller's path checks, Git application, build and independent
evaluation are identical for both actions.
The Ollama adapter supplies an exact JSON schema for source-list, source-read,
edit and proposal actions, with required rationale fields and no extra properties;
authoring uses temperature zero. This follows Ollama's
[structured output interface](https://docs.ollama.com/capabilities/structured-outputs).
The agent and broker still validate actions, scope and budgets independently;
schema-constrained decoding does not establish source or patch correctness.
The authoring exchange and its RPC waits use the durable job deadline. Each
HTTP call uses the authoring-only `AE_EVOLUTION_LLM_TIMEOUT_MS` (100–3600000 ms)
when set, otherwise the ordinary provider timeout. Every call is also capped by the job's remaining
time. A malformed authoring timeout disables evolution while ordinary service
remains available. Source-read examples use the job's permitted
page size to reduce unnecessary model round trips.
The advertised raw read size accounts for JSON/base64 overhead, and the model's
source-read schema is capped to that job-specific window.
The authoring exchange has a request-count ceiling and a deadline even if a
misbehaving seed continuously sends already-buffered messages. User turns are
temporarily busy during authoring; health/status and recovery stay in the trusted
controller. After an accepted proposal or an ordinary authoring failure, the seed
can resume conversations. Protocol violations stop and fence the runtime.

Authoring LLM calls reserve their full configured token/cost bound before HTTP.
The reservation is split between the provider's context window (`num_ctx`) and
output limit (`num_predict`), with neither unlimited. Successful authoring
responses require nonnegative provider usage counts within those bounds; missing
accounting is rejected, and an accounting violation cancels the job. Cached prompt
usage is counted conservatively as additional input. The provider must honor its
requested limits; this is a trust boundary with the configured inference service,
not an independent tokenizer or control of its host resources. See the official
[Ollama parameter reference](https://docs.ollama.com/modelfile) and
[chat response fields](https://docs.ollama.com/api/chat).

Completed calls replay their durable result without HTTP. An unresolved reserved
call is never automatically reissued. Provider errors consume the reservation,
and call-ID reuse with changed messages is rejected. Conversation context and
authoring context use separate broker entry points, preventing an ordinary user
turn from invoking source tools by changing a tool name.

`test/integration/authoring.py` exercises an actual published seed/BEAM runtime,
Unix IPC, scoped Git source and a fixture HTTP provider. It verifies source
pagination/ranges, structured patch submission, complete-file edit assembly,
incomplete-edit feedback and retry without a budget reset, proposal/call deduplication,
unknown-call denial, budget exhaustion, protected paths, prose-only rejection,
required usage accounting, and continued conversation service. The native suite
also executes restricted host builds/evaluations and generated
promotion/rollback with the process profile. `AE_TEST_RESOURCE_LIMITS_MODE=cgroup`
and `AE_TEST_CGROUP_ROOT` select the stronger profile. `orchestrated-rollback` uses the state machine to
repair a real compile failure, reach explicit approval, preserve acknowledged
work through candidate crash/rollback, and verify persistent disable/re-enable
across restart. Fixture authoring does not establish live-model authoring quality.

## Ledger and budgets

`ae_store:evolution(Operation)` dispatches into `ae_evolution_store` inside the
same SQLite transaction mechanism as routing and conversation. New tables retain
jobs, proposal fingerprints/patch hashes, accepted attempts, and LLM reservations.
The ledger implements proposing, accepted-for-build, testing, evaluated, bounded
repair, rejection, and cancellation. Supervised workers perform isolated builds
and evaluations; linked deployment transitions cover staging, manual approval,
quiescence, durable promotion/rollback intent, observation, completion, rejection,
and rollback. The orchestrator observes these durable records and owns supervised
workers; private test configuration remains unavailable to the authoring agent.

Creating a job requires a trusted `origin_ref`, objective, the committed active
slot/runtime/generation/source/epoch, and a complete validated limits map. There
are no implicit evolution limits. Identical origin retransmissions reuse the
existing job; conflicting reuse is rejected even after restart. An unfinished
manual deployment and an evolution job cannot overlap. Replacing the active
runtime cancels its pinned authoring job, including when the slot/artifact stays
the same.

Required limit keys are:

```text
max_attempts, total_ms, max_llm_calls, tokens_per_call, max_tokens,
max_cost_microunits, cost_per_call_microunits, max_patch_bytes,
max_diagnostic_bytes, max_source_calls, max_source_bytes, source_page_bytes,
build_ms, evaluation_ms, cpu_ms, memory_bytes, processes, disk_reserve_bytes
```

Each LLM call reserves the configured worst-case tokens and cost **before** the
outbound call. The trusted broker must enforce that per-call bound; the agent
cannot choose a cheaper reservation. Reservations survive crashes and are never
refunded by these APIs. An identical completed call reuses the stored result;
a reserved call without a result reports an unknown outcome rather than issuing
another potentially billed call. Call/proposal IDs cannot be reused with changed
contents. Proposals with identical contents reuse the accepted attempt and do not
consume another build. Repairs are complete diffs against the original pinned
baseline, with durable attempt counts and bounded public diagnostics. Private
evaluator output must never be passed into the public-diagnostics API.

Source operations reserve one page of byte credit before reading. Failed reads
do not restore that credit. The deadline, call/token/cost counts, source credits,
proposal IDs, patch hashes, and attempt counts persist across store restart.
Budget exhaustion terminates the job. No repair resets the job's deadline or
reservations.

## Immutable source access

`ae_source:list/5` and `read/6` authorize against the committed runtime and job
before accessing the pinned Git revision, then recheck authorization before
returning data. They verify its protected generation ref. Neither operation
reads a development checkout, controller source, private evaluator cases, or
host files. Git runs without a shell, global/system configuration, replacement
objects, text conversion, or network operations.

Listings stream Git metadata into bounded pages of at most 32 entries. Reads
stream byte ranges from regular blobs; they can read beyond a 1 MiB file offset
without returning the whole file. Content is base64 encoded so byte offsets do
not corrupt UTF-8. Responses include the job, base artifact, and source revision.
Symlink blobs are withheld. Readable paths comprise seed Erlang source/headers
and seed tests, explicit dependency/application manifests, the shared public
protocol, and public protocol documentation when present in the retained tree.
Files such as `.env`, controller modules, and private tests are excluded.
Protected source-path requests reject the job.

`ae_patch` admits a bounded subset of unified diffs for regular `.erl`/`.hrl`
files under seed source/tests. It rejects traversal, ambiguous/quoted paths,
renames, binary patches, symlink modes, dependency/application manifests, and
protected trees. Protected patch violations are terminal and retain an audit
hash. This lexical gate is necessary but insufficient: the builder must still
verify the base tree, reject symlinks/submodules in the workspace, apply/check
the patch with Git, and execute every compiler hook/test in the OS sandbox.

The tests cover reservation/repair persistence, retransmissions and conflicting
IDs, baseline replacement, source budgets, expiry, protected paths, paginated
disclosure, and ranges in a 1.2 MB source fixture. These checks are not evidence
of an implemented end-to-end self-evolution loop.
