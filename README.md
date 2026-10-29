# adam-eve

An Erlang/OTP agent with a trusted controller and replaceable Adam/Eve runtimes.
The architecture and planned milestones are in [docs/SPEC.md](docs/SPEC.md).

The initial implementation provides the protocol and durable controller store.
The isolated seed and CLI are the next part of Phase 0. Evolution is not enabled.

Development requirements: Erlang/OTP 24+, rebar3, a C compiler, make, and SQLite
development headers. Dependencies are pinned in `rebar.lock`.

```sh
rebar3 compile
rebar3 eunit
```

The store uses SQLite WAL with `synchronous=FULL`. Runtime activation increments a
durable epoch. Turn and tool writes check the committed runtime identity and
epoch in the same transaction as their audit event. Request IDs identify turns
across retries; reusing an ID with different session/message content is rejected.
