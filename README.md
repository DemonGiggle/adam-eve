# adam-eve

An Erlang/OTP agent with a trusted controller and replaceable Adam/Eve runtimes.
The architecture and planned milestones are in [docs/SPEC.md](docs/SPEC.md).

The development implementation now supports Phase 1: a trusted OTP controller
serves isolated Adam/Eve BEAM processes, stages manually built candidates, and
switches between them with durable approval, checkpoints, observation, and
rollback. The seed calls a configured local Ollama model through a broker;
conversation and pending turns survive runtime replacement. Evolution is disabled.

Development requirements: Erlang/OTP 24+, rebar3, a C compiler, make, and SQLite
development headers, Git, and Python 3. Dependencies are pinned in the controller
and seed `rebar.lock` files. Verified with OTP 24 and rebar3 3.22.1 on Linux.

```sh
scripts/build
export AE_DATA_ROOT="$HOME/.local/share/adam-eve"
export AE_LLM_MODEL="your-installed-model"
scripts/publish_seed --data-root "$AE_DATA_ROOT"
scripts/ae
```

Start Ollama with your chosen model installed before submitting a turn. The
adapter uses its [non-streaming chat API](https://docs.ollama.com/api/chat).
The data root must be an absolute, private directory outside this checkout;
the publisher creates it with mode 0700 if it does not exist. Publish once per
identity. Restarts use the persisted active artifact rather than rebuilding or
replacing it from the checkout.

The CLI accepts one JSON object per line and prints one JSON result per command:

```jsonl
{"op":"turn","request_id":"turn-1","session_id":"main","message":"Remember that I like tea."}
{"op":"restart"}
{"op":"turn","request_id":"turn-2","session_id":"main","message":"What do I like?"}
{"op":"status"}
{"op":"history"}
```

EOF stops the controller and seed. Run `scripts/ae` again with the same data root
and model settings to continue. Logs go to stderr; command results go to stdout.
Use a stable request ID to retry a disconnected turn: a completed request returns
its saved reply without another LLM call. Conflicting reuse of an ID is rejected.

Only one pending turn is admitted at a time. A provider failure leaves the turn
pending; resubmitting it returns the recorded outcome. If a controller crash
leaves a reserved call without a recorded result, resubmission returns
`tool_outcome_unknown`. Authorize another potentially billed call with
`{"op":"retry","request_id":"turn-1"}`, then resubmit the original turn. Attempts
are durably bounded across restarts. To stop retrying and admit other turns, use
`{"op":"cancel","request_id":"turn-1"}`. Cancellation preserves audit events and
excludes the unfinished turn from subsequent model context.

For a manual handoff, configure all four limits before starting the controller.
For example, a local development exercise could use:

```sh
export AE_APPROVAL_TTL_MS=60000
export AE_OBSERVE_MS=10000
export AE_HEALTH_INTERVAL_MS=250
export AE_QUIESCE_TIMEOUT_MS=5000
```

There are no implicit defaults for handoffs. Missing or invalid limits disable
staging while ordinary user service remains available. Each value must be a
positive integer of at most 300000 milliseconds; the chosen limits are saved in
the deployment record.

Prepare a **trusted, manually authored** Git patch against the retained active
source, then publish a different artifact:

```sh
scripts/publish_candidate --data-root "$AE_DATA_ROOT" \
  --patch /absolute/path/manual-change.patch --objective 'Describe the change'
```

The publisher reads the current source revision from SQLite, checks out that
retained Git commit, applies the patch in a disposable workspace, and records
the parent in both Git ancestry and the new manifest. Only seed source/tests may
change; manifests, dependency locks, and the shared protocol are protected. Manual
patches are limited to 256 KiB. This command runs a build with the operator's
permissions and is **not** an isolated builder for generated or untrusted code.

The final stdout line is the published artifact manifest; build logs go to
stderr. Publication does not change routing. In the existing `scripts/ae`
session, stage its digest, inspect the returned baseline/artifact/evaluation and
the source diff, then explicitly approve that exact deployment:

```jsonl
{"op":"stage","artifact_digest":"<digest from the published manifest>"}
{"op":"approve","deployment_id":"<returned deployment_id>","approval_binding":"<returned approval_binding>"}
{"op":"deployment","deployment_id":"<deployment_id>"}
```

Inspect the source diff using the two returned source revisions and
`git --git-dir "$AE_DATA_ROOT/source.git" diff <baseline-revision> <candidate-revision>`.
The staging gates check health, protocol/schema support, and a synthetic turn
with mocked context and LLM results. They make no production provider calls or
conversation writes. The active runtime keeps serving while approval is pending.
`{"op":"reject","deployment_id":"..."}` rejects a staged candidate. Expired
approvals, runtime replacement, or changed source/executable/manifest contents
cannot authorize promotion. The current gates are the manual development
handoff checks; the broader independent behavioral/security scorecard in Phase 2
is still pending.

Promotion closes admission and new broker calls, drains the in-flight turn or
leaves it durably retryable at the configured deadline, saves a controller-owned
checkpoint, and restores the candidate. The routing switch, new epoch, promotion
event, and deployment status share one transaction. Committed replies and tool
results are retained through later rollback. Health probes run during observation;
only a candidate that completes observation becomes last known-good. A candidate
crash rolls back to the predecessor under another new epoch. Controller restart
during observation also rolls back; an unpromoted staged candidate is rejected
on recovery. Rollback failure closes admission and leaves the controller
available for inspection. Repeated active-runtime crashes are bounded to three
automatic restarts per 30 seconds; `restart` requests explicit recovery after
fixing the cause. Runtime failures are audited.

| Environment | Default | Meaning |
|---|---|---|
| `AE_DATA_ROOT` | required | Persistent storage, outside the checkout |
| `AE_LLM_MODEL` | required | Installed Ollama model name |
| `AE_LLM_URL` | `http://127.0.0.1:11434/api/chat` | Loopback HTTP endpoint only |
| `AE_LLM_TIMEOUT_MS` | `30000` | Provider timeout, 100–300000 ms |
| `AE_LLM_MAX_TOKENS` | `512` | Requested output limit, 1–8192 |
| `AE_CONTEXT_TURNS` | `8` | Recent turns supplied per session, 1–8 |
| `AE_MAX_LLM_ATTEMPTS` | `3` | Operator-authorized calls per turn, 1–10 |
| `AE_APPROVAL_TTL_MS` | required for handoff | Staging/approval lifetime |
| `AE_OBSERVE_MS` | required for handoff | Post-switch observation window |
| `AE_HEALTH_INTERVAL_MS` | required for handoff | Staged/active probe interval |
| `AE_QUIESCE_TIMEOUT_MS` | required for handoff | In-flight turn drain deadline |

All conversation events remain durable even when only recent history is sent to
the model. The LLM endpoint receives no controller credentials or agent-selected
URL. Response bodies are limited to 1 MiB and reply text to 64 KiB.

The controller uses SQLite WAL with `synchronous=FULL`. Runtime activation
increments a durable epoch. Turn and tool writes check the committed runtime
identity and epoch in the same transaction as their audit event. The controller
commits replies before reporting `"committed": true` to the CLI.

`scripts/publish_seed` freezes the permitted seed/protocol source, commits it to
`source.git` under a protected generation ref, builds a separate seed escript,
and publishes its exact bytes under `artifacts/<sha256>/seed`. Publication syncs
files and directories before creating bootstrap metadata. The store retains the
artifact manifest. Before every runtime launch the controller verifies the
executable digest, source ref/tree and Git object integrity, capabilities, state
schema, and recorded OTP/ERTS versions. The seed never loads into the controller
VM. Disposable workspaces can be removed without losing retained code or state.

The runtime protocol is documented in [docs/PROTOCOL.md](docs/PROTOCOL.md).

Run all checks without an installed model or provider credentials:

```sh
scripts/test
```

EUnit covers protocol bounds, durable turn deduplication, fencing, broker denial,
retry budgets, and transactional handoff/rollback invariants. Integration checks use real controller/seed processes and a
fixture HTTP provider. They kill the seed and controller, verify memory replay
and pending-call recovery, delete disposable workspaces, restart from retained
contents, and verify that corrupt executables or missing source refs fail closed.
Phase 1 checks exercise different manual generations through Adam → Eve → Adam,
approval expiry/denial/binding, staged and active crashes, controller/lifecycle
process loss, in-flight quiescence, rollback of acknowledged work, cumulative
source ancestry, and bounded recovery into a still-functional controller.

This is the development seed milestone. The seed runs as the controller's OS
user; separate processes and authenticated IPC do not sandbox hostile code.
Restricted containers/users, portable checkpoint export, additional production
effects, isolated candidate builds/evaluation, self-evolution,
retention cleanup, and backup/restore drills remain in the later spec phases.
The escript retains compiled code and dependencies; its recorded host ERTS must
remain installed. Reproducible sandbox builds and self-contained runtime releases
remain future work. No live-model quality claim is made by the fixture tests.
