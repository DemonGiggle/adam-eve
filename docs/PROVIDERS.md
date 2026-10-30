# LLM providers

Provider profiles follow the registry and credential-reference design in
[q-agent](https://github.com/DemonGiggle/q-agent). Network requests and credentials
belong to the trusted controller; agent runtimes receive normalized text results.

Set `AE_CONFIG_FILE` to a JSON configuration based on
[config.example.json](../config.example.json). Each profile has an operator-chosen
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
| `chatgpt` | Subscription Responses stream and account-scoped model catalog | Console PKCE login file |

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

## Authoring and spending

`evolution_provider` (or `AE_EVOLUTION_PROVIDER`) chooses the authoring profile
independently of chat settings. Budgeted API calls cap generated tokens, require
nonnegative reported input/output usage, and refuse missing or excessive usage.
They conservatively require the encoded text bytes plus framing allowance to fit
the input reservation before HTTP. Ollama additionally bounds `num_ctx`.
Responses/Chat Completions request JSON mode; the agent and controller still
validate actions, patch scope and all build/evaluation gates. See the official
[structured-output guide](https://developers.openai.com/api/docs/guides/structured-outputs).

The subscription compatibility endpoint does not provide the output-cap contract
required by evolution accounting. It is available for ordinary conversation;
select a budget-capable authoring profile to enable evolution. Ordinary
subscription requests retain the controller deadline and response-size ceiling.
The client never automatically repeats an ambiguous failed inference.

## ChatGPT subscription login

Configure a `chatgpt` profile, then run:

```sh
AE_CONFIG_FILE=/absolute/config.json scripts/ae login chatgpt
```

Open the printed authorization URL, approve in the browser, and paste the full
localhost callback URL into the console. The compatibility flow follows
q-agent's PKCE/state design and Codex subscription endpoint. It has a ten-minute
login deadline, verifies the exact callback and state, and writes a private token
file atomically. The callback is never accepted from Telegram. Tokens refresh
under a per-file lock before expiry and once after a confirmed 401; simultaneous
callers reuse a rotated credential instead of refreshing the stale token twice.
Model catalog requests use the selected account's credentials.

This is separate from OpenAI API-key authentication and from registering a new
Sign in with ChatGPT client. The official integration contract is documented in
[Sign in with ChatGPT](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server).

`test/integration/providers.py` uses a local HTTP fixture and synthetic keys to
verify API wires, model listing, credential headers, required usage, output
completion checks, and PKCE callback/state persistence. It sends no paid requests.
