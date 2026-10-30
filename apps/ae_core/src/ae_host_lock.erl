-module(ae_host_lock).
-export([with/3]).

%% flock holds the same advisory lock as the operator backup/publish tools.
%% cat echoes a nonce only after flock acquires the lock and remains attached
%% to this port until the owner releases it or dies.
with(Path, Timeout, Fun) when is_function(Fun, 0), is_integer(Timeout), Timeout > 0 ->
    Port = open_port({spawn_executable, "/usr/bin/flock"}, [binary, exit_status, use_stdio,
        {env, ae_os:clean_env()}, {args, ["--exclusive", "--no-fork", Path, "/usr/bin/cat"]}]),
    Nonce = crypto:strong_rand_bytes(16),
    Timer = erlang:send_after(Timeout, self(), {lock_timeout, Port}),
    try
        true = port_command(Port, Nonce),
        wait(Port, Nonce, <<>>),
        Fun()
    after
        erlang:cancel_timer(Timer), catch port_close(Port), flush(Port)
    end.

wait(Port, Nonce, Acc) ->
    receive
        {Port, {data, Bytes}} when byte_size(Acc) + byte_size(Bytes) =< 16 ->
            Next = <<Acc/binary, Bytes/binary>>,
            case Next of Nonce -> ok; _ -> wait(Port, Nonce, Next) end;
        {Port, {data, _}} -> error(lock_protocol_failed);
        {Port, {exit_status, _}} -> error(lock_unavailable);
        {lock_timeout, Port} -> error(lock_timeout)
    end.
flush(Port) -> receive {Port, _} -> flush(Port); {lock_timeout, Port} -> flush(Port) after 0 -> ok end.
