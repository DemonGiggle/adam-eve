# LLM providers

Provider profiles follow the registry and credential-reference design in
[q-agent](https://github.com/DemonGiggle/q-agent). Network requests and credentials
belong to the trusted controller; agent runtimes receive normalized text results.

The controller automatically reads `~/.config/adam-eve/config.json`, based on
[config.example.json](../config.example.json). Set `AE_CONFIG_FILE` to an absolute
path to use a different file; see [Getting started](OPERATIONS.md) for setup. Each profile has an operator-chosen
name, an adapter, model, endpoint and optional thinking selection. Configure any
number of profiles up to 32, including multiple instances of the same adapter.
Unconfigured profiles cannot be selected. `AE_PROVIDERS_JSON` can supply the
profile map directly; `AE_LLM_PROVIDER` overrides the default profile name.

| Adapter | Default interface | Credential |
|---|---|---|
| `ollama` | `/api/chat`, `/api/tags` | Optional API key |
| `openai` | Responses; optional Chat Completions | `OPENAI_API_KEY` |
| `opencode-go` | Responses with client/session headers | `OPENCODE_GO_API_KEY` |
| `anthropic` | Messages | `ANTHROPIC_API_KEY` |

`wire` can select `responses`, `chat_completions` or `messages` for API profiles.
`model_routes` can override it for individual models. OpenCode's current Console
endpoints translate text models across the supported APIs; see its
[endpoint documentation](https://opencode.ai/v2/docs/console/go/#endpoints).
Custom API-compatible endpoints are supported. URLs with credentials or fragments
are refused, redirects are disabled, HTTPS verifies the system CA/hostname, and
bearer credentials over plain HTTP are allowed only on loopback for local proxies
and tests. Remote unauthenticated Ollama endpoints can be configured directly.

Existing `AE_LLM_MODEL` and `AE_LLM_URL` configuration still creates a single
Ollama profile when no profile map is supplied. An Ollama URL can be its base URL
or the complete `/api/chat` endpoint.

Use `api_key_env` or `api_key_path`, with at most one configured. A key file must
be an absolute regular file owned by the controller user, mode 0600 or 0400,
without symlink components or hard links. File reads use the opened descriptor
and bounded content; multiline bearer values are refused. Keys are resolved at
request time and never stored in conversation, session settings or code artifacts.

`thinking: "auto"` or an empty value omits the thinking field; it does not claim
equivalence with a concrete effort. Ollama supports `on`/`off` as boolean `think`
and explicit effort strings. Responses uses `reasoning.effort`, and Chat
Completions uses `reasoning_effort`. Unsupported explicit settings fail rather
than silently disappearing. Profile `models` metadata can declare exact
`thinking_levels` for each model to reject invalid selections before inference.
Models are listed from the selected provider, not a fixed global model list.
See [OpenAI's reasoning documentation](https://developers.openai.com/api/docs/guides/reasoning).

## Durable chat settings

The JSON CLI provides `providers`, `models {provider}`, `settings {session_id}`,
`settings {session_id, field, value}` and `new {session_id}`. Settings fields are
`provider`, `model`, `thinking` and `default`. Switching providers resets the
model/thinking overrides to that profile's defaults; switching models clears the
previous thinking override. `thinking: default` clears only that override.

Every admitted turn pins its provider, model, thinking and context boundary in
the same transaction as the user message. Later settings/reset commands affect
future turns. Existing acknowledged replies replay without resolving credentials
or calling a provider. `new` starts fresh context while retaining the audit and
old replies. Backups include settings/pins and reject a missing required pin.
Telegram settings are shared across a chat/group, with separate topic histories
and topic-specific resets. Telegram context only injects memory keys under its
`tg:<bot-id>:<chat-id>:` namespace; global CLI facts and other chats' memory are
excluded.

## Authoring and spending

`evolution_provider` (or `AE_EVOLUTION_PROVIDER`) chooses the authoring profile
independently of chat settings. Budgeted API calls cap generated tokens, require
nonnegative reported input/output usage, and refuse missing or excessive usage.
They conservatively require the encoded text bytes plus framing allowance to fit
the input reservation before HTTP. Ollama additionally bounds `num_ctx`.
Responses/Chat Completions request JSON mode; the agent and controller still
validate actions, patch scope and all build/evaluation gates. See the official
[structured-output guide](https://developers.openai.com/api/docs/guides/structured-outputs).

The client never automatically repeats an ambiguous failed inference.

`test/integration/providers.py` uses a local HTTP fixture and synthetic keys to
verify API wires, model listing, credential headers, required usage, output
completion checks. It sends no paid requests. Subscription/OAuth adapters are
outside the requested scope; the configured providers use Ollama or API keys.
