# Versioned semantic memory

Facts, preferences and summaries live in the trusted SQLite store, independently
of agent source, runtime processes and slot names. Each update creates an
immutable revision and a `memory_updated` event in one durable transaction. It
retains the operator's origin, kind/key, text value and references to existing
events. Values are data; no memory record is loaded as code or grants a tool
capability. The current seed reads these records through its existing
`memory_read` capability. Writes are available through the operator CLI.

Inspect history to find the committed source events, then inspect the current
memory revision:

```jsonl
{"op":"history"}
{"op":"memory"}
```

For example, with memory revision zero and event 12 documenting the preference:

```jsonl
{"op":"memory_put","origin_ref":"favorite-color-1","kind":"preference","key":"favorite-color","value":"saffron","source_event_seqs":[12],"expected_revision":0}
{"op":"memory_get","kind":"preference","key":"favorite-color","revision":null}
{"op":"memory_get","kind":"preference","key":"favorite-color","revision":1}
{"op":"memory","revision":1,"offset":0,"count":32}
```

Use actual event sequences and the current global memory revision from the
identity. Supported kinds are `fact`, `preference`, and `summary`. An exact
origin retransmission returns its committed result without creating another
revision, even after restart. Changed reuse returns `memory_origin_conflict`.
`expected_revision` is a compare-and-swap check against the global memory head;
a conflicting write returns `memory_revision_conflict` without appending events.
Source references must be nonempty, distinct, existing event sequences. The
controller validates reference existence, not the truth of a memory statement.

Deletion is another version and preserves earlier values and source references:

```jsonl
{"op":"memory_delete","origin_ref":"favorite-color-remove","kind":"preference","key":"favorite-color","source_event_seqs":[12],"expected_revision":1}
```

The latest snapshot excludes tombstones; historical reads retain them. Text
values are limited to 4096 UTF-8 bytes, keys to 128, origins to 256, and each
record has at most 16 source references. Snapshot pages have at most 32 entries
and an encoded-entry budget of 32 KiB. Follow `next_offset` until `eof`; an
explicit revision keeps pagination stable across concurrent updates.

## Context, handoff and recovery

Admission pins a turn's memory revision in the same transaction as its user
event. Context reconstruction prepends a bounded JSON memory snapshot to recent
conversation messages. A concurrent update cannot change that turn's model
input between `memory_read` and the broker's context check. New turns use the
newer revision. This is deterministic retrieval of recent active versions;
vector search and more advanced retrieval remain later work.

Checkpoints include `memory_revision` and a `context_summary_ref` when an active
summary exists. Memory updates during candidate observation remain committed
after rollback, alongside acknowledged replies and completed effects. Deletion
does not erase earlier revisions needed by pending turns or checkpoints.

Consistent backups include all memory versions, idempotency records and turn
pins. Verification checks their source events, update events, checkpoint
references and event boundaries. Restored identities expose memory for
inspection while keeping new writes fenced until `restore_ready` succeeds.
Older stores/backups without memory tables remain supported: their existing
turns use revision zero, and startup adds the empty memory schema.

`test/integration/memory.py` verifies recall after the original message leaves
the recent-history window, controller restart, Adam → Eve handoff, candidate
failure and rollback, exact acknowledged replay, online backup and fenced
restore. It also rejects a transport-valid backup with broken memory source
references. EUnit covers version conflicts, immutable history, idempotency,
pinned contexts and bounded pagination with escaped values.
