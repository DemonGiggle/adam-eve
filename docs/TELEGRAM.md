# Telegram

The optional controller-owned Telegram frontend uses long polling, modeled on
[q-agent](https://github.com/DemonGiggle/q-agent). It handles private chats,
groups and forum topics, with separate topic conversation histories. Model and
provider settings are shared across a chat or group. The bot token and provider
keys stay in the controller and are never passed to agent runtimes.

Provision an identity as described in the [README](../README.md), then copy
[config.example.json](../config.example.json) and edit its Telegram section:

```json
{
  "enabled": true,
  "token_env": "TELEGRAM_BOT_TOKEN",
  "allowed_users": [123456789],
  "allowed_groups": [-1001234567890],
  "admin_user_ids": [123456789]
}
```

`allowed_users` contains private user IDs; a private chat must have the same chat
and user ID. A listed group authorizes its members. Group messages must mention
the bot, address a command to it, or reply to its message. Topic IDs separate
history. Administrators must also be listed as users; `/restart` is accepted
only from an allowed private administrator. Empty allowlists prevent startup.
Bots and commands addressed to other bots are ignored.

Save the configuration in `~/.config/adam-eve/config.json`, or set
`AE_CONFIG_FILE` to an absolute path to use a different file.

```sh
export TELEGRAM_BOT_TOKEN='your-bot-token'
scripts/ae serve
```

Alternatively omit `token_env` and set `token_path` to an absolute, owner-only
0600/0400 regular file with no symlink components. `AE_TELEGRAM_ENABLED=true`
overrides the file's enabled flag. The Bot API endpoint defaults to HTTPS;
plain HTTP is accepted only on loopback for a local proxy or fixture. Long
polling and Telegram webhooks are mutually exclusive; remove an existing webhook
through your bot administration workflow before using polling.

Commands are `/help`, `/status`, `/providers`, `/provider <name>`, `/models`,
`/model <id>`, `/think <level|auto|default>`, `/settings [default]`, `/new`,
`/cancel`, `/retry`, `/memory`, `/forget`, and `/restart`. `/models` shows the
first 64 provider results; `/model` accepts an exact model ID. `/new` cancels
that topic's pending requests and starts fresh context without deleting audit
history. `/retry` explicitly authorizes another inference attempt for the
topic's failed request and may incur a provider charge. Memory is restricted to
the chat's `tg:<bot-id>:<chat-id>:` namespace; `/forget` clears up to 32 current
entries atomically, and refuses larger sets for operator handling.

Image messages and captions work with vision-capable configured providers.
The controller downloads one Telegram photo with a 2 MiB limit, checks its file
signature, and stores its bytes with the incoming update before inference. The
image is included in that turn's provider request, not agent IPC or credentials.
The model must support the selected image format. Earlier images are retained
in the update ledger but are not automatically reattached to later turns.

Updates and their cursor commit together before another poll acknowledges them.
Completed replies are queued durably and sent in bounded chunks. Restart resumes
queued work and delivery; a reserved inference with unknown outcome is not
automatically repeated. Telegram has no idempotency key for `sendMessage`: a
network interruption after Telegram accepts a chunk but before the controller
records success can produce a duplicate chunk. It does not rerun model work.
Polling and delivery pause while restore verification or routing admission is
closed. Queue capacity defaults to 128 pending updates and can be configured
with `queue_capacity`; rate limits and transient failures back off.

The service and CLI both start a controller, so do not run them concurrently
against the same data root. Stop the service before using the standalone CLI.
`test/integration/telegram.py` exercises the frontend against a local fixture;
no real bot messages or paid inference are sent by the test suite.
