# Live-model evolution demonstration

`test/integration/live_evolution.py` is an opt-in demonstration using an
installed Ollama model. It creates a new identity and retains source, releases,
scorecards, and explicit test-operator approvals. It is not part of `scripts/test`.
Generated builds, candidate tests, and agent runtimes run on the host with the
controller user's permissions; see [Host execution](HOST_EXECUTION.md).

Build the project, start Ollama, and install a model. Choose a new private data
root outside the checkout and set the model's exact digest from Ollama's
`/api/tags` response:

```sh
scripts/build
export AE_RUNTIME_ISOLATION=host
export AE_LIVE_LLM_MODEL=your-installed-model
export AE_LIVE_LLM_URL=http://127.0.0.1:11434/api/chat
export AE_LIVE_MODEL_DIGEST=the-64-hex-model-digest
python3 test/integration/live_evolution.py --data-root /absolute/new/private/identity
```

The harness declares its own test budgets and evaluation policy. They are not
production defaults. `AE_EVOLUTION_LLM_TIMEOUT_MS` can adjust the authoring
request timeout; `AE_JSX_PACKAGE` can select the pinned JSX package outside the
standard rebar cache. The caller must ensure the selected model and time budgets
are suitable for its environment.

Adam authors a change to replies beginning with `hello:`. After evaluation and
explicit test-operator approval, Eve authors a second change for `bye:` while
preserving the first behavior. The harness checks two promotions and a full
restart using retained artifacts. The data root contains `live-demonstration.json`,
review files, job records, and protected generation refs for inspection.

This demonstration uses synthetic objectives. Its success does not establish
model quality on general tasks or protect the host from generated code. The
regular fixture suite separately exercises crash recovery and rollback.
