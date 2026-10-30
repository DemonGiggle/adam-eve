#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Marker]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")), logger:remove_handler(default),
    Config = ae_config:load(), application:load(ae_core), application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core), Parent = self(),
    spawn(fun() -> Parent ! {result, ae_router:turn(<<"cancel-me">>, <<"main">>, <<"pause">>)} end),
    wait(Marker, erlang:monotonic_time(millisecond) + 10000),
    Start = erlang:monotonic_time(millisecond), ok = ae_router:cancel_request(<<"cancel-me">>),
    receive {result, {error, _}} -> ok after 2000 -> error(cancellation_blocked) end,
    {ok, <<"reply:after">>} = ae_router:turn(<<"after">>, <<"main">>, <<"after">>),
    Elapsed = erlang:monotonic_time(millisecond) - Start, true = Elapsed < 2500,
    [] = [E || {_, <<"tool_result">>, #{<<"request_id">> := <<"cancel-me">>}} = E <- ae_store:events()],
    application:stop(ae_core), io:put_chars([jsx:encode(#{<<"cancelled">> => true, <<"elapsed_ms">> => Elapsed}), "\n"]).
wait(Marker, Deadline) ->
    case filelib:is_file(Marker) of true -> ok; false ->
        true = erlang:monotonic_time(millisecond) < Deadline,
        receive after 10 -> wait(Marker, Deadline) end end.
