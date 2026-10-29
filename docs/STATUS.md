# Implementation status against SPEC v0.1

Implementation baseline: `2102e59`. This report describes implemented behavior
and existing test evidence; it does not change the requirements in [SPEC.md](SPEC.md).
The MVP is not complete, and evolution remains disabled.

## Milestones

| SPEC milestone | Progress | Remaining exit evidence |
|---|---|---|
| Phase 0: reliable seed | Implemented and integration-tested with a fixture provider: CLI, brokered LLM calls, durable conversations, retained source/releases, process restart. | A live model is not required by the automated suite; no live-model quality claim is established. |
| Phase 1: dual-slot handoff | Implemented and integration-tested with manually authored generations: Adam → Eve → Adam, explicit approval, fencing, checkpoint/replay, observation, crash recovery, and rollback of acknowledged work. | The full handoff suite has not yet been repeated with both slots using the restricted runtime backend. |
| Phase 2: controlled self-evolution | Partial. Job-scoped source access, structured authoring, repair budgets, protected patches, reproducible isolated builds, durable provenance, and local backup/restore are implemented. | Independent evaluator/scorecard, evolution state machine and CLI, evaluated-artifact approval integration, publication/retention recovery coverage, and the two successive live-LLM-authored promotions. |
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
VM. They do not establish full restricted handoff or an independent evaluation.

Generated releases currently have no independent evaluation result. The
deployment path rejects them with `independent_evaluation_required`; compiling
a candidate does not make it promotable. The next implementation dependency is
the independent evaluator, followed by lifecycle orchestration and approval
integration.

## Acceptance criteria crosswalk

Numbers refer to [SPEC §14](SPEC.md#14-v01-acceptance-criteria). “Manual” means
the existing trusted, manually authored deployment path; it does not count as
the Phase 2 self-evolution demonstration.

| Criterion | Current evidence / remaining work |
|---|---|
| 1. Continuing identity | Verified across manual generations and controller/runtime restart. Generated-generation acceptance remains pending. |
| 2. Active-epoch effects only | Transactional runtime/epoch checks and stale-request rejection are tested. |
| 3. Conversation and pending tasks survive | Restart/handoff tests retain turns and tool-call reservations/results. Richer task workflows are not implemented. |
| 4. Isolated candidate builds/tests | Restricted builds are verified. The independent candidate test runner remains missing. |
| 5. Failed gates and rollback | Manual staging failures preserve the active generation; observation failures roll back. Generated evaluation gates remain missing. |
| 6. Durable promotions/rollbacks | Manual deployment, routing, audit events, and restart recovery are tested. Evolution-job linkage remains missing. |
| 7. AI-authored patch through promotion | Not met. Fixture-authored patches reach a retained build; independent evaluation and promotion remain pending. |
| 8. Artifact provenance and evaluation | Parent/source/objective/job/attempt/build provenance exists. Independent test results and scorecards remain missing. |
| 9. Controller survives agent failure | Bounded runtime recovery and degraded controller inspection are tested. |
| 10. Disable evolution, keep serving | Evolution is currently always disabled while ordinary service remains available. A completed enabled/disabled lifecycle remains pending. |
| 11. Successive LLM-authored behavior | Not met. Manual cumulative lineage is tested; two live-LLM-authored behavioral changes and independent regression evidence remain pending. |
| 12. Retained, verified code/releases | Exact executable retention, protected Git refs, integrity checks, and restart are tested. Coordinated retention/cleanup and interrupted-publication coverage remain unfinished. |
| 13. Bound approvals and durable budgets | Manual approval bindings and authoring deduplication/reservations survive restart. Generated evaluation/approval binding remains missing. |
| 14. Preserve acknowledged work; recover backups | Manual rollback and local consistent-backup/fenced-restore drills are tested. Full generated-candidate rollback and environment-specific off-host recovery validation remain pending. |

## LLM provider

Ollama is the implemented provider adapter for conversation and structured source
authoring. The operator configures the installed model through `AE_LLM_MODEL`;
the broker owns the endpoint and enforces time/output limits, with durable token
and cost reservations for authoring. There are no OpenAI or Anthropic adapters.
Automated checks use a fixture provider rather than an installed live model.

Implementation details and test entry points are in [EVOLUTION.md](EVOLUTION.md),
[BUILD.md](BUILD.md), [ISOLATION.md](ISOLATION.md), and [RECOVERY.md](RECOVERY.md).
