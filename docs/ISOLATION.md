# Restricted runtime backend

The controller has an optional Linux x86_64 Bubblewrap backend. The trusted
launcher is `apps/ae_core/priv/ae_sandbox.py`, outside evolvable agent source.
It requires Bubblewrap, libseccomp, Python 3, and prlimit. The explicit `process`
resource profile runs on a namespace-capable host without delegated cgroups.
Complete aggregate CPU/memory/process enforcement is deferred to v0.2. The
optional `cgroup` profile requires a delegated cgroup v2 subtree and fails closed
when unavailable; there is no automatic profile downgrade or unrestricted fallback.

The existing `development` backend is retained only for explicitly trusted,
manually built seeds/artifacts. It refuses artifacts whose `authoring` is not
`trusted_manual`; manifests predating that field are treated as legacy manual
artifacts. This backend is not suitable for generated/untrusted code.

## Isolation and resource controls

The restricted backend:

- Creates private user, mount, PID, IPC, UTS, and network namespaces; drops all
  capabilities and enables `no_new_privs`.
- Mounts the selected public OS/BEAM toolchain read-only, an immutable copy of
  the verified executable, and only that runtime's read-only IPC directory.
  Host home, controller/data directories, other runtime sockets, and cgroup
  controls are absent. Root, `/tmp`, `/proc`, and `/dev` are read-only.
- Installs seccomp rules blocking namespace creation and mounting, cgroup
  remounts, cross-process inspection, keyring access, BPF, io_uring, and other
  privileged kernel operations. Normal BEAM threads remain supported.
- In the `cgroup` profile, places the launcher child in a private cgroup before executing any agent
  code. It writes and reads back memory/swap, CPU rate, PID, and OOM-group
  controls. It requires `cgroup.kill` for complete descendant cleanup.
- Adds per-process address-space, CPU, file-size, descriptor, and per-user task
  limits in both profiles; supervises elapsed time, output size, and controller
  EOF. The process profile kills Bubblewrap to tear down its PID namespace and
  descendants, including processes that changed sessions. The cgroup profile
  additionally supervises aggregate CPU and kills/removes the complete cgroup.
- Removes inherited environment variables and file descriptors. Child output
  is captured and bounded; only a fixed status reaches the controller VM.

The release file is opened without following symlinks, bounded, and SHA-256
checked again. Its verified bytes are sealed in a memfd and mounted read-only;
changing the host artifact after verification cannot change that running copy.
The retained artifact still undergoes the existing publication/start/promotion
integrity gates.

## Configuration

Set these before starting the controller:

```text
AE_RUNTIME_ISOLATION=bubblewrap
AE_RESOURCE_LIMITS_MODE=process
AE_SANDBOX_LIMITS_JSON=<JSON object containing every key below>
```

All values in the limits object must be explicit positive integers:

| Key | Enforcement |
|---|---|
| `memory_bytes` | Requested memory budget; aggregate enforcement and swap disabling require `cgroup` |
| `pids` | Inherited task rlimit; aggregate tasks ceiling requires `cgroup` |
| `cpu_percent` | Requested aggregate CPU quota; enforced only in `cgroup`; 100 is one CPU |
| `cpu_seconds` | Per-process CPU rlimit; aggregate CPU watchdog additionally requires `cgroup` |
| `address_space_bytes` | Per-process virtual address-space rlimit |
| `file_bytes` | Per-file size rlimit and maximum release bytes |
| `open_files` | Per-process descriptor rlimit |
| `output_bytes` | Maximum captured child output |
| `wall_ms` | Runtime lifetime watchdog |

These are environment budgets, with no universal defaults. Account for both
slots and independent build/evaluation workers when sizing the environment.
ERTS needs virtual address space for its allocators and JIT memfd files, so
address-space/file-size limits must allow its boot footprint. The launcher sets
a smaller literal super carrier; see the [ERTS allocator reference](https://www.erlang.org/docs/24/man/erts_alloc.html).
A watchdog expiry is a runtime failure and uses the existing fenced recovery
path. A selected sandbox that cannot start leaves the controller degraded; it
does not silently select the development backend.

For aggregate enforcement, explicitly select `AE_RESOURCE_LIMITS_MODE=cgroup`
and set `AE_CGROUP_ROOT` to an absolute delegated subtree with CPU, memory and
PID controllers enabled. `cgroup` remains the default for older configurations
that omit the mode. For builder/evaluator JSON configurations, select the same
profile with `"resource_limits_mode":"process"` or `"cgroup"`; omitted values
also retain the older strict behavior. Their `cgroup_root` path is unused by the
process profile. Controller status reports its runtime profile, generated build
provenance records the build profile, and the durable evaluation configuration
binds the evaluator profile to its scorecard and approval.

Probe the full backend with the same configured limits before use:

```sh
python3 apps/ae_core/priv/ae_sandbox.py --probe \
  --resource-limits-mode "$AE_RESOURCE_LIMITS_MODE" \
  --cgroup-root "${AE_CGROUP_ROOT:-/sys/fs/cgroup}" --limits-json "$AE_SANDBOX_LIMITS_JSON"
```

The backend does not create administrator delegations or change ancestor cgroup
controllers. A writable ordinary directory, a systemd unit accepting properties,
or successful namespace creation is insufficient evidence of enforced resource
limits. The cgroup-profile probe checks the actual filesystem and kernel
controls; a successful process-profile probe does not establish aggregate limits.

## Verification and current limits

Run namespace/seccomp, sealed-release, IPC/BEAM, and fail-closed component checks:

```sh
python3 -m unittest discover -s test/sandbox -v
```

For full aggregate-resource and teardown tests, provide an explicitly delegated
test subtree:

```sh
AE_TEST_CGROUP_ROOT="$AE_CGROUP_ROOT" python3 -m unittest discover -s test/sandbox -v
```

The current development host permits namespaces but does not delegate CPU,
memory, or PID controllers. The default suite now runs process-profile isolation,
session-escaping descendant teardown, sealed releases and actual restricted
runtime crash/checkpoint recovery on that host. Build, independent evaluation,
orchestrated generated promotion/rollback and the full manual Adam/Eve handoff
suite also pass there. Aggregate cgroup checks remain optional v0.2 evidence;
earlier runs passed inside a disposable VM with real delegation. No VM is needed
for the v0.1 host profile. See [BUILD.md](BUILD.md) and [EVOLUTION.md](EVOLUTION.md).
Backup/restore is described separately in [RECOVERY.md](RECOVERY.md).
