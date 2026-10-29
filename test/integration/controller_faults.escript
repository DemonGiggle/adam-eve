#!/usr/bin/env escript
%%! +S 2:2 +A 2
-mode(compile).

main([Digest]) ->
    ok = code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
    ok = logger:remove_handler(default),
    ok = logger:add_handler(default, logger_std_h, #{config => #{type => standard_error}}),
    Config = ae_config:load(),
    application:load(ae_core), application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core),
    try
        non_existing = code:which(seed_agent),
        Base = ae_store:routing(),
        {ok, First} = ae_deployment:stage(list_to_binary(Digest)),
        Old = whereis(ae_deployment), Ref = monitor(process, Old), exit(Old, kill),
        receive {'DOWN', Ref, process, Old, _} -> ok after 5000 -> error(no_down) end,
        wait(fun() -> is_pid(whereis(ae_deployment)) andalso whereis(ae_deployment) =/= Old andalso
            ae_store:active_deployment() =:= undefined andalso
            length(supervisor:which_children(ae_runtime_sup)) =:= 1 end),
        Base = ae_store:routing(),
        #{<<"status">> := <<"rejected">>} = ae_store:deployment(maps:get(<<"deployment_id">>, First)),
        [_] = supervisor:which_children(ae_runtime_sup),
        %% A runner can die while the gateway is asking for its identity. This
        %% must fail the request without taking down the trusted router.
        Router = whereis(ae_router), Parent = self(),
        [{_, Runtime, _, _}] = supervisor:which_children(ae_runtime_sup),
        ok = sys:suspend(Runtime),
        spawn(fun() -> Parent ! {raced_turn, ae_router:turn(<<"runner-race">>, <<"race">>, <<"hello">>)} end),
        wait(fun() ->
            {messages, Messages} = process_info(Runtime, messages),
            lists:any(fun({'$gen_call', _, auth}) -> true; (_) -> false end, Messages)
        end),
        exit(Runtime, kill),
        receive {raced_turn, {error, runtime_unavailable}} -> ok after 5000 -> error(router_crashed) end,
        wait(fun() -> maps:get(<<"epoch">>, ae_store:routing()) > maps:get(<<"epoch">>, Base) end),
        Router = whereis(ae_router), NewBase = ae_store:routing(),
        {ok, Second} = ae_deployment:stage(list_to_binary(Digest)),
        spawn(fun() -> Parent ! {turn, ae_router:turn(<<"during-drain">>, <<"drain">>, <<"drain-pause">>)} end),
        wait(fun() -> lists:any(fun
            ({_, <<"tool_reserved">>, #{<<"request_id">> := <<"during-drain">>}}) -> true;
            (_) -> false end, ae_store:events()) end),
        spawn(fun() -> Parent ! {promotion, ae_deployment:approve(maps:get(<<"deployment_id">>, Second),
            maps:get(<<"approval_binding">>, Second))} end),
        wait(fun() -> maps:get(<<"admission">>, ae_store:routing()) =:= <<"closed">> end),
        {error, quiescing} = ae_router:turn(<<"not-admitted">>, <<"drain">>, <<"must wait">>),
        receive {turn, {ok, <<"g3:g2:reply:drain-pause">>}} -> ok after 10000 -> error(turn_not_drained) end,
        Promoted = receive {promotion, {ok, Route}} -> Route after 10000 -> error(not_promoted) end,
        true = maps:get(<<"epoch">>, Promoted) > maps:get(<<"epoch">>, NewBase),
        OldAuth = {maps:get(<<"slot">>, NewBase), maps:get(<<"runtime_instance_id">>, NewBase), maps:get(<<"epoch">>, NewBase)},
        {error, stale_runtime} = ae_tool_broker:request(OldAuth, <<"during-drain">>, #{}),
        [_] = [ok || {_, <<"assistant_reply">>, #{<<"request_id">> := <<"during-drain">>}} <- ae_store:events()],
        io:format("Controller process restart and in-flight quiescence passed~n")
    after application:stop(ae_core) end;
main(_) -> halt(64).

wait(Fun) -> wait(Fun, erlang:monotonic_time(millisecond) + 10000).
wait(Fun, Deadline) ->
    case Fun() of
        true -> ok;
        false ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 10 -> ok end, wait(Fun, Deadline)
    end.
