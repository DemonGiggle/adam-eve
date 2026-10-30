-module(ae_host_command).
-export([run/5, run_capture/5]).

%% Execute a fixed host tool directly, without a shell or inherited credentials.
%% The owner process controls the port; a timeout or output overflow closes it.
run(Executable, Args, Env, Timeout, Limit)
        when is_list(Executable), is_list(Args), is_list(Env),
             is_integer(Timeout), Timeout > 0, is_integer(Limit), Limit > 0 ->
    execute(Executable, Args, Env, Timeout, Limit, false).

run_capture(Executable, Args, Env, Timeout, Limit)
        when is_list(Executable), is_list(Args), is_list(Env),
             is_integer(Timeout), Timeout > 0, is_integer(Limit), Limit > 0 ->
    execute(Executable, Args, Env, Timeout, Limit, true).

execute(Executable, Args, Env, Timeout, Limit, IncludeFailure) ->
    try
        Port = open_port({spawn_executable, Executable}, [binary, exit_status, use_stdio,
            stderr_to_stdout, {env, ae_os:clean_env() ++ Env}, {args, Args}]),
        Timer = erlang:send_after(Timeout, self(), {host_command_timeout, Port}),
        try collect(Port, Limit, <<>>, IncludeFailure)
        after erlang:cancel_timer(Timer), catch port_close(Port), flush(Port) end
    catch _:_ -> {error, command_unavailable} end.

collect(Port, Limit, Acc, IncludeFailure) ->
    receive
        {Port, {data, Bytes}} when byte_size(Acc) + byte_size(Bytes) =< Limit ->
            collect(Port, Limit, <<Acc/binary, Bytes/binary>>, IncludeFailure);
        {Port, {data, _}} -> {error, output_limit};
        {Port, {exit_status, 0}} -> {ok, Acc};
        {Port, {exit_status, Code}} ->
            case IncludeFailure of true -> {error, {exit_status, Code, Acc}}; false -> {error, command_failed} end;
        {host_command_timeout, Port} -> {error, timeout}
    end.

flush(Port) ->
    receive {Port, _} -> flush(Port); {host_command_timeout, Port} -> flush(Port)
    after 0 -> ok end.
