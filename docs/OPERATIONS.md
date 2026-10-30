# Getting started and operation

## Requirements and setup

Build and run on Linux with Erlang/OTP 24+, rebar3, Git, Python 3, a C compiler,
make, and SQLite development headers. Dependencies are pinned in the controller
and seed `rebar.lock` files. The restricted sandbox also requires Bubblewrap,
libseccomp and prlimit; see [Isolation](ISOLATION.md).

For a local Ollama model, start Ollama and install a model before submitting a
turn. For example, run `ollama pull llama3.2:3b`. From the checkout, copy the
example configuration:

```sh
mkdir -p "$HOME/.config/adam-eve"
cp -n config.example.json "$HOME/.config/adam-eve/config.json"
export AE_CONFIG_FILE="$HOME/.config/adam-eve/config.json"
```

Edit `providers.ollama.model` in that file to match the installed model, such as
`llama3.2:3b`. The example location is a convention, not an automatically
discovered path: set
`AE_CONFIG_FILE` to the absolute path of the file you want the controller to
read. Keep it set when restarting the controller. Existing files are not
overwritten by the copy command.

Then build and provision an identity:

```sh
scripts/build
export AE_DATA_ROOT="$HOME/.local/share/adam-eve"
export AE_LLM_TIMEOUT_MS=120000
scripts/publish_seed --data-root "$AE_DATA_ROOT"
scripts/ae
```

Alternatively, leave `AE_CONFIG_FILE` unset and set `AE_LLM_MODEL` to the
installed model name to use the single default Ollama profile. `AE_LLM_MODEL`
does not override a model in the configured profile map. See [LLM providers](PROVIDERS.md)
for API-key providers and other configuration options.

The data root must be an absolute, private directory outside the checkout. The
publisher creates it with mode 0700 if needed. Publish once per identity;
restarts use the persisted active artifact rather than rebuilding it. The seed
is a separate executable and does not load into the controller VM.

The default development runtime is for trusted, manually built code. Generated
candidates require the restricted backend. See [Isolation](ISOLATION.md) and
[Controlled evolution](EVOLUTION.md) before enabling evolution.

## JSON command interface

`scripts/ae` reads one JSON object per line and prints one JSON result per
command. Logs go to stderr; results go to stdout. For example:

```jsonl
{"op":"turn","request_id":"turn-1","session_id":"main","message":"Remember that I like tea."}
{"op":"restart"}
{"op":"turn","request_id":"turn-2","session_id":"main","message":"What do I like?"}
{"op":"status"}
{"op":"history"}
```

EOF stops the controller and seed. Start the CLI again with the same data root
and provider configuration to continue. Provider, model and thinking commands
are described in [LLM providers](PROVIDERS.md); semantic memory commands are in
[Memory](MEMORY.md). For the Telegram service, see [Telegram](TELEGRAM.md).
Run only one controller against a data root at a time.

Use a stable request ID when resubmitting a disconnected turn: a completed
request returns its saved reply without another LLM call. Conflicting reuse of
an ID is rejected. Only one pending turn is admitted at a time. A provider
failure leaves the turn pending; resubmitting it returns the recorded outcome.
If a controller crash leaves a reserved call without a recorded result,
resubmission returns `tool_outcome_unknown`. To authorize another potentially
billed call, issue the retry command and resubmit the original turn:

```jsonl
{"op":"retry","request_id":"turn-1"}
{"op":"cancel","request_id":"turn-1"}
```

Use `cancel` instead of retry to stop the request and admit other turns. Attempts
are durably bounded across restarts. Cancellation preserves audit events and
excludes the unfinished turn from subsequent model context.

## Manual handoff

A manual handoff requires all four positive limits before starting the
controller. For a local development exercise, for example:

```sh
export AE_APPROVAL_TTL_MS=60000
export AE_OBSERVE_MS=10000
export AE_HEALTH_INTERVAL_MS=250
export AE_QUIESCE_TIMEOUT_MS=5000
```

Missing or invalid values disable staging while ordinary service remains
available. Each limit is at most 300000 milliseconds and is saved in the
deployment record.

Prepare a **trusted, manually authored** Git patch against the retained active
source and publish a different artifact:

```sh
scripts/publish_candidate --data-root "$AE_DATA_ROOT" \
  --patch /absolute/path/manual-change.patch --objective 'Describe the change'
```

The publisher checks out the retained active revision in a disposable workspace,
applies the patch, and records the parent in Git ancestry and the manifest. Only
seed source and tests may change; manual patches are limited to 256 KiB. This
command builds with the operator's permissions and is not an isolated builder
for generated or untrusted code. The final stdout line is the artifact manifest;
build logs go to stderr. Publication does not change routing.

In the existing `scripts/ae` session, stage its digest, inspect the returned
baseline, artifact, evaluation and source diff, and explicitly approve the
binding:

```jsonl
{"op":"stage","artifact_digest":"<digest from the published manifest>"}
{"op":"approve","deployment_id":"<returned deployment_id>","approval_binding":"<returned approval_binding>"}
{"op":"deployment","deployment_id":"<deployment_id>"}
```

Inspect the source diff using the returned source revisions:

```sh
git --git-dir "$AE_DATA_ROOT/source.git" diff "$BASELINE_REVISION" "$CANDIDATE_REVISION"
```

Set `BASELINE_REVISION` and `CANDIDATE_REVISION` to the returned revision IDs.
A pending candidate can be rejected with
`{"op":"reject","deployment_id":"..."}`. Staging tests the candidate without
production provider calls or conversation writes. Approval is bound to the
candidate and baseline; expired approvals or changed artifacts cannot authorize
promotion. Generated candidates use separate job-bound evaluation and staging;
see [Controlled evolution](EVOLUTION.md).

Promotion closes admission, drains or retains in-flight work, checkpoints state,
and switches routing under a new epoch. Observation establishes the last
known-good candidate; a crash or incomplete observation triggers rollback.
Committed replies and tool results remain durable. Repeated active-runtime
crashes are bounded to three automatic restarts per 30 seconds; `restart`
requests recovery after the cause is fixed.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `AE_DATA_ROOT` | Required | Private persistent storage outside the checkout |
| `AE_LLM_MODEL` | Required without profiles | Ollama model name |
| `AE_LLM_URL` | `http://127.0.0.1:11434/api/chat` | Ollama endpoint; see [LLM providers](PROVIDERS.md) |
| `AE_CONFIG_FILE` | Unset | JSON provider and Telegram configuration |
| `AE_LLM_TIMEOUT_MS` | `30000` | Conversation provider timeout, 100–300000 ms |
| `AE_EVOLUTION_LLM_TIMEOUT_MS` | Conversation timeout | Authoring timeout, 100–3600000 ms, capped by the job deadline |
| `AE_RUNTIME_START_TIMEOUT_MS` | `5000` | Runtime startup deadline, 100–30000 ms |
| `AE_LLM_MAX_TOKENS` | `512` | Requested output limit, 1–8192 |
| `AE_CONTEXT_TURNS` | `8` | Recent turns supplied per session, 1–8 |
| `AE_MAX_LLM_ATTEMPTS` | `3` | Operator-authorized calls per turn, 1–10 |
| `AE_APPROVAL_TTL_MS` | Required for handoff | Staging and approval lifetime |
| `AE_OBSERVE_MS` | Required for handoff | Post-switch observation window |
| `AE_HEALTH_INTERVAL_MS` | Required for handoff | Staged and active probe interval |
| `AE_QUIESCE_TIMEOUT_MS` | Required for handoff | In-flight turn drain deadline |
| `AE_RUNTIME_ISOLATION` | `development` | Trusted manual runtime or `bubblewrap` |
| `AE_RESOURCE_LIMITS_MODE` | `cgroup` | Select `process` for the v0.1 host profile or `cgroup` for aggregate enforcement |
| `AE_CGROUP_ROOT` | Required for cgroup profile | Delegated cgroup v2 subtree |
| `AE_SANDBOX_LIMITS_JSON` | Required for Bubblewrap | Explicit limits; see [Isolation](ISOLATION.md) |
| `AE_RETENTION_POLICY_JSON` | Required for evolution | Preservation policy; see [Retention](RETENTION.md) |

See [LLM providers](PROVIDERS.md) for profile and credential options, and
[Controlled evolution](EVOLUTION.md) for evolution, builder and evaluator
configuration. Complete aggregate CPU, memory and process enforcement is
planned for v0.2; the host process profile provides per-process limits and
controller-enforced timeouts.

## Storage and verification

The controller uses SQLite WAL with `synchronous=FULL`. Turn and tool writes
check the active runtime identity and epoch in the same transaction as their
audit event; replies are committed before reporting `"committed": true`.
Conversation history remains durable even when only recent context is sent to
the provider.

Seed publication retains source in `source.git` and the exact executable under
`artifacts/<sha256>/seed`. Before launch, the controller verifies the release
and retained source, capabilities, state schema, and recorded OTP/ERTS versions.
The escript retains its compiled dependencies but requires its recorded host
ERTS. See [Building](BUILD.md), [Runtime protocol](PROTOCOL.md),
[Retention](RETENTION.md), and [Backup and restore](RECOVERY.md).

Run the complete fixture-based test suite with `scripts/test`. It exercises
controller and seed processes, provider adapters, Telegram, evolution, crash
recovery and sandbox boundaries. Full aggregate cgroup checks require an
explicitly delegated test subtree; see [Isolation](ISOLATION.md).
