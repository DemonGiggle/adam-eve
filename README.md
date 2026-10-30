# adam-eve

> A self-evolving AI agent built on Erlang/OTP

adam-eve separates a trusted controller from replaceable Adam/Eve agent runtimes.
Conversations and code survive runtime replacement, while proposed changes pass
independent checks and explicit approval before promotion.

## Features

- **Durable conversations** with replay, bounded retries, and persistent memory.
- **Controlled evolution** with isolated candidate builds, evaluation, approval,
  observation, and rollback.
- **LLM providers** for Ollama, OpenAI-compatible APIs, OpenCode Go, and Anthropic.
- **Telegram integration** for private chats, groups, forum topics, and photos.
- **Recoverable state** with retained source and artifacts, backups, and fenced restore.
- **Host execution** on Linux; complete aggregate resource enforcement is planned
  for v0.2.

## Supported providers

| Provider | Adapter | Setup |
|---|---|---|
| OpenAI and compatible APIs | `openai` | API key and model; custom endpoints supported |
| Anthropic | `anthropic` | API key and model |
| OpenCode Go | `opencode-go` | API key and model |
| Ollama | `ollama` | Running Ollama server and installed model |

See [LLM providers](docs/PROVIDERS.md) for endpoints, credentials, model
selection, and thinking settings. Providers use Ollama or API keys; subscription
login is not supported.

## Quick start

On Linux, install Erlang/OTP 24+, rebar3, Git, Python 3, a C compiler, make,
and SQLite development headers. For example, on Ubuntu 22.04 or newer:

```sh
sudo apt update
sudo apt install erlang rebar3 git python3 build-essential libsqlite3-dev
```

Clone this repository and copy the example configuration:

```sh
git clone https://github.com/DemonGiggle/adam-eve.git
cd adam-eve
mkdir -p "$HOME/.config/adam-eve"
cp -n config.example.json "$HOME/.config/adam-eve/config.json"
export AE_CONFIG_FILE="$HOME/.config/adam-eve/config.json"
```

Open `~/.config/adam-eve/config.json` in a text editor. Choose a configured
profile, set `default_provider` to its name, and replace its `model` placeholder
with a model available from that provider:

- **OpenAI:** use the `openai` profile and set `OPENAI_API_KEY` in your shell.
  For a compatible service, also set its `base_url` and, if needed, its `wire`.
- **OpenCode Go:** use the `opencode-go` profile and set `OPENCODE_GO_API_KEY`.
- **Anthropic:** add `"anthropic": {"adapter": "anthropic", "model": "your-model"}`
  inside `providers`, select `anthropic`, and set `ANTHROPIC_API_KEY`.
- **Ollama:** use the `ollama` profile, start Ollama, and install the selected
  model. [Getting started](docs/OPERATIONS.md) includes a local setup example.

For example, export an API key with `export OPENAI_API_KEY='your-api-key'`.
The controller reads the file specified by `AE_CONFIG_FILE`; it does not discover
the file automatically. The copy command preserves an existing config file.
Any readable absolute path can be used.

Build and provision an identity, then start the controller:

```sh
scripts/build
export AE_DATA_ROOT="$HOME/.local/share/adam-eve"
export AE_LLM_TIMEOUT_MS=120000
scripts/publish_seed --data-root "$AE_DATA_ROOT"
scripts/ae
```

Enter the following line in the running `scripts/ae` session and press Enter:

```jsonl
{"op":"turn","request_id":"turn-1","session_id":"main","message":"Hello!"}
```

The controller returns a JSON object with the agent's reply in `text` and
`"committed":true`. Each new message needs a new `request_id`; keep the same
`session_id` to continue the conversation. Adjust the timeout above for your
provider and model if needed.

Press Ctrl+D to stop. To continue later, set the same `AE_CONFIG_FILE`,
`AE_DATA_ROOT`, and `AE_LLM_TIMEOUT_MS` in your shell and run `scripts/ae` from
the checkout. Do not run `scripts/publish_seed` again for the same identity.
The data root must be an absolute, private directory outside the checkout.
See [Getting started and operation](docs/OPERATIONS.md) for requirements,
configuration, retry and handoff procedures.

## Configuration

The example configuration includes a disabled Telegram section. Credentials are
referenced through environment variables or private files and remain in the
controller. The evolution provider can be configured independently of the
conversation provider.

- [LLM providers](docs/PROVIDERS.md) — profiles, credentials, models, and thinking.
- [Telegram](docs/TELEGRAM.md) — bot setup, allowlists, commands, and topics.

Evolution is disabled by default. Enabling it requires explicit limits and a
restricted runtime; see [Controlled evolution](docs/EVOLUTION.md) and
[Isolation](docs/ISOLATION.md).

## Documentation

- [Getting started and operation](docs/OPERATIONS.md) — build, CLI, configuration, and manual handoff.
- [Controlled evolution](docs/EVOLUTION.md) — authoring, approval, and recovery.
- [Building](docs/BUILD.md) and [evaluation](docs/EVALUATION.md) — candidate construction and checks.
- [Isolation](docs/ISOLATION.md) — sandbox requirements and resource profiles.
- [Memory](docs/MEMORY.md) — persistent facts and context.
- [Backup and restore](docs/RECOVERY.md) and [retention](docs/RETENTION.md) — state and artifact management.
- [Runtime protocol](docs/PROTOCOL.md) — controller and agent communication.
- [Specification](docs/SPEC.md) — architecture, invariants, and milestones.
- [Live-model demonstration](docs/LIVE_EVOLUTION.md) — optional acceptance exercise.

## Tests

Run the suite on the host without a model or provider credentials:

```sh
scripts/test
```

The suite uses local provider fixtures. Some sandbox checks require a delegated
cgroup v2 test root; see [Isolation](docs/ISOLATION.md).
