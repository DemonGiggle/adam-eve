# Restricted runtime backend

The controller has an optional Linux x86_64 Bubblewrap backend. The trusted
launcher is `apps/ae_core/priv/ae_sandbox.py`, outside evolvable agent source.
It requires Bubblewrap, libseccomp, Python 3, prlimit, and a **delegated cgroup v2
subtree with CPU, memory, and PID controllers enabled**. It never falls back to
an unrestricted process or to per-process limits alone.

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
- Places the launcher child in a private cgroup before executing any agent
  code. It writes and reads back memory/swap, CPU rate, PID, and OOM-group
  controls. It requires `cgroup.kill` for complete descendant cleanup.
- Adds hard address-space, CPU, file-size, descriptor, and per-user task limits;
  supervises total cgroup CPU use, elapsed time, output size, and controller EOF.
  Teardown kills the complete cgroup and removes its directory.
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
AE_CGROUP_ROOT=<absolute path to an operator-delegated empty cgroup subtree>
AE_SANDBOX_LIMITS_JSON=<JSON object containing every key below>
```

All values in the limits object must be explicit positive integers:

| Key | Enforcement |
|---|---|
| `memory_bytes` | Aggregate cgroup memory ceiling; swap is disabled |
| `pids` | Cgroup tasks ceiling and inherited task rlimit |
| `cpu_percent` | Aggregate CPU quota; 100 is one CPU |
| `cpu_seconds` | Total CPU watchdog and inherited process CPU rlimit |
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

Probe the full backend with the same configured limits before use:

```sh
python3 apps/ae_core/priv/ae_sandbox.py --probe \
  --cgroup-root "$AE_CGROUP_ROOT" --limits-json "$AE_SANDBOX_LIMITS_JSON"
```

The backend does not create administrator delegations or change ancestor cgroup
controllers. A writable ordinary directory, a systemd unit accepting properties,
or successful namespace creation is insufficient evidence of enforced resource
limits. The probe checks the actual cgroup filesystem and kernel controls.

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
memory, or PID controllers. Five component tests pass here; three aggregate
cgroup tests and a restricted-runtime recovery test require `AE_TEST_CGROUP_ROOT`.
All nine sandbox tests passed as an unprivileged user inside a separate disposable
QEMU/Linux 6.12 VM with real delegation. Restricted
candidate compilation, the supervised build transition and restricted runtime
crash/checkpoint recovery passed there as well; see [BUILD.md](BUILD.md). Full
restricted Adam/Eve handoff remains separate verification work. Automatic evolution stays disabled
until orchestration and independent quality gates are implemented. Backup/restore
is described separately in [RECOVERY.md](RECOVERY.md).
