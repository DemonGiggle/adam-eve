#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Id]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")), logger:remove_handler(default),
    application:load(ae_core), Config = ae_config:load(), application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core),
    wait_ready(erlang:monotonic_time(millisecond) + 10000),
    #{<<"evolution_enabled">> := false} = ae_router:status(),
    {error, evolution_disabled} = ae_evolution:trigger(<<"disabled-after-restart">>, <<"must not run">>),
    {ok, <<"conversation still works">>} = ae_router:turn(<<"post-disable-restart">>, <<"test">>, <<"hello">>),
    ok = ae_evolution:set_enabled(true), #{<<"evolution_enabled">> := true} = ae_router:status(),
    {ok, Existing} = ae_evolution:trigger(<<"orchestrated-rollback">>, <<"Improve the greeting; preserve existing behavior.">>),
    true = maps:get(<<"id">>, Existing) =:= list_to_binary(Id), <<"rolled_back">> = maps:get(<<"status">>, Existing),
    {error, origin_conflict} = ae_evolution:trigger(<<"orchestrated-rollback">>, <<"changed objective">>),
    application:stop(ae_core), io:put_chars("Evolution disable/restart/re-enable and origin replay passed.\n").
wait_ready(Deadline) ->
    case ae_evolution:status() of
        #{<<"state">> := <<"recovering">>} -> true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 20 -> wait_ready(Deadline) end;
        _ -> ok end.
