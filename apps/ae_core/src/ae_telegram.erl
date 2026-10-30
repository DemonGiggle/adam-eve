-module(ae_telegram).
-behaviour(gen_server).
-export([start_link/1, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
status() -> case whereis(?MODULE) of undefined -> #{<<"enabled">> => false}; _ -> gen_server:call(?MODULE, status) end.
init(Config) ->
    process_flag(trap_exit, true), C = ae_telegram_config:normalize(Config),
    Now = erlang:monotonic_time(millisecond),
    self() ! boot, {ok, #{config => C, bot => undefined, poll => undefined, work => undefined, command => undefined,
        delivery => undefined, poll_after => Now, work_after => Now, delivery_after => Now, poll_delay => 1000, delivery_delay => 1000}}.
handle_call(status, _, S) -> {reply, #{<<"enabled">> => true, <<"connected">> => maps:get(bot, S) =/= undefined}, S};
handle_call(_, _, S) -> {reply, {error, unsupported}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(boot, #{bot := undefined, config := C} = S) ->
    case ae_telegram_api:call(C, <<"getMe">>, #{}) of
        {ok, #{<<"id">> := BotId, <<"username">> := Username} = Bot} when is_integer(BotId), BotId > 0, BotId < (1 bsl 63), is_binary(Username), byte_size(Username) > 0 ->
            ok = ae_store:telegram({recover, BotId}),
            spawn(fun() -> ae_telegram_api:call(C, <<"setMyCommands">>, #{<<"commands">> => ae_telegram_api:commands()}) end),
            self() ! tick, {noreply, S#{bot := Bot}};
        _ -> erlang:send_after(5000, self(), boot), {noreply, S}
    end;
handle_info(tick, #{bot := undefined} = S) -> {noreply, S};
handle_info(tick, S) ->
    Next = case {ae_store:recovery(), ae_store:routing()} of
        {#{<<"pending">> := true}, _} -> S;
        {_, #{<<"admission">> := <<"closed">>}} -> S;
        _ -> start_delivery(start_command(start_work(start_poll(S))))
    end,
    erlang:send_after(250, self(), tick), {noreply, Next};
handle_info({done, poll, Ref, Result}, #{poll := Ref, bot := Bot, config := C} = S) ->
    BotId = maps:get(<<"id">>, Bot),
    case Result of
        {ok, Updates} when is_list(Updates), length(Updates) =< 100 ->
            try
                Ids = [maps:get(<<"update_id">>, U) || U <- Updates],
                true = lists:all(fun(I) -> is_integer(I) andalso I >= 0 andalso I < (1 bsl 63) - 1 end, Ids),
                Entries = [E || U <- Updates, {ok, E} <- [ae_telegram_normalize:normalize(U, Bot, C)]],
                case Ids of [] -> ok; _ -> ok = ae_store:telegram({ingest, BotId, lists:max(Ids) + 1, Entries}) end
            catch _:_ -> ok end;
        _ -> ok
    end,
    {Delay, NextDelay} = backoff(Result, maps:get(poll_delay, S)),
    {noreply, S#{poll := undefined, poll_after := erlang:monotonic_time(millisecond) + Delay, poll_delay := NextDelay}};
handle_info({done, work, Ref, {Id, <<"deferred">>, _}}, #{work := Ref, bot := Bot} = S) ->
    ok = ae_store:telegram({defer, maps:get(<<"id">>, Bot), Id}),
    {noreply, S#{work := undefined, work_after := erlang:monotonic_time(millisecond) + 1000}};
handle_info({done, work, Ref, {Id, Status, Text}}, #{work := Ref, bot := Bot} = S) ->
    ok = ae_store:telegram({finish, maps:get(<<"id">>, Bot), Id, Status, Text}), {noreply, S#{work := undefined}};
handle_info({done, command, Ref, {Id, Status, Text}}, #{command := Ref, bot := Bot} = S) ->
    ok = ae_store:telegram({finish, maps:get(<<"id">>, Bot), Id, Status, Text}), {noreply, S#{command := undefined}};
handle_info({done, delivery, Ref, {Id, Result}}, #{delivery := Ref} = S) ->
    Status = case Result of {ok, _} -> <<"delivered">>; {error, {telegram, Code, _}} when Code >= 400, Code < 500, Code =/= 429 -> <<"failed">>; _ -> <<"pending">> end,
    ok = ae_store:telegram({outbox, Id, Status}),
    {Delay, NextDelay} = backoff(Result, maps:get(delivery_delay, S)),
    {noreply, S#{delivery := undefined, delivery_after := erlang:monotonic_time(millisecond) + Delay, delivery_delay := NextDelay}};
handle_info(_, S) -> {noreply, S}.

start_poll(#{poll := undefined, bot := #{<<"id">> := Bot}, config := C, poll_after := After} = S) ->
    Capacity = maps:get(capacity, C) - ae_store:telegram({count, Bot}),
    case Capacity > 0 andalso erlang:monotonic_time(millisecond) >= After of
        true ->
            Offset = ae_store:telegram({offset, Bot}),
            spawn_task(poll, fun() -> ae_telegram_api:call(C, <<"getUpdates">>, #{<<"offset">> => Offset,
                <<"limit">> => min(32, Capacity), <<"timeout">> => maps:get(poll_seconds, C),
                <<"allowed_updates">> => [<<"message">>]}) end, S);
        false -> S
    end;
start_poll(S) -> S.
start_work(#{work := undefined, bot := #{<<"id">> := Bot}, config := C, work_after := After} = S) ->
    Next = case erlang:monotonic_time(millisecond) >= After of
        true -> ae_store:telegram({next, Bot, <<"turn">>}); false -> undefined end,
    case Next of
        undefined -> S;
        {Id, E} ->
            case ae_store:telegram({earlier, Bot, <<"command">>, Id, maps:get(<<"session_id">>, E)}) of
                true -> S;
                false -> ok = ae_store:telegram({claim, Bot, Id}),
                    spawn_task(work, fun() -> try process(Bot, Id, E, C) catch _:_ -> {Id, <<"blocked">>, <<"Request failed. Use /retry or /cancel.">>} end end, S)
            end
    end;
start_work(S) -> S.
start_command(#{command := undefined, bot := #{<<"id">> := Bot}, config := C} = S) ->
    case ae_store:telegram({next, Bot, <<"command">>}) of
        undefined -> S;
        {Id, E} ->
            Command = maps:get(<<"command">>, E),
            Preempt = Command =:= <<"/cancel">> orelse Command =:= <<"/new">>,
            Earlier = ae_store:telegram({earlier, Bot, <<"turn">>, Id, maps:get(<<"session_id">>, E)}),
            case Earlier andalso not Preempt of
                true -> start_interrupt(ae_store:telegram({next_interrupt, Bot}), Bot, C, S);
                false -> start_interrupt({Id, E}, Bot, C, S)
            end
    end;
start_command(S) -> S.
start_interrupt(undefined, _, _, S) -> S;
start_interrupt({Id, E}, Bot, C, S) ->
    ok = ae_store:telegram({claim, Bot, Id}),
    spawn_task(command, fun() -> try process(Bot, Id, E, C) catch _:_ -> {Id, <<"done">>, <<"Command failed.">>} end end, S).
start_delivery(#{delivery := undefined, bot := #{<<"id">> := Bot}, config := C, delivery_after := After} = S) ->
    Next = case erlang:monotonic_time(millisecond) >= After of true -> ae_store:telegram({next_outbox, Bot}); false -> undefined end,
    case Next of
        undefined -> S;
        {Id, #{<<"route">> := Route} = Message} ->
            case ae_telegram_normalize:authorized(Route, C) of
                false -> ok = ae_store:telegram({outbox, Id, <<"failed">>}), S;
                true -> case ae_store:telegram({outbox, Id, <<"sending">>}) of
                    ok -> spawn_task(delivery, fun() -> {Id, try ae_telegram_api:send(C, Route, Message) catch _:_ -> {error, worker_failed} end} end, S);
                    _ -> S end
            end
    end;
start_delivery(S) -> S.
spawn_task(Kind, Fun, State) ->
    Parent = self(), Ref = make_ref(),
    spawn_link(fun() -> Result = try Fun() catch _:_ -> {error, worker_failed} end, Parent ! {done, Kind, Ref, Result} end),
    State#{Kind := Ref}.

process(Bot, Id, E, C) ->
    case ae_telegram_normalize:authorized(E, C) of
        false -> {Id, <<"done">>, <<>>};
        true -> case maps:get(<<"kind">>, E) of
            <<"turn">> ->
                _ = ae_telegram_api:typing(C, E),
                case maps:get(<<"photo_file_id">>, E, null) of
                    null -> turn(Id, E);
                    undefined -> turn(Id, E);
                    FileId ->
                        Images = case maps:find(<<"images">>, E) of
                            {ok, Existing} -> {ok, Existing}; error -> ae_telegram_api:photo(C, FileId) end,
                        case Images of
                            {ok, Media} -> case ae_store:telegram({images, Bot, Id, Media}) of
                                ok -> turn(Id, E); _ -> {Id, <<"done">>, <<>>} end;
                            _ -> {Id, <<"done">>, <<"Photo unavailable or larger than 2 MiB.">>}
                        end
                end;
            _ -> {Id, <<"done">>, command(Bot, E, C)}
        end
    end.
turn(Id, E) ->
    case ae_router:turn(maps:get(<<"request_id">>, E), maps:get(<<"session_id">>, E), maps:get(<<"text">>, E)) of
        {ok, Text} -> {Id, <<"done">>, Text};
        {error, Reason} when Reason =:= pending_turn; Reason =:= busy; Reason =:= quiescing -> {Id, <<"deferred">>, <<>>};
        {error, _} -> {Id, <<"blocked">>, <<"The request did not complete. Use /retry to retry or /cancel to discard it.">>}
    end.
command(Bot, #{<<"command">> := Command, <<"argument">> := Arg, <<"session_id">> := Session, <<"update_id">> := Id} = E, C) ->
    Config = maps:get(controller, C),
    case Command of
        <<"/help">> -> help(); <<"/start">> -> help();
        <<"/status">> -> S = ae_router:status(), R = maps:get(<<"routing">>, S),
            jsx:encode(#{<<"runtime_health">> => maps:get(<<"runtime_health">>, S),
                <<"slot">> => maps:get(<<"slot">>, R), <<"epoch">> => maps:get(<<"epoch">>, R),
                <<"evolution_enabled">> => maps:get(<<"evolution_enabled">>, S)});
        <<"/providers">> -> jsx:encode(ae_settings:providers(Config));
        <<"/settings">> when Arg =:= <<"default">> -> settings(Bot, Id, Session, <<"default">>, <<>>, Config);
        <<"/settings">> -> show_settings(Session, Config);
        <<"/provider">> when Arg =:= <<>> -> jsx:encode(ae_settings:providers(Config));
        <<"/provider">> -> settings(Bot, Id, Session, <<"provider">>, Arg, Config);
        <<"/model">> when Arg =:= <<>> -> show_settings(Session, Config);
        <<"/model">> -> settings(Bot, Id, Session, <<"model">>, Arg, Config);
        <<"/think">> when Arg =:= <<>> -> show_settings(Session, Config);
        <<"/think">> -> settings(Bot, Id, Session, <<"thinking">>, Arg, Config);
        <<"/models">> ->
            {ok, #{<<"effective">> := #{<<"name">> := Name}}} = ae_settings:get(Session, Config),
            case ae_llm:models(Name, Config) of {ok, Models} -> jsx:encode(lists:sublist(Models, 64)); _ -> <<"Model list unavailable.">> end;
        <<"/new">> -> cancel_topic(Bot, Id, Session, true);
        <<"/retry">> -> ok = ae_store:telegram({retry_topic, Bot, Id, Session}), <<>>;
        <<"/cancel">> -> cancel_topic(Bot, Id, Session, false);
        <<"/restart">> -> case ae_telegram_normalize:admin(E, C) of true ->
            case ae_router:restart() of ok -> <<"Agent restarted.">>; _ -> <<"Agent is busy.">> end;
            false -> <<"Admin permission required.">> end;
        <<"/memory">> -> case ae_store:memory({scoped, ae_sessions:scope(Session), null, 0, 32}) of
            {ok, Snapshot} -> jsx:encode(Snapshot); _ -> <<"Memory unavailable.">> end;
        <<"/forget">> -> ok = ae_store:telegram({forget, Bot, Id, Session}), <<>>;
        _ -> <<"Unsupported command.">>
    end.
settings(Bot, Id, Session, Field, Value, Config) ->
    ok = ae_store:telegram({settings, Bot, Id, Session, Field, Value, Config}), <<>>.
cancel_topic(Bot, Id, Session, Reset) ->
    {ok, Requests} = ae_store:telegram({cancel_topic, Bot, Id, Session, Reset}),
    lists:foreach(fun ae_tool_broker:cancel_request/1, Requests), <<>>.
show_settings(Session, Config) ->
    case ae_settings:get(Session, Config) of {ok, V} -> jsx:encode(V); _ -> <<"Provider unavailable.">> end.
help() -> <<"/status /providers /provider /models /model /think /settings /new /cancel /retry /memory /forget /restart">>.
backoff({ok, _}, _) -> {0, 1000};
backoff({error, {telegram, _, Retry}}, Delay) when Retry > 0 -> {Retry * 1000, min(30000, Delay * 2)};
backoff(_, Delay) -> {Delay, min(30000, Delay * 2)}.
