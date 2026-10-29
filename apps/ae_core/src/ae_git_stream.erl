-module(ae_git_stream).
-export([fold/4]).

%% Trusted local Git only: no shell, network, hooks, textconv, global config, or
%% replacement objects. The consumer can stop before a large blob/tree is read.
fold(Root, Args, Step, Initial) ->
    Env = ae_os:clean_env() ++ [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_NO_REPLACE_OBJECTS", "1"}, {"GIT_CONFIG_NOSYSTEM", "1"}],
    Port = open_port({spawn_executable, os:find_executable("git")},
        [binary, exit_status, use_stdio, {env, Env},
         {args, ["--no-replace-objects", "--git-dir", filename:join(Root, "source.git")] ++ Args}]),
    Timer = erlang:send_after(10000, self(), {git_timeout, Port}),
    try collect(Port, Step, Initial)
    after
        erlang:cancel_timer(Timer), catch port_close(Port), flush(Port)
    end.
collect(Port, Step, State) ->
    receive
        {Port, {data, Chunk}} ->
            case Step(Chunk, State) of
                {continue, Next} -> collect(Port, Step, Next);
                {halt, Result} -> {ok, Result}
            end;
        {Port, {exit_status, 0}} -> {ok, State};
        {Port, {exit_status, _}} -> {error, source_unavailable};
        {git_timeout, Port} -> {error, source_timeout}
    end.
flush(Port) ->
    receive {Port, _} -> flush(Port); {git_timeout, Port} -> ok after 0 -> ok end.
