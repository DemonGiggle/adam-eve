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

Normal job completion removes disposable workspaces. Recovery-safe collection
of interrupted workspaces and hidden partial publications remains separate work;
no historical artifact/source/checkpoint deletion command is provided. A partial
publication is never treated as a promotable release. See [BUILD.md](BUILD.md)
for interruption tests and [RECOVERY.md](RECOVERY.md) for consistent backups.

`test/integration/storage.py` verifies policy requirements, durable policy
recording, rejection before spending under storage pressure, and continued user
service. The orchestrated authoring integration exercises admission checks across
repair, build, independent evaluation, promotion and rollback.
