# Backup and restore

`scripts/backup` creates a recoverable set of retained Git source, exact executable
artifacts/manifests, and authoritative SQLite state. `scripts/restore` verifies
that set and publishes a new data root with production admission closed. These
are privileged operator commands; the seed has no backup, restore, filesystem,
or reconciliation capability.

This implements a local restore drill for the current schema. The controller,
matching OTP/ERTS, Git, Python and the configured model/provider must be provisioned
separately in the recovery environment. Backups contain conversations, tool
results and operational audit data and belong in operator-owned private storage.
Content digests detect corruption; trust in the producer and backup location is
provided by the operator, rather than a signature or remote storage protocol.

## Environment policy

Supply every field in a JSON policy file. For example, a **disposable local test**
could use:

```json
{
  "schedule": "manual before each local experiment",
  "minimum_copies": 2,
  "rpo_ms": 60000,
  "rto_ms": 60000,
  "failure_domain": "same local test disk; no disk-loss coverage",
  "disk_reserve_bytes": 1048576
}
```

Production values are environment decisions. Configure an external scheduler,
monitor backup failures and verify the declared number of retained copies. The
commands record this policy with each set and retain every successful backup;
they do not install a schedule or delete old copies. Retention garbage collection
remains unimplemented. `minimum_copies` declares the environment's required
minimum; a newly created first backup does not claim that minimum is satisfied.
Copying to another directory on the same disk does not cover disk/host loss.
Provision independent storage appropriate to the declared failure domain and
repeat the drill there before claiming its recovery objectives.

```sh
scripts/backup --data-root "$AE_DATA_ROOT" \
  --backup-root /private/independent-backups/adam-eve \
  --policy /private/config/adam-eve-backup.json
```

The data root must already exist and contain a provisioned controller database.
The backup root is created with mode 0700 when absent; existing roots must be
private and owned by the operator. Paths cannot overlap or point through links.
The command returns the complete backup path and SHA-256 identity. Keep that
identity with the recovery record. Incomplete `.backup-*` staging directories
left by process or host loss are not restorable backup sets.

The publisher lock prevents source/artifact publication while their immutable
contents are copied. A supported SQLite online backup then captures a single
read transaction, including committed WAL records. The snapshot records routing,
the event high-water mark and its known epoch floor. Ordinary turns can keep
running, and an already-published candidate can be promoted while the copy runs;
all retained artifacts are copied before the state snapshot. No live database
file is copied directly. Git objects/protected generation refs, executable
hashes, registry references, checkpoints and SQLite integrity/foreign keys are
verified before fsync and atomic publication of the complete backup directory.

The current format includes all retained artifacts, source history, checkpoints,
deployment/evolution ledgers, turn IDs, tool results, attempts and unresolved
reservations. Disposable workspaces, runtime sockets/processes, bootstrap input,
provider configuration and unrelated files are omitted. Git alternates, shallow
or partial repositories and linked files are rejected. Source maintenance that
changes retained files must use the same publication lock; running independent
Git pruning/rewrites against the managed repository is unsupported.

Disk reserve is checked before copying files and the database. A failed backup
does not alter the live identity or publish a complete set. Filesystem exhaustion
from other processes is still an operational failure to monitor. The SQLite
snapshot has a 60-second deadline; larger environments need a separately reviewed
backup configuration rather than an indefinite read transaction.

## Restore and reconcile

1. Fence or stop the original controller and both runtimes. This application does
   not implement distributed failover or concurrent controllers for one identity.
2. Determine an epoch floor at least as high as **every epoch previously issued**,
   including epochs newer than the selected backup. Keep that information outside
   the failed store. The command rejects floors below the backup's known floor;
   it cannot discover epochs lost with the original host.
3. Record the service failure time in Unix milliseconds and select a backup that
   meets the environment's recovery point objective. RPO is measured conservatively
   from snapshot start to failure time. A backup older than the configured RPO is
   rejected; restoration time is not substituted for failure time.
4. Restore into an **absent** target under an existing private parent:

   ```sh
   scripts/restore --backup /private/independent-backups/adam-eve/BACKUP_SHA256 \
     --data-root /private/recovered/adam-eve \
     --epoch-floor HIGHEST_PREVIOUSLY_ISSUED_EPOCH \
     --failure-time-ms FAILURE_TIME_UNIX_MS
   ```

   Restore verifies the manifest/inventory, every file, executable/source identity,
   SQLite state and declared recovery point before atomic publication. It never
   overwrites an existing target. It adds a durable `restore_prepared` record and
   closes admission without deleting or rewriting acknowledged history. It copies
   exact releases and never builds or executes source during verification.
5. Start the controller using the recovered data root and the normal provider and
   provider and host-execution configuration. `status` exposes `recovery.pending: true`, the backup
   identity, closed admission and the declared recovery point. The runtime restores
   a checkpoint through that point and reports ready as a standby. Its new epoch
   exceeds the supplied floor. Startup during an interrupted observation rolls
   back code to the predecessor while retaining the candidate's committed work.
6. Inspect history and pending work; reconcile outstanding external effects with
   their original request IDs. Verify that the original identity remains fenced
   and that the recovered runtime is healthy. Acknowledge through the operator CLI:

   ```jsonl
   {"op":"restore_ready","backup_id":"BACKUP_SHA256","origin_ref":"incident-123: original fenced; effects reconciled"}
   ```

   This checks the current routing, checkpoint high-water mark, fresh epoch and
   runtime health before opening admission and granting its production lease.
   Acknowledgement is durable and idempotent for that backup. A crash before
   acknowledgement keeps admission closed. Unresolved tool reservations remain
   `tool_outcome_unknown`; only a subsequent explicit retry/cancel decision changes
   their status. Acknowledging a restore does not automatically repeat them.

The restore command reports copy/verification duration and the declared RTO
budget. Full service RTO includes provisioning, controller startup, reconciliation,
acknowledgement and a successful turn; the command does not claim those steps are
complete merely because files were copied. Run and measure the complete drill
against each environment's policy. Data committed after the declared recovery
point is outside this backup, even if a client had received an acknowledgement.

## Automated drill

`python3 test/integration/recovery.py` (also in `scripts/test`) uses real BEAM
processes and a fixture HTTP provider. It snapshots a live WAL with an acknowledged
reply and an unresolved call, kills the original controller, restores to a clean
root and verifies source/artifact integrity and retained request IDs. Closed
admission survives another restart and makes no production calls. After explicit
acknowledgement, completed replies replay without another provider call and
unknown outcomes stay unresolved. The drill rejects corruption, links, an
insufficient epoch floor, an existing target and a missed RPO, then measures service
recovery against the explicit local test policy. A second snapshot during
observation restores predecessor code, preserves a candidate-committed reply,
and advances to a fresh epoch before admitting work. These local fixture checks
do not establish off-host recovery or live-provider reconciliation guarantees.
Missing policy, exhausted disk reserve, and a missing protected source reference
in a set with recomputed transport hashes are rejected as well.
