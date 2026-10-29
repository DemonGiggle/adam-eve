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

The future `ae_builder` must export/check the pinned tree, apply the accepted
patch to a disposable workspace, and run this recipe through `ae_sandbox.run`
with source, dependency, and recipe inputs mounted read-only. Only private
bounded output storage may be writable. No controller data, credentials, source
repository, or private evaluator cases may be mounted in that compiler process.
It must enforce the durable job budget, independently evaluate the exact output,
and publish verified complete contents before registering availability.

Reproducibility tests rebuild the same committed input under different directory
paths and file timestamps and compare the complete executable bytes. They also
check embedded provenance, licensing, distinct source identities, pinned-package
denial, and rejection of source-controlled build hooks. Existing Phase 0/1 tests
exercise these releases through real runtime restart, handoff, and rollback.

These checks establish reproducibility for the tested pinned inputs/toolchain.
They do not establish cross-toolchain equivalence, a self-contained ERTS release,
an isolated generated-code builder, or the independent Phase 2 quality gates.
