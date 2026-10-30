-module(ae_tool_broker).
-behaviour(gen_server).
-export([start_link/1, request/3, request_evolution/3, cancel_request/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
request(Auth, Request, Message) -> gen_server:call(?MODULE, {tool, Auth, Request, Message}, 310000).
request_evolution(Auth, Id, Message) ->
    Timeout = case ae_store:evolution({get, Id}) of
        #{<<"deadline">> := Deadline} -> max(10000, Deadline - erlang:system_time(millisecond) + 10000);
        _ -> 10000 end,
    gen_server:call(?MODULE, {evolution_tool, Auth, Id, Message}, Timeout).
cancel_request(Request) -> gen_server:call(?MODULE, {cancel_request, Request}, 10000).
init(Config) -> process_flag(trap_exit, true), {ok, #{config => Config, tasks => #{}}}.
handle_call({evolution_tool, Auth, Job, Message}, From, #{config := Config} = State) ->
    start_task(Job, From, fun() -> case ae_store:authorized(Auth) of
        ok -> ae_authoring_broker:request(Auth, Job, Message, Config); Error -> Error end end, State);
handle_call({tool, Auth, Request, Message}, From, #{config := Config} = State) ->
    start_task(Request, From, fun() -> case ae_store:authorized(Auth) of
        ok -> authorize(Auth, Request, Message, Config); Error -> Error end end, State);
handle_call({cancel_request, Request}, _, #{tasks := Tasks} = State) ->
    Matching = [Ref || {Ref, #{request := Id}} <- maps:to_list(Tasks), Id =:= Request],
    Next = lists:foldl(fun(Ref, Acc) -> stop_task(Ref, {ok, #{<<"error">> => <<"cancelled">>}}, Acc) end, State, Matching),
    {reply, ok, Next};
handle_call(_, _, State) -> {reply, {error, denied}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info({http_request, Ref, Id}, #{tasks := Tasks} = State) ->
    case maps:find(Ref, Tasks) of
        {ok, T} -> {noreply, State#{tasks := Tasks#{Ref := T#{http := [Id | maps:get(http, T)]}}}};
        error -> httpc:cancel_request(Id), {noreply, State}
    end;
handle_info({tool_finished, Ref, Reply}, #{tasks := Tasks} = State) ->
    case maps:find(Ref, Tasks) of
        {ok, T} ->
            gen_server:reply(maps:get(from, T), Reply), cleanup(T),
            {noreply, State#{tasks := maps:remove(Ref, Tasks)}};
        error -> {noreply, State}
    end;
handle_info({'DOWN', Monitor, process, _, _}, #{tasks := Tasks} = State) ->
    Refs = [Ref || {Ref, T} <- maps:to_list(Tasks),
        maps:get(worker_monitor, T) =:= Monitor orelse maps:get(caller_monitor, T) =:= Monitor],
    Next = lists:foldl(fun(Ref, Acc) -> stop_task(Ref, {error, broker_worker_lost}, Acc) end, State, Refs),
    {noreply, Next};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{tasks := Tasks}) ->
    maps:foreach(fun(_, T) -> cleanup(T), exit(maps:get(pid, T), kill) end, Tasks), ok.

start_task(Request, {Caller, _} = From, Fun, #{tasks := Tasks} = State) ->
    Parent = self(), Ref = make_ref(),
    {Pid, Monitor} = spawn_opt(fun() ->
        put(ae_http_owner, {Parent, Ref}),
        Reply = try Fun() catch _:_ -> {error, broker_request_failed} end,
        Parent ! {tool_finished, Ref, Reply}
    end, [link, monitor]),
    T = #{request => Request, from => From, pid => Pid, worker_monitor => Monitor,
        caller_monitor => monitor(process, Caller), http => []},
    {noreply, State#{tasks := Tasks#{Ref => T}}}.
stop_task(Ref, Reply, #{tasks := Tasks} = State) ->
    T = maps:get(Ref, Tasks), cleanup(T), exit(maps:get(pid, T), kill), gen_server:reply(maps:get(from, T), Reply),
    State#{tasks := maps:remove(Ref, Tasks)}.
cleanup(T) ->
    demonitor(maps:get(worker_monitor, T), [flush]), demonitor(maps:get(caller_monitor, T), [flush]),
    unlink(maps:get(pid, T)), [httpc:cancel_request(Id) || Id <- maps:get(http, T)], ok.

authorize({_, _, Epoch}, Request,
          #{<<"request_id">> := Request, <<"epoch">> := Epoch,
            <<"tool">> := <<"memory_read">>, <<"args">> := Args,
            <<"idempotency_key">> := <<"memory_read">>}, Config) when map_size(Args) =:= 0 ->
    {ok, #{<<"messages">> => ae_context:messages(Request, Config)}};
authorize({_, _, Epoch} = Auth, Request,
          #{<<"request_id">> := Request, <<"epoch">> := Epoch, <<"tool">> := <<"llm">>,
            <<"args">> := #{<<"messages">> := Messages} = Args,
            <<"idempotency_key">> := <<"llm">>}, Config) when map_size(Args) =:= 1 ->
    case ae_context:messages(Request, Config) of
        Messages ->
            case ae_store:reserve_tool(Auth, Request, <<"llm">>, maps:get(max_llm_attempts, Config)) of
                {ok, reserved} ->
                    Result = case ae_llm:select(ae_store:session({turn, Request}), Config) of
                      {ok, Selected} -> case ae_llm:complete(ae_media:attach(Messages, ae_store:telegram({media, Request})), Selected) of
                        {ok, Value} -> Value;
                        {error, Reason} -> #{<<"error">> => atom_to_binary(Reason, utf8)}
                      end;
                      {error, Reason} -> #{<<"error">> => atom_to_binary(Reason, utf8)} end,
                    ae_store:finish_tool(Auth, Request, <<"llm">>, Result);
                {ok, {completed, Result}} -> {ok, Result};
                {error, Reason} -> {ok, #{<<"error">> => atom_to_binary(Reason, utf8)}}
            end;
        _ -> {error, context_mismatch}
    end;
authorize(_, _, _, _) -> {error, denied}.
