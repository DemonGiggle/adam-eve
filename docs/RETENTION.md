# Retention and storage admission

v0.1 preserves all published source revisions, exact executable releases,
rejected attempt records and audit history. It does not silently remove versions
to recover disk space. This pins the active release, last known-good generation,
observation predecessor and versions referenced by jobs, checkpoints or tasks.

Enabling evolution requires an explicit environment policy:

```sh
export AE_RETENTION_POLICY_JSON='{"promoted_generations":"all","rejected_attempts":"all","audit":"all"}'
```

These are the supported v0.1 policy values. Missing, incomplete or unsupported
policies disable evolution while ordinary conversation remains available. A
valid policy is persisted in the control store and audited when it changes.
Shorter historical retention is not interpreted as permission to delete data.
Consistent backup/restore includes this policy and the complete retained set.

Evolution admission checks available filesystem space before accepting a job or
starting a new authoring, build, evaluation or staging step. The estimate includes
the declared disk reserve, source/artifact ceilings, attempt count, bounded
model-result storage, temporary exports and database/WAL copies. Insufficient
headroom returns `storage_pressure`; an unavailable check returns
`storage_unavailable`. A rejected trigger creates no job and reserves no model
spending. Pressure observed between steps cancels the job through its normal
cleanup path and preserves retained versions.

This is a conservative admission check, not a filesystem quota against other
writers. The isolated builder/evaluator also check space before their own large
allocations. Operators still provision and monitor persistent storage and backup
destinations according to the environment policy.

Normal job completion removes disposable workspaces. For interrupted hidden
publications, inspect the read-only plan, then apply it:

```sh
scripts/cleanup --data-root /absolute/private/identity
scripts/cleanup --data-root /absolute/private/identity --apply
```

The collector requires the persisted preservation policy and terminal evolution
and deployment jobs; pending restore verification also fences cleanup. It holds
the publication/backup lock, refusing an active publisher, and derives pins from
routing, registry, checkpoints, jobs and the last known-good route. Pinned
executables must match their digests and protected source references. Only
recognized `.publishing-*` directories containing regular partial release files
are removable. Every complete artifact path and every generation/attempt source
ref is preserved, including unregistered releases left by interrupted publication.
Unknown files and links are refused before any deletion.

Cleanup commits its exact path list and audit intent before removal, syncs the
artifact directory before completion, and resumes that intent after interruption.
The audit and intent survive consistent backup/restore. It does not collect
interrupted workspaces whose live ownership cannot yet be established, nor delete
historical artifacts, source, checkpoints or audit. A partial publication is never
treated as a promotable release. See [BUILD.md](BUILD.md) for publication tests
and [RECOVERY.md](RECOVERY.md) for consistent backups.

`test/integration/storage.py` verifies policy requirements, durable policy
recording, rejection before spending under storage pressure, and continued user
service. The orchestrated authoring integration exercises admission checks across
repair, build, independent evaluation, promotion and rollback.
`test/build/test_cleanup.py` covers publisher/recovery fences, retained pins,
unexpected links and a SIGKILL after removal but before completion. The recovery
integration verifies cleanup alongside active user service and through backup.
