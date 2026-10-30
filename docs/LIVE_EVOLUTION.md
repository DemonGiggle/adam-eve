# Live-model acceptance demonstration

`test/integration/live_evolution.py` is an opt-in Phase 2 demonstration using
an installed Ollama model. It creates a new identity and retains its state,
source, executable releases, scorecards and explicit test-operator approvals.
It does not use the fixture provider and is excluded from `scripts/test`.
Model errors fail the demonstration; they are not replaced with canned patches.

The host must satisfy the namespace/seccomp requirements in
[ISOLATION.md](ISOLATION.md). Complete aggregate resource enforcement is deferred
to v0.2; the v0.1 process profile needs neither delegated cgroups nor a VM.
Build the controller with `scripts/build` and
install the chosen model in a local Ollama instance. Set:

```sh
export AE_RUNTIME_ISOLATION=bubblewrap
export AE_RESOURCE_LIMITS_MODE=process
export AE_RUNTIME_START_TIMEOUT_MS=30000
export AE_LIVE_LLM_MODEL=your-installed-model
export AE_LIVE_LLM_URL=http://127.0.0.1:11434/api/chat
export AE_LIVE_MODEL_DIGEST=the-64-hex-model-digest-from-the-local-api-tags-response
```

Also provide `AE_SANDBOX_LIMITS_JSON` with the complete runtime limits described
in the isolation guide. Build, evaluation and evolution budgets are explicitly
declared in the demonstration script as local test policy. Adjust them for the
test environment before running; they are not production defaults. The runtime
wall allowance must cover authoring and the demonstration, and its CPU allowance
must leave enough job budget for staging/observation. `AE_JSX_PACKAGE` can select
the local pinned JSX package instead of the standard rebar cache path.

Choose a new data root outside the checkout:

```sh
python3 test/integration/live_evolution.py --data-root /absolute/new/private/identity
```

Adam asks the model to change replies beginning with `hello:` into `Hello, `,
while preserving other replies and existing broker/protocol behavior. After
independent evaluation, the test operator explicitly submits the returned
approval binding and waits for observation completion. Eve then authors a second
change from that promoted source: `bye:` becomes `Goodbye, `, preserving the first
behavior. Its private evaluation includes the earlier behavior as a required
regression case, plus context reconstruction and provider failure handling.
Cases contain fresh nonces and are not mounted in generated sandboxes.

The harness verifies two promotions, Adam → Eve → Adam, retained source refs
and executable digests, then restarts the entire controller and runtimes without
rebuilding. Both acknowledged user turns must replay exactly. Inspect
`live-demonstration.json`, `generation-*-review.json`, `job-*.json`, the evolution
ledger, and protected generation refs in the data root. Set
`AE_LIVE_CONTROLLER_REVISION` to record the tested controller revision as well.
All generated execution still requires the restricted backend.

The demo is a controlled test environment with synthetic objectives. Its explicit
approval calls do not enable policy-based production promotion. Candidate crash
and rollback checks remain in the restricted authoring integration; full fault
coverage, retention/cleanup and environment backup objectives require separate
evidence before claiming the complete MVP.

## Networkless validation VM

When inference runs on the host and generated execution runs in a networkless
VM, the optional `ollama_file_bridge.py` forwards HTTP bodies and usage counts
unchanged through a private shared queue. Run on the inference host:

```sh
python3 test/integration/ollama_file_bridge.py host --queue /private/shared/queue --url http://127.0.0.1:11435/api/chat
```

Inside the VM, using that directory's private mount:

```sh
python3 test/integration/ollama_file_bridge.py guest --queue /mounted/private/queue
```

The guest broker then uses `http://127.0.0.1:11434/api/chat`. Generated sandboxes
must not mount the queue. Request/response files retain the actual inference
trace for inspection; the bridge supplies no authoring content or mock results.
