# Implementation status against SPEC v0.1

This report tracks the current implementation against SPEC v0.1 revision 2.
It describes implemented behavior
and existing test evidence; it does not change the requirements in [SPEC.md](SPEC.md).
The MVP is not complete. Evolution is disabled by default and can be explicitly
enabled only with complete limits and the restricted runtime backend.

## Milestones

| SPEC milestone | Progress | Remaining exit evidence |
|---|---|---|
| Phase 0: reliable seed | Implemented and integration-tested with a fixture provider: CLI, brokered LLM calls, durable conversations, retained source/releases, process restart. | A live model is not required by the automated suite; no live-model quality claim is established. |
| Phase 1: dual-slot handoff | Implemented and integration-tested with manually authored generations: Adam → Eve → Adam, explicit approval, fencing, checkpoint/replay, observation, crash recovery, and rollback of acknowledged work. | The full handoff suite has not yet been repeated with both slots using the restricted runtime backend. |
| Phase 2: controlled self-evolution | Partial. The evolution state machine and CLI connect authoring/repair, isolated builds/evaluation, job-bound manual approval, promotion/rollback, persistent disable, and local backup/restore. | Publication/retention recovery coverage, the restricted restart/failure matrix, and two successive live-LLM-authored promotions. |
| Phase 3: autonomous low-risk evolution | Not implemented. | Scheduled triggers and policy-authorized promotion are later work. |
| Phase 4: advanced capabilities | Not implemented. | Explicitly outside MVP scope. |

## Phase 2 evidence and gaps

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
so those positive checks were run as an unprivileged user in a disposable Linux
VM. Additional VM checks now cover independent baseline/candidate comparisons,
passing and failing EUnit/Common Test suites, predecessor restore, and the
supervised author/build/evaluation path. A further generated-candidate test
explicitly stages, approves, promotes, acknowledges work, kills the candidate,
and rolls back while preserving its reply/tool result. The orchestrated variant
also repairs an actual compiler failure within the same job, serves conversation
during evaluation and pending approval, disables evolution while keeping service
available, restarts, explicitly re-enables, and deduplicates the original trigger
across epoch changes. The full restricted failure matrix and successive authored
generations remain pending.

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
| 1. Continuing identity | Verified across manual generations and controller/runtime restart. Generated-generation acceptance remains pending. |
| 2. Active-epoch effects only | Transactional runtime/epoch checks and stale-request rejection are tested. |
| 3. Conversation and pending tasks survive | Restart/handoff tests retain turns and tool-call reservations/results. Richer task workflows are not implemented. |
| 4. Isolated candidate builds/tests | Restricted builds and independent comparisons run without production store/tool access. Full lifecycle acceptance remains pending. |
| 5. Failed gates and rollback | Manual failures and generated score/approval mismatches preserve the active generation. Actual restricted generated-candidate observation failure rolls back acknowledged work. |
| 6. Durable promotions/rollbacks | Manual and generated deployments update routing, audit and linked evolution records transactionally. Full orchestration/restart coverage remains pending. |
| 7. AI-authored patch through promotion | Not met for a live LLM. A fixture-authored behavioral patch is compiled, independently tested, explicitly approved, promoted, and rolled back. |
| 8. Artifact provenance and evaluation | Parent/source/objective/job/attempt/build provenance and bound scorecards are linked through generated deployment. |
| 9. Controller survives agent failure | Bounded runtime recovery and degraded controller inspection are tested. |
| 10. Disable evolution, keep serving | The restricted orchestrated test verifies enabled → disabled → restart → explicit re-enable, with ordinary service while disabled. Store tests verify disabled/cancelled approvals fail closed and an observing candidate closes admission until rollback. |
| 11. Successive LLM-authored behavior | Not met. Manual cumulative lineage is tested; two live-LLM-authored behavioral changes and independent regression evidence remain pending. |
| 12. Retained, verified code/releases | Exact executable retention, protected Git refs, integrity checks, and restart are tested. Coordinated retention/cleanup and interrupted-publication coverage remain unfinished. |
| 13. Bound approvals and durable budgets | Manual/generated bindings, reservations across restart, compiler repair without budget reset, durable promotion/rollback intents, and disable/cancellation guards are tested. Full orchestrator failure/restart coverage remains pending. |
| 14. Preserve acknowledged work; recover backups | Manual/generated rollback preserves committed replies/results. Local consistent-backup/fenced-restore drills pass; environment-specific off-host recovery validation remains pending. |

## LLM provider

Ollama is the implemented provider adapter for conversation and structured source
authoring. The operator configures the installed model through `AE_LLM_MODEL`;
the broker owns the endpoint and enforces time/output limits, with durable token
and cost reservations for authoring. There are no OpenAI or Anthropic adapters.
Automated checks use a fixture provider rather than an installed live model.

Implementation details and test entry points are in [EVOLUTION.md](EVOLUTION.md),
[BUILD.md](BUILD.md), [ISOLATION.md](ISOLATION.md), and [RECOVERY.md](RECOVERY.md).
