# Implementation status against SPEC v0.1

This report tracks the current implementation against SPEC v0.1 revision 3.
It describes implemented behavior
and existing test evidence; it does not change the requirements in [SPEC.md](SPEC.md).
The v0.1 acceptance criteria are demonstrated on the Linux host with the explicit
Bubblewrap `process` profile. Evolution is disabled by default and can be
explicitly enabled only with complete limits, retention policy and restricted
execution. See the [2026-10-30 acceptance record](evidence/2026-10-30-host-v0.1.json).

The operator has deferred complete aggregate kernel CPU/memory/process
enforcement to v0.2. Namespace/filesystem/network isolation, broker fencing,
attempt/token/spending budgets, and timeouts remain v0.1 requirements. A host
profile using per-process limits is implemented so v0.1 verification no
longer requires a VM or delegated cgroups. Existing cgroup checks remain useful
v0.2 evidence rather than an MVP completion gate.

## Milestones

| SPEC milestone | Progress | Remaining exit evidence |
|---|---|---|
| Phase 0: reliable seed | CLI, brokered LLM calls, durable conversations, retained source/releases and process restart pass fixture tests and the real-model run. | Controlled local acceptance. |
| Phase 1: dual-slot handoff | Implemented and integration-tested with manually authored generations: Adam → Eve → Adam, explicit approval, fencing, checkpoint/replay, observation, crash recovery, and rollback of acknowledged work. The full suite also passes directly on the host with both slots using Bubblewrap/process limits. | Complete aggregate resource enforcement belongs to v0.2. |
| Phase 2: controlled self-evolution | Two real LLM-authored generations pass independent gates, explicit approval, observation and full restart. Retention, publication/cleanup interruption, nine controller crash boundaries and local backup/restore are tested. | Synthetic objectives and explicit test-operator approval; no general model-quality or host-loss recovery claim. |
| Phase 3: autonomous low-risk evolution | Not implemented. | Scheduled triggers and policy-authorized promotion are later work. |
| Phase 4: advanced capabilities | Not implemented. | Explicitly outside MVP scope. |

## Phase 2 evidence

The configured `qwen3.8:27b` Ollama model authored both accepted changes. The first
formats initial `hello:` as `Hello, `; the second adds `bye:` → `Goodbye, ` while
preserving the first behavior as a required regression. Each used one attempt
and three model calls. Both objective comparisons improved from 0/2 baseline to
2/2 candidate; every independent gate passed. The small samples establish these
deterministic behaviors, not general model coding quality.

Promotion completed Adam → Eve at epoch 2, then Eve → Adam at epoch 4. The exact
final executable restarted at epoch 5 and replayed both acknowledged real-provider
replies without rebuilding or another provider call. Source ancestry, protected
refs, executable digests, proposals, scorecards and approvals are retained at
`/home/gigo/.local/share/adam-eve/acceptance-20261030` on the acceptance host.
The portable [acceptance record](evidence/2026-10-30-host-v0.1.json) binds their
identities. A subsequent consistent-backup/fenced-restore drill on this generated
identity replayed the same replies: observed RPO 67 ms and service RTO 737 ms
against the declared 60000 ms local-disk objectives. Two verified backup sets
are retained. This declares no disk/host-loss coverage.

The authoring integration runs a real seed process over authenticated Unix IPC
with a fixture HTTP provider. It verifies paginated source access, structured
patches, deduplication, durable LLM reservations, bounded repair, protected-path
denial, and continued conversation service. This demonstrates the authoring
mechanism, not live-model code-generation quality.

The supervised builder has completed an author → build → `testing` transition
with both the author runtime and compiler restricted by Bubblewrap and cgroups.
Separate VM checks cover kernel memory/process/CPU limits, namespace restrictions,
sealed releases, runtime launcher failure, fresh epochs, retained completed and
unknown effects, and checkpoint restart. The native host lacks delegated cgroups,
so initial aggregate-limit checks ran as an unprivileged user in a disposable
Linux VM. The explicit v0.1 process profile now also passes host builds,
independent comparisons, namespace teardown, runtime recovery and orchestrated
generated promotion/crash/rollback. Additional VM checks cover independent baseline/candidate comparisons,
passing and failing EUnit/Common Test suites, predecessor restore, and the
supervised author/build/evaluation path. A further generated-candidate test
explicitly stages, approves, promotes, acknowledges work, kills the candidate,
and rolls back while preserving its reply/tool result. The orchestrated variant
also repairs an actual compiler failure within the same job, serves conversation
during evaluation and pending approval, disables evolution while keeping service
available, restarts, explicitly re-enables, and deduplicates the original trigger
across epoch changes. A separate host test now kills the whole controller during
a reserved model call, generated pending approval, and observation after an
acknowledged candidate reply. Restart retains reservations and code, refuses old
approvals, never reissues unknown authoring, and rolls back an unobserved candidate
without losing its reply. A test-only store driver also verifies whole-controller
death after approval, quiescing, promotion preparation, routing commit before
activation, rollback intent, and rollback commit before activation, following the
real generated build/evaluation/staging gates. The separate live run establishes
successive actual model-authored generations; fixture tests establish failure
recovery and invariant coverage.

Generated releases can now receive a durable independent scorecard through a
supervised evaluator. Digest-only manual staging still rejects them with
`independent_evaluation_required`. The job-bound staging API verifies the stored
scorecard and requires explicit approval after standby checks; a scorecard alone
does not authorize promotion. The supervised `ae_evolution` state machine and
operator CLI now drive this path. Configuration and controls are documented in
[EVOLUTION.md](EVOLUTION.md); evaluation scope is in [EVALUATION.md](EVALUATION.md).

## Acceptance criteria crosswalk

Numbers refer to [SPEC §14](SPEC.md#14-v01-acceptance-criteria). “Manual” means
the existing trusted, manually authored deployment path; it does not count as
the Phase 2 self-evolution demonstration.

| Criterion | Current evidence / remaining work |
|---|---|
| 1. Continuing identity | Manual and live generated generations retain identity, routing, conversations and exact code across full restart. |
| 2. Active-epoch effects only | Transactional runtime/epoch checks and stale-request rejection are tested. |
| 3. Conversation and pending tasks survive | Restart/handoff tests retain turns and tool-call reservations/results. Versioned facts, preferences and summaries with source events survive context eviction, restart, handoff, rollback and backup restore; turn admission pins the memory revision. Richer task workflows remain later work. |
| 4. Isolated candidate builds/tests | Native Bubblewrap builds/evaluations and the live lifecycle run without production store/tool access or credentials mounted in candidates. |
| 5. Failed gates and rollback | Manual failures and generated score/approval mismatches preserve the active generation. Actual restricted generated-candidate observation failure rolls back acknowledged work. |
| 6. Durable promotions/rollbacks | Routing, audit and linked jobs commit transactionally; nine whole-controller crash boundaries recover, including routing and rollback commits before activation. |
| 7. AI-authored patch through promotion | Both real Ollama-authored patches compiled, passed independent gates and explicit approval, promoted and completed observation. |
| 8. Artifact provenance and evaluation | Parent/source/objective/job/attempt/build provenance and bound scorecards are linked through generated deployment. |
| 9. Controller survives agent failure | Bounded runtime recovery and degraded controller inspection are tested. |
| 10. Disable evolution, keep serving | The restricted orchestrated test verifies enabled → disabled → restart → explicit re-enable, with ordinary service while disabled. Store tests verify disabled/cancelled approvals fail closed and an observing candidate closes admission until rollback. |
| 11. Successive LLM-authored behavior | The second live job inherits the first promoted source, adds its objective and passes the first behavior as a required regression. |
| 12. Retained, verified code/releases | Exact executable retention, protected Git refs, integrity checks, restart, six candidate-publication SIGKILL boundaries, explicit preservation policy and storage admission before spending are tested. Partial-publication collection preserves every complete release/ref and resumes after SIGKILL. Uncertain workspaces are preserved. |
| 13. Bound approvals and durable budgets | Binding mismatches and stale approvals are refused; deduplication, unknown calls, reservations and bounded compiler repair survive restart. Nine whole-controller crash boundaries retain reservations. |
| 14. Preserve acknowledged work; recover backups | Candidate/controller crash and rollback preserve committed replies/results. Fixture and actual generated identities pass consistent-backup/fenced-restore drills within their declared local objectives. |

## LLM provider

Ollama is the implemented provider adapter for conversation and structured source
authoring. The operator configures the installed model through `AE_LLM_MODEL`;
the broker owns the endpoint and enforces time/output limits, with durable token
and cost reservations for authoring. There are no OpenAI or Anthropic adapters.
Automated checks use a fixture provider rather than an installed live model.
An opt-in real-model acceptance harness is documented in
[LIVE_EVOLUTION.md](LIVE_EVOLUTION.md). The recorded host run passed both
successive generations with `qwen3.8:27b`. The model supplied every replacement;
the seed assembled diffs from complete pinned source reads. No handwritten
replacement was injected into either accepted job. Earlier failed runs remain
separate evidence and their reservations were not refunded.

## Operational scope

The native suite passes core/seed EUnit, isolated build/evaluation, real-process
integration, namespace/seccomp and recovery checks. Four delegated-cgroup tests
skip on this host and target the deferred v0.2 aggregate enforcement profile.
Selecting that profile still fails closed without delegation.

v0.1 preserves all complete versions, rejected attempts and audit history.
Collection removes only recognized recovered partial publications; interrupted
workspaces with uncertain ownership are preserved and disk pressure rejects
evolution. Historical deletion, automatic backup expiry, scheduled evolution,
advanced retrieval/task workflows and distributed failover remain later work.
Production operators supply their own limits, objectives, backup schedule/storage
and restore evidence for the required failure domain.

Implementation details and test entry points are in [EVOLUTION.md](EVOLUTION.md),
[BUILD.md](BUILD.md), [ISOLATION.md](ISOLATION.md), [MEMORY.md](MEMORY.md), and [RECOVERY.md](RECOVERY.md).
