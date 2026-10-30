# Host execution

adam-eve runs the controller, agent runtimes, candidate compiler, and candidate
tests on the host as the same operating-system user. Generated code can read,
modify, or delete files and access the network or other processes available to
that user. Separate BEAM processes and the broker protocol do not provide an OS
security boundary. Run experiments only in an environment whose host access is
acceptable to you.

The controller removes inherited environment variables from spawned agent and
compiler processes and passes provider credentials through controller-owned
broker calls. This reduces accidental exposure, but it does not prevent code
running as the same user from accessing host files or processes.

`AE_RUNTIME_ISOLATION=host` selects host execution and is the default. The old
`development` value is accepted as a host alias. `bubblewrap` is no longer
supported and is rejected rather than silently changing an explicitly requested
sandbox into host execution. Existing data and retained artifacts remain usable
with the host setting.

Evolution remains disabled by default. When enabled, the controller records
attempts, reserves configured CPU and token budgets, applies output limits, and
uses job, build, evaluation, startup, and request deadlines. The CPU reservations
are accounting, not measured or enforced CPU usage. Memory and process values
in the evolution job are recorded but are not enforced as OS limits. Stopping
a supervised process does not guarantee cleanup of descendants that it created.

Builds use a pinned source revision and dependency, and evaluations compare the
candidate and baseline with synthetic model responses before explicit approval.
These checks support the experiment's quality and recovery workflow; they do
not prevent candidate code from affecting the host or bypassing the broker.
See [Controlled evolution](EVOLUTION.md), [Building](BUILD.md), and
[Evaluation](EVALUATION.md).
