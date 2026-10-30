# Runtime protocol v1 — turns, handoff and bounded authoring

This is the implemented subset of [SPEC.md](SPEC.md), Section 7. Agent
checkpoint-export and `quiesce` wire messages are rejected until implemented.
Admission, draining, and authoritative checkpoints are controller-owned.

Each frame is a four-byte unsigned big-endian byte length followed by a UTF-8
JSON object. Frames are bounded to 1 MiB. Every object contains
`"protocol_version": 1` and a `"type"`. Unknown versions, types, missing fields,
extra fields, and invalid field types are rejected. IDs are nonempty strings of
at most 256 bytes; message/reply text is nonempty and at most 64 KiB. Epochs are
positive integers; event sequences are nonnegative integers.

The controller creates a private temporary directory (0700) and Unix socket
(0600), then launches the seed in another BEAM OS process. No distributed Erlang
connection is created. The seed receives only its socket path and a random,
single-instance authentication token. Its inherited environment is removed,
except a fixed executable search path and BEAM resource flags. Provider settings
and controller secrets are not passed to the seed. This same-user development
transport requires an OS sandbox before running untrusted generated code.

## Bootstrap

1. Seed sends `authenticate {token}`; the controller verifies the launch token.
2. Controller sends `hello {slot, runtime_instance_id, generation, capabilities}`.
3. Controller sends `restore {checkpoint_id, state_schema_version, last_event_seq}`.
4. Seed sends `ready {generation, restored_seq, supported_schema_versions}`.
5. The runtime remains standby. Only a separate controller transaction can commit
   its runtime instance and a new epoch; the runner then enables production turns
   for that exact committed identity. Starting a process never grants authorization.

The implementation supports state schema 1. Conversation-only releases declare
`memory_read` and `llm`. New seeds additionally declare `source_list`, `source_read`,
`evolution_status`, `evolution_llm` and `evolution_propose`. The authoring
capabilities require a separate controller-authorized job/exchange; they cannot
be invoked during a user turn. Earlier releases do not gain those permissions
merely because the controller was upgraded.
`generation` is the bare hexadecimal SHA-256 of the retained seed executable.
Staging uses `checkpoint_id: synthetic-stage` and sequence zero, followed by a
synthetic turn with controller-supplied mock tool results. No production data or
broker calls are available in this mode. Before promotion the controller sends
`restore` again, discarding simulation state; the seed returns a matching `ready`.

Production checkpoints are immutable schema-1 envelopes saved transactionally in
SQLite with an identity, generation, event high-watermark, and pending turn IDs.
Their content digest is the checkpoint ID. All durable seed state lives in the
controller's conversation/tool/task tables and append-only events, so the seed
fetches the reconstructed authoritative context on each turn. Neither a heap nor
an old conversation copy is used as restore state. Before promotion/rollback the
store checks the checkpoint watermark against the latest committed sequence;
late writes invalidate a stale restore. Rollback creates a fresh checkpoint
including candidate-committed events and pending work. Portable checkpoint
export and more complex agent state schemas remain future work.

## User turns

| Direction | Type | Fields beyond version/type |
|---|---|---|
| Controller → seed | `user_turn` | `request_id, session_id, epoch, message, memory_cursor` |
| Seed → controller | `tool_request` | `request_id, epoch, tool, args, idempotency_key` |
| Controller → seed | `tool_result` | `request_id, idempotency_key, result` |
| Seed → controller | `assistant_reply` | `request_id, text, event_refs` |
| Seed → controller | `turn_failed` | `request_id, reason` |

The seed requests `memory_read` with empty `args`, then `llm` with
`{"messages": [...]}`. The idempotency key equals the tool name, scoped to the
durable turn. Only these two requests, in this order, are accepted. The broker
checks that the claimed request and epoch match the authenticated runtime and
the admitted turn. Model context must equal the controller's bounded,
session-scoped history; the seed cannot fetch another session by inventing IDs.
Old complete turns are omitted when JSON escaping would exceed the frame budget;
the current user message remains in context.

`memory_read` returns `{"messages": [...]}`. `llm` returns `{"text": "..."}` or
`{"error": "reason"}`. `turn_failed` is a Phase 0 extension that leaves the turn
pending and reports a bounded provider/recovery failure to the CLI. Empty
`event_refs` are used by the stateless seed; the controller owns event writes.

The LLM reservation and result are durable. A completed result is reused after
seed failure. If the controller dies after reserving a call but before saving
its result, the provider outcome is unknown: there is no automatic repeat. An
operator may authorize a retry, within the durable attempt limit, or cancel the
pending turn. This protects against silently repeating a potentially billed
call; provider transport does not supply exactly-once execution.

## Authorized authoring

The internal controller authoring operation sends `evolution_context` containing
exactly `job_id, origin_ref, base_generation, base_artifact, base_source_revision,
base_epoch, target_slot, objective, source_manifest_ref, limits`. Its baseline is
the durable active routing record. A repair also receives `evolution_feedback`
with `job_id, attempt_id, outcome, diagnostics_ref, evaluation_summary_ref,
remaining_budget`; public diagnostics are retrieved through `evolution_status`.

Authoring reuses `tool_request`/`tool_result`, with `request_id` equal to the job
ID and `epoch` equal to the pinned active epoch. Every `args` map includes
`job_id, base_artifact, base_source_revision` and the following tool fields:

| Tool | Additional fields |
|---|---|
| `source_list` | `offset, count` (at most 32 entries) |
| `source_read` | `path, offset, bytes` (bounded by reserved source-page credit) |
| `evolution_status` | none |
| `evolution_llm` | `call_id, messages`; idempotency key must equal `call_id` |

Source responses identify the pinned job/source and include `next_offset, eof`.
Read bytes are `data_base64`; a strategy can decode valid UTF-8 before prompting.
`source_page_bytes` bounds the encoded response, including metadata. A
`source_read` request may ask for at most
`floor((source_page_bytes - 512) * 3 / 4)` raw bytes. Use that raw window and
`next_offset/eof` to page files; the authoring response schema advertises the
job-specific ceiling.
The seed's model-facing `edit` action accepts 1–32 exact unique `old_text` and
`new_text` replacements for completely read files, plus the proposal rationale.
It applies the list atomically in order; one action submits the complete proposal,
including any required helper definitions. The seed constructs unified diffs
within one patch budget and sends the normal `evolution_proposal`; this adds
no runtime protocol message, capability or controller privilege. Direct model
patches remain supported. See [EVOLUTION.md](EVOLUTION.md) for edit bounds.
Unknown/protected paths never grant filesystem access. Protected requests reject
the job. LLM messages contain only `role, content`, with at most 32 messages and
256 KiB total JSON. They are authoring input, separate from conversation history.

The seed submits `evolution_proposal` with `job_id, proposal_id, epoch,
base_artifact, base_source_revision, patch, hypothesis, expected_benefit, risks,
requested_tests`. Patches are nonempty, at most 256 KiB and further constrained
by job policy. Rationale fields are at most 4 KiB, list fields have at most 32
bounded strings. The store atomically validates the baseline/path policy and
deduplicates proposal IDs. `evolution_failed {job_id, epoch, reason}` reports a
bounded authoring error. Request count and elapsed time bound each exchange.
An accepted proposal records data; it does not authorize execution or deployment.
See [EVOLUTION.md](EVOLUTION.md) for provider accounting and remaining gates.

## Health and shutdown

- Controller sends `health_check {request_id}`; seed replies with
  `health_status {request_id, status}` where a healthy status is `"ok"`.
- Controller may send `shutdown {reason}`. Closing the authenticated socket also
  terminates the seed process.

Bootstrap operations use `AE_RUNTIME_START_TIMEOUT_MS` (five seconds by default,
100–30000 ms). Connection, authentication and initial restore share one startup
deadline; health probes have five-second deadlines. A turn has one
deadline of the configured provider timeout plus ten seconds, with a fixed
number of broker exchanges. Controller writes always recheck durable fencing;
old runtime instances cannot commit replies or tool results after replacement.
During drain, new turns and new broker calls are denied; results of already
reserved calls and their replies can still commit until the routing switch.
After the switch all writes from the old slot/instance/epoch are rejected.
