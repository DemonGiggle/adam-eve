-module(ae_runtime_worker).
-behaviour(gen_server).
-export([start_link/3, turn/4, auth/1, health/1, os_pid/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Root, Routing, Config) -> gen_server:start_link(?MODULE, {Root, Routing, Config}, []).
turn(Pid, Request, Session, Message) -> gen_server:call(Pid, {turn, Request, Session, Message}, 315000).
auth(Pid) -> gen_server:call(Pid, auth).
health(Pid) -> gen_server:call(Pid, health, 10000).
os_pid(Pid) -> gen_server:call(Pid, os_pid).

init({Root, Routing, Config}) ->
    process_flag(trap_exit, true),
    Manifest = maps:get(<<"artifact">>, Routing),
    ok = ae_artifacts:verify(Root, Manifest),
    Instance = hex(crypto:strong_rand_bytes(16)),
    Token = hex(crypto:strong_rand_bytes(32)),
    Directory = filename:join("/tmp", "ae-" ++ binary_to_list(Instance)),
    ok = file:make_dir(Directory),
    ok = file:change_mode(Directory, 8#700),
    Path = filename:join(Directory, "ipc"),
    try
        {ok, Listen} = gen_tcp:listen(0, [{ifaddr, {local, Path}} | ae_protocol:socket_options()]),
        try
            ok = file:change_mode(Path, 8#600),
            Port = open_port({spawn_executable, os:find_executable("escript")},
                [binary, exit_status, use_stdio, {env, ae_os:clean_env()},
                 {args, [ae_artifacts:executable(Root, Manifest), Path, binary_to_list(Token)]}]),
            try
                {ok, Socket} = gen_tcp:accept(Listen, 5000),
                {ok, #{<<"type">> := <<"authenticate">>, <<"token">> := Token}} =
                    ae_protocol:recv(Socket, 5000),
                Generation = maps:get(<<"digest">>, Manifest),
                ok = send(Socket, <<"hello">>, #{<<"slot">> => maps:get(<<"slot">>, Routing),
                    <<"runtime_instance_id">> => Instance, <<"generation">> => Generation,
                    <<"capabilities">> => maps:get(<<"capabilities">>, Manifest)}),
                Seq = ae_store:last_seq(),
                ok = send(Socket, <<"restore">>, #{<<"checkpoint_id">> => <<"event-log">>,
                    <<"state_schema_version">> => 1, <<"last_event_seq">> => Seq}),
                {ok, #{<<"type">> := <<"ready">>, <<"generation">> := Generation,
                       <<"restored_seq">> := Seq, <<"supported_schema_versions">> := [1]}} =
                    ae_protocol:recv(Socket, 5000),
                {ok, Active} = ae_store:activate(Routing, Instance),
                Auth = {maps:get(<<"slot">>, Active), Instance, maps:get(<<"epoch">>, Active)},
                {ok, #{socket => Socket, port => Port, directory => Directory,
                       auth => Auth, timeout => maps:get(llm_timeout, Config) + 10000}}
            catch Class:Reason:Stack ->
                catch port_close(Port), erlang:raise(Class, Reason, Stack)
            end
        after gen_tcp:close(Listen) end
    catch Class2:Reason2:Stack2 ->
        file:del_dir_r(Directory), erlang:raise(Class2, Reason2, Stack2)
    end.

handle_call(auth, _, #{auth := Auth} = State) -> {reply, Auth, State};
handle_call(os_pid, _, #{port := Port} = State) ->
    {os_pid, OsPid} = erlang:port_info(Port, os_pid), {reply, OsPid, State};
handle_call(health, _, #{socket := Socket} = State) ->
    Probe = hex(crypto:strong_rand_bytes(8)),
    ok = send(Socket, <<"health_check">>, #{<<"request_id">> => Probe}),
    Reply = case ae_protocol:recv(Socket, 5000) of
        {ok, #{<<"type">> := <<"health_status">>, <<"request_id">> := Probe,
               <<"status">> := <<"ok">>}} -> ok;
        _ -> {error, unhealthy}
    end,
    {reply, Reply, State};
handle_call({turn, Request, Session, Message}, _, #{socket := Socket, auth := {_, _, Epoch}} = State) ->
    Turn = #{<<"request_id">> => Request, <<"session_id">> => Session,
        <<"epoch">> => Epoch, <<"message">> => Message, <<"memory_cursor">> => ae_store:last_seq()},
    case send(Socket, <<"user_turn">>, Turn) of
        ok ->
            Deadline = erlang:monotonic_time(millisecond) + maps:get(timeout, State),
            case exchange(State#{deadline => Deadline}, Request, [<<"memory_read">>, <<"llm">>]) of
                {error, runtime_protocol_failure} = Error -> {stop, normal, Error, State};
                Reply -> {reply, Reply, State}
            end;
        _ -> {stop, normal, {error, runtime_unavailable}, State}
    end.
handle_cast(_, State) -> {noreply, State}.
handle_info({Port, {exit_status, _}}, #{port := Port} = State) -> {stop, normal, State};
handle_info({'EXIT', Port, _}, #{port := Port} = State) -> {stop, normal, State};
handle_info({_, {data, _}}, State) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, State) ->
    catch gen_tcp:close(maps:get(socket, State)),
    catch port_close(maps:get(port, State)),
    file:del_dir_r(maps:get(directory, State)), ok.

exchange(#{socket := Socket, auth := Auth, deadline := Deadline} = State, Request, Remaining) ->
    Timeout = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case ae_protocol:recv(Socket, Timeout) of
        {ok, #{<<"type">> := <<"tool_request">>, <<"tool">> := Tool,
               <<"request_id">> := Request, <<"idempotency_key">> := Key} = Message}
                when Remaining =/= [] ->
            case Remaining of
                [Tool | Rest] ->
                    case ae_tool_broker:request(Auth, Request, Message) of
                        {ok, Result} ->
                            ok = send(Socket, <<"tool_result">>, #{<<"request_id">> => Request,
                                <<"idempotency_key">> => Key, <<"result">> => Result}),
                            exchange(State, Request, Rest);
                        _ -> {error, runtime_protocol_failure}
                    end;
                _ -> {error, runtime_protocol_failure}
            end;
        {ok, #{<<"type">> := <<"assistant_reply">>, <<"request_id">> := Request,
               <<"text">> := Text}} when Remaining =:= [] -> {ok, Text};
        {ok, #{<<"type">> := <<"turn_failed">>, <<"request_id">> := Request,
               <<"reason">> := Reason}} -> {error, Reason};
        _ -> {error, runtime_protocol_failure}
    end.

send(Socket, Type, Fields) ->
    ae_protocol:send(Socket, Fields#{<<"type">> => Type, <<"protocol_version">> => 1}).
hex(Bytes) -> list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bytes])).
