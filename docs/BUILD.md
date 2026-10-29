# Fixed seed build recipe

Seed publication uses the controller-owned `build_seed.escript` recipe instead
of executing a source-controlled rebar build. The development `scripts/build`
command still uses rebar to compile the controller and prepare its dependencies.
`publish_seed` and `publish_candidate` build their explicitly trusted manual
source with the fixed recipe and retain the resulting executable as before.

The recipe:

- Checks the supported seed manifest and exact locked JSX dependency. It refuses
  extra build hooks, plugins, compiler configuration, or dependency declarations.
- Compiles seed, shared protocol, and verified JSX source with deterministic
  compiler output, debug information, and warnings as errors. Includes resolve
  from stable relative source paths. Symlink source entries and duplicate module
  names are rejected.
- Builds application descriptors from the actual compiled modules, includes the
  dependency license, and sorts archive members with fixed timestamps/modes.
- Embeds source revision/tree, parent artifact, recipe and dependency hashes,
  and OTP/ERTS/compiler/architecture information in the executable. This avoids
  associating one executable identity with conflicting source provenance.

The package cache must contain the exact `jsx-3.1.0.tar` fetched by `scripts/build`.
The raw package SHA-256 is checked before extraction, matching the protected seed
lock. Extraction is bounded and excludes links and unsafe paths. Set
`AE_JSX_PACKAGE` if the verified package is stored outside rebar's default cache.
The recipe does not fetch dependencies or consult user build configuration.

The manual build helper requires an explicit `trusted_manual=True` call. It
clears the compiler's inherited environment; it has no generated-code fallback.
The manual publisher remains inappropriate for untrusted or AI-authored patches:
compiler code still executes on the operator host in this development path.

## Isolated candidate builder

`ae_build_sup:start_job(JobId, Config, NotifyPid)` starts a temporary supervised
`ae_builder` for an accepted proposal. It reserves a durable execution lease
before starting the fixed Python launcher. CPU reservations accumulate across
builds, evaluations, staging and repairs without refunds after failure or restart. An
unresolved reservation cannot silently launch a duplicate execution. Each lease
also has an absolute expiry within the job deadline. The builder can advance a
job from `building` to `testing`; it cannot approve or deploy it.

`ae_candidate.py` uses a private Git index against the protected active source
ref. It checks the baseline, patch hash, changed-path set, regular file modes,
source size/count, and cumulative source parent. Git hooks, filters, external
object stores, replacements, and arbitrary configuration are excluded. It
retains a deterministic commit under `refs/attempts/<job>/<attempt>` and exports
raw blobs, so checkout/archive attributes cannot alter compiler input bytes.
Only public build inputs are exported; controller code, Git metadata, private
contract tests and credentials are not mounted in the compiler. Unexpected
private files and symlinks cause rejection rather than being copied into it.

Compilation uses the verified cgroup/namespace/seccomp backend with source and
the verified dependency mounted read-only. The exact controller recipe is
hashed and sealed before mounting. The compiler emits bounded base64 release
bytes through stdout; it receives no writable host output mount. The controller
treats those contents as opaque untrusted bytes, checks their size/hash and
durably publishes the complete release and protected generation ref. It never
decodes a generated BEAM/archive or loads candidate modules into its own VM.

The manifest records the source tree/parent, objective, job/attempt, patch hash,
toolchain compatibility and pinned recipe/dependency hashes. Its `authoring` is
`llm` and `evaluation` is null. Publication alone does not make it deployable:
ordinary deployment rejects generated artifacts with
`independent_evaluation_required`. The supervised independent evaluator is
documented in [EVALUATION.md](EVALUATION.md). Job-bound generated staging and
manual approval are implemented; the orchestration state machine and CLI trigger
are still required before enabling self-evolution.
Missing isolation never falls back to the manual host compiler.

Configure the internal builder through `AE_BUILD_CONFIG_JSON`. Every field is
required; invalid or missing configuration disables the builder. For example,
the following are **local test budgets**, not production defaults:

```json
{
  "cgroup_root": "/sys/fs/cgroup/owned-jobs",
  "jsx_package": "/private/cache/jsx-3.1.0.tar",
  "source_bytes": 2097152,
  "source_files": 128,
  "artifact_bytes": 8388608,
  "sandbox_limits": {
    "memory_bytes": 536870912,
    "pids": 32,
    "cpu_percent": 100,
    "cpu_seconds": 5,
    "address_space_bytes": 1073741824,
    "file_bytes": 33554432,
    "open_files": 128,
    "output_bytes": 16777216,
    "wall_ms": 20000
  }
}
```

Effective CPU/memory/process/time bounds cannot exceed the durable job/lease
limits. The cgroup watchdog also enforces fractional-second aggregate CPU
budgets; polling and kernel scheduling impose watchdog granularity. Compiler
failures return bounded public diagnostics, without raw Git/host errors. Scope
violations terminate the job. Failed compilation can request a complete repair
diff within the original remaining budget. The control plane and conversation
service remain usable after a failed build.

Reproducibility tests rebuild the same committed input under different directory
paths and file timestamps and compare the complete executable bytes. They also
check embedded provenance, licensing, distinct source identities, pinned-package
denial, and rejection of source-controlled build hooks. Existing Phase 0/1 tests
exercise these releases through real runtime restart, handoff, and rollback.

These checks establish reproducibility for the tested pinned inputs/toolchain.
They do not establish cross-toolchain equivalence, a self-contained ERTS release,
or the independent Phase 2 quality gates.

Candidate tests cover pinned exports/ancestry, deterministic attempt commits,
zero-context patch checks, symlink/scope denial, mandatory execution leases,
disk reserve and fail-closed isolation. Set `AE_TEST_CGROUP_ROOT` to exercise
the successful restricted compilation and retained output. The authoring
integration includes a supervised-build failure; with a delegated test root it
also includes a successful author → build → testing transition and verifies
that the unevaluated output cannot be deployed.

The native development host lacks cgroup delegation. Separate checks in an
unprivileged user session inside a disposable QEMU/Linux 6.12 VM verified all
eight kernel boundary tests, a successful restricted build, and the supervised
authoring-to-build transition with both runtime and compiler restricted. Software
emulation used explicit test allowances of 180000
ms build wall time and 90000 ms CPU. These are selected by
`AE_TEST_BUILD_WALL_MS`/`AE_TEST_BUILD_CPU_MS`, not substituted for production
budgets. A separate restricted-runtime test killed the launcher, verified fresh
epochs and retained completed/unknown effects, then restarted from a checkpoint.
Full restricted Adam/Eve handoff remains separate acceptance work. Evaluator
checks and their scope are documented separately in [EVALUATION.md](EVALUATION.md).
