# Erlang host migration notes

The experiment owner authorized running generated code with host access and
requested that the Erlang controller stop invoking other language runtimes.
The controller's disk admission, runtime launcher, builder and evaluator now
use Erlang and standard host utilities. The former Python sandbox, candidate
builder and evaluator are removed. `AE_RUNTIME_ISOLATION=host` is the default;
an explicit request for the removed `bubblewrap` backend is rejected.

Standalone publication, backup, restore and cleanup commands remain Python, as
do integration test drivers. These are not invoked from the Erlang controller.
If the intended scope also includes removing Python from operator commands,
those tools need a separate native migration with backup and crash-recovery
compatibility tests. Existing identities and backup formats must remain usable.

The revised full suite has passed synthetic authoring, failed-build repair,
manual approval, promotion, crash, rollback, and controller crash-boundary tests.
The removed sandbox and its delegated-cgroup tests do not apply to host
execution. The Erlang candidate publisher now has deterministic SIGKILL coverage
at six publication boundaries, including before file sync and before/after the
atomic rename. The tests verify baseline availability, complete releases,
idempotent recovery, and rejection of conflicting manifests. These process-crash
tests do not simulate filesystem power loss.
