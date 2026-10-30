# Candidate builds

The controller builds LLM-authored patches with Erlang code in
`ae_host_prepare`, `ae_host_build`, `ae_host_publish`, and a fixed `build_seed.escript` compiler
recipe. Compilation runs on the host as the controller user. A generated patch,
compiler hook, or agent test can affect files, processes, and network resources
accessible to that user. See [Host execution](HOST_EXECUTION.md).

The authoring broker and builder check the pinned baseline, patch hash, changed
paths, source tree, and dependency inputs. The builder applies the patch to a
private Git index and retains a deterministic child commit. It exports raw Git
blobs instead of using checkout filters, so the exported source matches the
retained tree. It rejects symlinks, submodules, unapproved paths, and oversized
source before compiling.

The fixed recipe checks the seed configuration and lock, compiles the seed,
protocol, and pinned JSX source, then produces a reproducible escript. It embeds
the source revision/tree, parent artifact, recipe and dependency hashes, and
OTP/ERTS/compiler information. The controller checks the output size, retains
the exact executable and source ref, and verifies the resulting artifact before
recording it. An unevaluated generated artifact is not directly promotable;
see [Evaluation](EVALUATION.md) and [Controlled evolution](EVOLUTION.md).

Publication shares a filesystem lock with backup and manual publication. It
writes and syncs the executable and manifest in a temporary directory before
renaming it into the content-addressed artifact store. Existing artifacts are
verified before reuse. Durable execution reservations prevent an interrupted
build from being automatically reissued or receiving a refunded budget. Tests
kill the Erlang publisher at six publication boundaries and verify baseline
availability, atomic visibility, idempotent recovery, and conflict rejection.

## Configuration

Set `AE_BUILD_CONFIG_JSON` to a JSON object with explicit values. The following
are examples for a local experiment, not universal defaults:

```json
{
  "jsx_package": "/absolute/path/to/jsx-3.1.0.tar",
  "source_bytes": 2097152,
  "source_files": 128,
  "artifact_bytes": 8388608,
  "output_bytes": 16777216,
  "cpu_ms": 10000,
  "wall_ms": 20000
}
```

`scripts/build` fetches the pinned JSX package into the rebar cache, usually
`~/.cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar`. `jsx_package` must be an
absolute path. Erlang verifies the package hash and bounds extraction before the
fixed recipe runs. Old builder configuration objects are accepted for existing
identities, but their sandbox and cgroup fields no longer enforce isolation.

`cpu_ms` is a pessimistic reservation against the job budget, not a measured
CPU limit. The build worker enforces its wall deadline and output bound; it does
not enforce memory, process, or aggregate CPU limits on generated host code.
The controller retains bounded compiler diagnostics for repair attempts.

The operator commands `scripts/publish_seed` and `scripts/publish_candidate`
use the same fixed recipe for manual publication. They currently use Python as
standalone operator tools; the Erlang controller does not invoke them. The
integration suite covers host builds, pinned inputs, source scope, evaluation,
approval, crash recovery, and rollback with fixture model responses.
