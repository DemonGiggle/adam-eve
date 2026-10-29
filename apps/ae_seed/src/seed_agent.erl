-module(seed_agent).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, {Path, Token}} = application:get_env(ae_seed, connection),
    {ok, Socket} = gen_tcp:connect({local, Path}, 0, ae_protocol:socket_options(), 5000),
    ok = send(Socket, <<"authenticate">>, #{<<"token">> => Token}),
    {ok, #{<<"type">> := <<"hello">>, <<"generation">> := Generation}} =
        ae_protocol:recv(Socket, 5000),
    {ok, #{<<"type">> := <<"restore">>, <<"last_event_seq">> := Seq}} =
        ae_protocol:recv(Socket, 5000),
    ok = send(Socket, <<"ready">>, #{<<"generation">> => Generation,
        <<"restored_seq">> => Seq, <<"supported_schema_versions">> => [1]}),
    ok = inet:setopts(Socket, [{active, once}]),
    {ok, #{socket => Socket, turn => undefined}}.

handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({tcp, Socket, Data}, #{socket := Socket} = State) ->
    {ok, Message} = ae_protocol:decode(Data),
    Next = message(Message, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, Next};
handle_info({tcp_closed, _}, State) -> halt(0), {stop, normal, State};
handle_info({tcp_error, _, _}, State) -> halt(1), {stop, normal, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{socket := Socket}) -> gen_tcp:close(Socket).

message(#{<<"type">> := <<"user_turn">>} = Turn, #{socket := Socket} = State) ->
    ok = tool(Socket, Turn, <<"memory_read">>, #{}),
    State#{turn := Turn, phase => memory};
message(#{<<"type">> := <<"tool_result">>, <<"request_id">> := Request,
          <<"result">> := Result},
        #{socket := Socket, turn := #{<<"request_id">> := Request} = Turn,
          phase := memory} = State) ->
    #{<<"messages">> := Messages} = Result,
    ok = tool(Socket, Turn, <<"llm">>, #{<<"messages">> => Messages}),
    State#{phase := llm};
message(#{<<"type">> := <<"tool_result">>, <<"request_id">> := Request,
          <<"result">> := #{<<"text">> := Text}},
        #{socket := Socket, turn := #{<<"request_id">> := Request}, phase := llm} = State) ->
    ok = send(Socket, <<"assistant_reply">>, #{<<"request_id">> => Request,
        <<"text">> => Text, <<"event_refs">> => []}),
    State#{turn := undefined};
message(#{<<"type">> := <<"tool_result">>, <<"request_id">> := Request,
          <<"result">> := #{<<"error">> := Reason}}, #{socket := Socket} = State) ->
    ok = send(Socket, <<"turn_failed">>, #{<<"request_id">> => Request, <<"reason">> => Reason}),
    State#{turn := undefined};
message(#{<<"type">> := <<"health_check">>, <<"request_id">> := Request},
        #{socket := Socket} = State) ->
    ok = send(Socket, <<"health_status">>, #{<<"request_id">> => Request, <<"status">> => <<"ok">>}),
    State;
message(#{<<"type">> := <<"shutdown">>}, _) -> halt(0);
message(_, _) -> error(unexpected_message).

tool(Socket, Turn, Tool, Args) ->
    Request = maps:get(<<"request_id">>, Turn),
    send(Socket, <<"tool_request">>, #{<<"request_id">> => Request,
        <<"epoch">> => maps:get(<<"epoch">>, Turn), <<"tool">> => Tool, <<"args">> => Args,
        <<"idempotency_key">> => Tool}).
send(Socket, Type, Fields) ->
    ae_protocol:send(Socket, Fields#{<<"type">> => Type, <<"protocol_version">> => 1}).
