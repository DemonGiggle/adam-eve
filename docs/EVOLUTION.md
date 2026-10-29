# Phase 2 foundations

The durable authoring ledger, source reader, and patch policy are implemented.
They are trusted controller libraries, not yet exposed as agent capabilities or
CLI evolution commands. `evolution_enabled` remains false. The orchestrating
`ae_evolution` state machine, `seed_evolver`, broker integration, isolated builder,
independent scorecard, and publication/retention recovery remain
required before the Phase 2 exit criterion can be claimed.
The fixed reproducible seed recipe is available separately; see [BUILD.md](BUILD.md).
Operator backup/restore and its local recovery drill are in [RECOVERY.md](RECOVERY.md).

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
