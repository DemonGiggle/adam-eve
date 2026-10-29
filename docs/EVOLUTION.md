# Phase 2 foundations

The durable authoring ledger, source reader, patch policy and an agent-side
`seed_evolver` are implemented. An internal `ae_router:author/1` exchanges a
controller-authorized job with the active runtime. The source/status and budgeted
LLM broker capabilities are available only during that exchange, bound to its
job, generation, authenticated runtime and epoch. There is no CLI evolution
command yet, and `evolution_enabled` remains false. The orchestrating
`ae_evolution` state machine, independent evaluator/scorecard, and
publication/retention recovery remain
required before the Phase 2 exit criterion can be claimed.
The fixed reproducible seed recipe is available separately; see [BUILD.md](BUILD.md).
That guide also describes the supervised isolated builder, durable execution
leases, and the gate that keeps its unevaluated output out of production.
Operator backup/restore and its local recovery drill are in [RECOVERY.md](RECOVERY.md).

## Authoring path

Newly published seeds declare `source_list`, `source_read`, `evolution_status`,
`evolution_llm` and `evolution_propose` in their capability manifest. Earlier
conversation-only releases still boot, but cannot be sent an authoring job.
Adding capabilities to an existing identity requires the normal explicit manual
deployment approval, bound to that manifest. No job or agent request changes the
manifest or creates a controller-authorized objective on its own.

`seed_evolver` asks the broker for public job status, then asks the configured
Ollama adapter for a JSON source-list/read action or a complete unified patch
with structured rationale. Source reads support paginated paths and byte ranges;
the strategy keeps bounded recent authoring context instead of requiring the
whole repository in one prompt. Proposal identities include the durable job and
attempt number, and all repairs remain against the original pinned baseline.
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
pagination/ranges, structured patch submission, proposal/call deduplication,
unknown-call denial, budget exhaustion, protected paths, prose-only rejection,
required usage accounting, and continued conversation service. The accepted
patch is data in the ledger; this test does not execute or promote generated
code and does not establish live-model authoring quality.

## Ledger and budgets

`ae_store:evolution(Operation)` dispatches into `ae_evolution_store` inside the
same SQLite transaction mechanism as routing and conversation. New tables retain
jobs, proposal fingerprints/patch hashes, accepted attempts, and LLM reservations.
The current library implements proposing, accepted-for-build, bounded repair,
rejection, and cancellation; it does not run code or deploy artifacts.

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
