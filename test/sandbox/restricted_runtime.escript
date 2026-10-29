#!/usr/bin/env escript
%%! +S 2:2 +A 1
-mode(compile).
main([]) ->
    ok = code:add_pathsz(filelib:wildcard("_build/default/lib/*/ebin")),
    logger:remove_handler(default),
    Config = ae_config:load(), application:load(ae_core),
    application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core),
    try
        #{<<"runtime_isolation">> := <<"bubblewrap">>, <<"runtime_health">> := <<"ok">>,
          <<"routing">> := First, <<"os_pid">> := Pid} = ae_router:status(),
        Auth = auth(First),
        {ok, pending} = ae_store:begin_turn(Auth, <<"completed">>, <<"s">>, <<"remember">>),
        {ok, reserved} = ae_store:reserve_tool(Auth, <<"completed">>, <<"llm">>),
        {ok, _} = ae_store:finish_tool(Auth, <<"completed">>, <<"llm">>, #{<<"text">> => <<"retained">>}),
        {ok, _} = ae_store:finish_turn(Auth, <<"completed">>, <<"retained">>),
        {ok, pending} = ae_store:begin_turn(Auth, <<"unknown">>, <<"s">>, <<"unresolved">>),
        {ok, reserved} = ae_store:reserve_tool(Auth, <<"unknown">>, <<"llm">>),
        {ok, _} = ae_os:run(os:find_executable("kill"), ["-KILL", integer_to_list(Pid)], 5000),
        Timeout = maps:get(runtime_start_timeout, Config) + 15000,
        Recovered = wait(maps:get(<<"epoch">>, First), erlang:monotonic_time(millisecond) + Timeout),
        {error, stale_runtime} = ae_store:authorized(Auth),
        {ok, {completed, <<"retained">>}} = ae_store:begin_turn(auth(Recovered), <<"completed">>, <<"s">>, <<"remember">>),
        {error, tool_outcome_unknown} = ae_store:reserve_tool(auth(Recovered), <<"unknown">>, <<"llm">>),
        ok = ae_router:restart(),
        #{<<"runtime_health">> := <<"ok">>, <<"routing">> := Restarted} = ae_router:status(),
        true = maps:get(<<"epoch">>, Restarted) > maps:get(<<"epoch">>, Recovered),
        {error, tool_outcome_unknown} = ae_store:reserve_tool(auth(Restarted), <<"unknown">>, <<"llm">>),
        non_existing = code:which(seed_agent),
        io:put_chars("Restricted runtime recovery passed: fresh epochs, retained replies and unresolved effects\n")
    after application:stop(ae_core) end.
auth(Route) -> {maps:get(<<"slot">>, Route), maps:get(<<"runtime_instance_id">>, Route), maps:get(<<"epoch">>, Route)}.
wait(Epoch, Deadline) ->
    #{<<"routing">> := Route, <<"runtime_health">> := Health} = ae_router:status(),
    case maps:get(<<"epoch">>, Route) > Epoch andalso Health =:= <<"ok">> of
        true -> Route;
        false ->
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 50 -> ok end, wait(Epoch, Deadline)
    end.
