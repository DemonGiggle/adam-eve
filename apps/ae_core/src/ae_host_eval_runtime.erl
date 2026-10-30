-module(ae_host_eval_runtime).
-export([start/4, turn/3, restore/2, health/1, calls/1, close/1]).

%% The evaluator talks to a separate host BEAM over the same bounded protocol.
%% Generated code is not sandboxed and runs with the controller user's access.
start(Root, Manifest, Config, Deadline) ->
    Directory = filename:join("/tmp", "ae-eval-" ++ binary_to_list(hex(crypto:strong_rand_bytes(12)))),
    ok = file:make_dir(Directory), ok = file:change_mode(Directory, 8#700),
    Path = filename:join(Directory, "ipc"),
    Token = hex(crypto:strong_rand_bytes(32)), Epoch = rand:uniform(1000000),
    try
        {ok, Listen} = gen_tcp:listen(0, [{ifaddr, {local, Path}} | ae_protocol:socket_options()]),
        ok = file:change_mode(Path, 8#600),
        Parent = self(), Executable = ae_artifacts:executable(Root, Manifest),
        Owner = spawn(fun() -> port_owner(Parent, Executable, Path, Token, Deadline) end),
        State0 = #{directory => Directory, owner => Owner, manifest => Manifest, config => Config,
            deadline => Deadline, token => Token, epoch => Epoch, sequence => 0},
        try
            {ok, Socket} = gen_tcp:accept(Listen, timeout(Deadline, maps:get(<<"startup_ms">>, Config))),
            State = State0#{socket => Socket},
            {ok, #{<<"type">> := <<"authenticate">>, <<"token">> := Token}} = recv(State, maps:get(<<"startup_ms">>, Config)),
            send(State, <<"hello">>, #{<<"slot">> => <<"adam">>, <<"runtime_instance_id">> => nonce(16),
                <<"generation">> => maps:get(<<"digest">>, Manifest), <<"capabilities">> => maps:get(<<"capabilities">>, Manifest)}),
            Restored = restore(State, rand:uniform(10000)),
            ok = health(Restored),
            put({eval_calls, Token}, 0),
            {ok, Restored}
        catch Class:Reason:Stack ->
            Owner ! stop, file:del_dir_r(Directory), erlang:raise(Class, Reason, Stack)
        after gen_tcp:close(Listen) end
    catch Class2:Reason2:Stack2 -> file:del_dir_r(Directory), erlang:raise(Class2, Reason2, Stack2) end.

restore(State, Sequence) ->
    send(State, <<"restore">>, #{<<"checkpoint_id">> => nonce(16), <<"state_schema_version">> => 1,
        <<"last_event_seq">> => Sequence}),
    {ok, #{<<"type">> := <<"ready">>, <<"generation">> := Generation, <<"restored_seq">> := Sequence,
        <<"supported_schema_versions">> := [1]}} = recv(State, maps:get(<<"startup_ms">>, maps:get(config, State))),
    Generation = maps:get(<<"digest">>, maps:get(manifest, State)), State#{sequence := Sequence}.
health(State) ->
    Request = nonce(16), send(State, <<"health_check">>, #{<<"request_id">> => Request}),
    {ok, #{<<"type">> := <<"health_status">>, <<"request_id">> := Request, <<"status">> := <<"ok">>}} =
        recv(State, maps:get(<<"turn_ms">>, maps:get(config, State))), ok.
calls(State) -> case get({eval_calls, maps:get(token, State)}) of undefined -> 0; N -> N end.
close(State) ->
    catch gen_tcp:close(maps:get(socket, State)), maps:get(owner, State) ! stop,
    erase({eval_calls, maps:get(token, State)}), file:del_dir_r(maps:get(directory, State)), ok.

turn(State, Case, Policy) ->
    Started = erlang:monotonic_time(microsecond), Request = nonce(16),
    Deadline = min(maps:get(deadline, State), erlang:monotonic_time(millisecond) + maps:get(<<"turn_ms">>, maps:get(config, State))),
    Memory = maps:get(<<"history">>, Case) ++ [#{<<"role">> => <<"user">>, <<"content">> => maps:get(<<"message">>, Case)}],
    send(State, <<"user_turn">>, #{<<"request_id">> => Request, <<"session_id">> => nonce(16),
        <<"epoch">> => maps:get(epoch, State), <<"message">> => maps:get(<<"message">>, Case),
        <<"memory_cursor">> => maps:get(sequence, State)}),
    turn_loop(State, Case, Policy, Request, Memory, Deadline, Started, #{}, 0, 0, true, 0).

turn_loop(State, Case, Policy, Request, Memory, Deadline, Started, Cache, Calls, Reads, Correct, Steps) ->
    true = Steps =< maps:get(<<"max_tool_requests">>, Policy),
    {ok, Message} = ae_protocol:recv(maps:get(socket, State), timeout(Deadline, maps:get(<<"turn_ms">>, maps:get(config, State)))),
    Request = maps:get(<<"request_id">>, Message),
    case maps:get(<<"type">>, Message) of
        <<"assistant_reply">> ->
            [] = maps:get(<<"event_refs">>, Message),
            result(Case, <<"reply">>, maps:get(<<"text">>, Message), Correct, Calls, Reads, Started);
        <<"turn_failed">> ->
            result(Case, <<"failure">>, maps:get(<<"reason">>, Message), Correct, Calls, Reads, Started);
        <<"tool_request">> ->
            Epoch = maps:get(epoch, State), Epoch = maps:get(<<"epoch">>, Message),
            Tool = maps:get(<<"tool">>, Message), Args = maps:get(<<"args">>, Message), Key = maps:get(<<"idempotency_key">>, Message),
            true = lists:member(Tool, [<<"memory_read">>, <<"llm">>]),
            true = lists:member(Tool, maps:get(<<"capabilities">>, maps:get(manifest, State))),
            {Response, NextCache, NextCalls, NextReads, NextCorrect} = case maps:find(Key, Cache) of
                {ok, {Tool, Args, Previous}} -> {Previous, Cache, Calls, Reads, Correct};
                {ok, _} -> error(idempotency_conflict);
                error ->
                    {Value, C, R, IsCorrect} = tool(State, Tool, Args, Memory, Case, Calls, Reads, Correct),
                    {Value, Cache#{Key => {Tool, Args, Value}}, C, R, IsCorrect}
            end,
            send(State, <<"tool_result">>, #{<<"request_id">> => Request, <<"idempotency_key">> => Key, <<"result">> => Response}),
            turn_loop(State, Case, Policy, Request, Memory, Deadline, Started, NextCache, NextCalls, NextReads, NextCorrect, Steps + 1);
        _ -> error(invalid_runtime_message)
    end.
tool(_, <<"memory_read">>, Args, Memory, _, Calls, Reads, Correct) ->
    true = map_size(Args) =:= 0, {#{<<"messages">> => Memory}, Calls, Reads + 1, Correct};
tool(State, <<"llm">>, #{<<"messages">> := Messages} = Args, _, Case, Calls, Reads, Correct) ->
    true = map_size(Args) =:= 1 andalso is_list(Messages) andalso length(Messages) =< 32,
    true = lists:all(fun(M) -> is_map(M) andalso lists:sort(maps:keys(M)) =:= [<<"content">>, <<"role">>] andalso
        lists:member(maps:get(<<"role">>, M), [<<"system">>, <<"user">>, <<"assistant">>]) andalso
        is_binary(maps:get(<<"content">>, M)) andalso byte_size(maps:get(<<"content">>, M)) > 0 andalso
        byte_size(maps:get(<<"content">>, M)) =< 65536 end, Messages),
    Token = maps:get(token, State), put({eval_calls, Token}, calls(State) + 1),
    {maps:get(<<"model_result">>, Case), Calls + 1, Reads, Correct andalso Messages =:= maps:get(<<"expected_messages">>, Case)}.
result(Case, Outcome, Reply, Correct, Calls, Reads, Started) ->
    #{success => Outcome =:= maps:get(<<"expected_type">>, Case) andalso Reply =:= maps:get(<<"expected_text">>, Case)
        andalso Correct andalso Calls > 0 andalso Reads > 0,
      memory_correct => Correct andalso Reads > 0, tool_correct => Calls > 0, calls => Calls,
      latency_us => max(0, erlang:monotonic_time(microsecond) - Started), reply => Reply, outcome => Outcome}.

send(State, Type, Fields) ->
    ok = ae_protocol:send(maps:get(socket, State), Fields#{<<"type">> => Type, <<"protocol_version">> => 1}).
recv(State, Duration) -> ae_protocol:recv(maps:get(socket, State), timeout(maps:get(deadline, State), Duration)).
timeout(Deadline, Duration) -> Remaining = min(Duration, Deadline - erlang:monotonic_time(millisecond)), true = Remaining > 0, Remaining.
nonce(N) -> hex(crypto:strong_rand_bytes(N)).
hex(Bytes) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).

port_owner(Parent, Executable, Path, Token, Deadline) ->
    process_flag(trap_exit, true), Ref = monitor(process, Parent),
    try
        Port = open_port({spawn_executable, "/usr/bin/escript"}, [binary, exit_status, use_stdio, stderr_to_stdout,
            {env, ae_os:clean_env()}, {args, [Executable, Path, binary_to_list(Token)]}]),
        owner_loop(Port, Ref, Deadline, 0)
    catch _:_ -> ok end.
owner_loop(Port, Ref, Deadline, Bytes) ->
    receive
        {Port, {data, Data}} when Bytes + byte_size(Data) =< 1048576 -> owner_loop(Port, Ref, Deadline, Bytes + byte_size(Data));
        {Port, {data, _}} -> catch port_close(Port);
        {Port, {exit_status, _}} -> ok;
        {'DOWN', Ref, process, _, _} -> catch port_close(Port);
        stop -> catch port_close(Port)
    after max(0, Deadline - erlang:monotonic_time(millisecond)) -> catch port_close(Port) end.
