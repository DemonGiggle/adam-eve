# Runtime protocol v1 — Phase 0

This is the implemented subset of [SPEC.md](SPEC.md), Section 7. Future evolution,
quiescing, and checkpoint-export messages are rejected until implemented.

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
5. Controller compares the persisted routing record and atomically commits a new
   runtime instance and incremented epoch with its activation event.

Phase 0 supports state schema 1 and capabilities `memory_read` and `llm` only.
`generation` is the bare hexadecimal SHA-256 of the retained seed executable.
`checkpoint_id` is `event-log`: the seed has no private durable state and fetches
context from the authoritative store for each turn. Exported snapshots and
dual-slot restore are planned for Phase 1.

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

## Health and shutdown

- Controller sends `health_check {request_id}`; seed replies with
  `health_status {request_id, status}` where a healthy status is `"ok"`.
- Controller may send `shutdown {reason}`. Closing the authenticated socket also
  terminates the seed process.

Bootstrap and health operations have five-second deadlines. A turn has one
deadline of the configured provider timeout plus ten seconds, with a fixed
number of broker exchanges. Controller writes always recheck durable fencing;
old runtime instances cannot commit replies or tool results after replacement.
