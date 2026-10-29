-module(ae_os).
-export([run/3, clean_env/0]).

run(Executable, Args, Timeout) ->
    Port = open_port({spawn_executable, Executable},
                     [binary, exit_status, use_stdio, stderr_to_stdout, {args, Args}]),
    Timer = erlang:send_after(Timeout, self(), {command_timeout, Port}),
    try collect(Port, <<>>) after erlang:cancel_timer(Timer) end.

collect(Port, Acc) ->
    receive
        {Port, {data, Bytes}} when byte_size(Acc) + byte_size(Bytes) =< 1048576 ->
            collect(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {exit_status, 0}} -> {ok, string:trim(Acc)};
        {Port, {exit_status, _}} -> {error, command_failed};
        {command_timeout, Port} -> catch port_close(Port), {error, command_timeout};
        {Port, {data, _}} -> catch port_close(Port), {error, command_output_limit}
    end.

clean_env() ->
    [{Name, false} || Entry <- os:getenv(),
        Name <- [hd(string:split(Entry, "="))], Name =/= "PATH"] ++
        [{"PATH", "/usr/bin:/bin"}, {"ERL_FLAGS", "+S 2:2 +A 1"}].
