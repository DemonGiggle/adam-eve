-module(ae_host_git).
-export([run/4]).

%% Use a fixed local Git executable, with configuration, hooks and network
%% disabled. Inputs are arguments or files, never interpolated shell commands.
run(Root, Args, ExtraEnv, Limit) ->
    Env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_NO_REPLACE_OBJECTS", "1"},
        {"GIT_TERMINAL_PROMPT", "0"}, {"GIT_OPTIONAL_LOCKS", "0"},
        {"GIT_ALLOW_PROTOCOL", ""}, {"LC_ALL", "C.UTF-8"}, {"TZ", "UTC"}] ++ ExtraEnv,
    Prefix = ["--no-replace-objects", "--git-dir", filename:join(Root, "source.git"),
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
        "-c", "core.attributesFile=/dev/null", "-c", "gc.auto=0", "-c", "maintenance.auto=false"],
    ae_host_command:run("/usr/bin/git", Prefix ++ Args, Env, 10000, Limit).
