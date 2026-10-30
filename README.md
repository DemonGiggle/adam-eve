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

## Quick start

Install Erlang/OTP 24+, rebar3, Git, Python 3, a C compiler, make, and SQLite
development headers. Start Ollama and install a model, then build and provision
an identity:

```sh
scripts/build
export AE_DATA_ROOT="$HOME/.local/share/adam-eve"
export AE_LLM_MODEL="your-installed-model"
scripts/publish_seed --data-root "$AE_DATA_ROOT"
scripts/ae
```

The controller reads one JSON command per line and returns one JSON result:

```jsonl
{"op":"turn","request_id":"turn-1","session_id":"main","message":"Hello!"}
{"op":"status"}
```

Send EOF to stop. Start `scripts/ae` again with the same data root to continue.
The data root must be an absolute, private directory outside the checkout.
See [Getting started and operation](docs/OPERATIONS.md) for requirements,
configuration, retry and handoff procedures.

## Configuration

Ollama works with `AE_LLM_MODEL` and the default local endpoint. For API-key
providers or Telegram, copy [config.example.json](config.example.json), edit the
profiles, and set `AE_CONFIG_FILE` to its absolute path. Credentials are referenced
through environment variables or private files and remain in the controller.

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
