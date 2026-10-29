-module(ae_store_tests).
-include_lib("eunit/include/eunit.hrl").

durability_and_fencing_test() ->
    Root = filename:join("/tmp", "ae-store-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, Pid} = ae_store:start_link(Root),
        Initial = ae_store:boot(#{<<"digest">> => <<"seed">>}),
        {ok, First} = ae_store:activate(Initial, <<"instance-1">>),
        Auth = auth(First),
        ?assertEqual({ok, pending}, ae_store:begin_turn(Auth, <<"r1">>, <<"s1">>, <<"remember me">>)),
        ?assertEqual({ok, reserved}, ae_store:reserve_tool(Auth, <<"r1">>, <<"llm">>)),
        Result = #{<<"text">> => <<"remembered">>},
        ?assertEqual({ok, Result}, ae_store:finish_tool(Auth, <<"r1">>, <<"llm">>, Result)),
        ?assertEqual({ok, <<"remembered">>}, ae_store:finish_turn(Auth, <<"r1">>, <<"remembered">>)),
        gen_server:stop(Pid),
        {ok, Pid2} = ae_store:start_link(Root),
        ?assertEqual(First, ae_store:routing()),
        {ok, Second} = ae_store:activate(First, <<"instance-2">>),
        ?assertEqual({error, stale_runtime}, ae_store:begin_turn(Auth, <<"r2">>, <<"s1">>, <<"hello">>)),
        ?assertEqual({error, stale_routing}, ae_store:activate(First, <<"instance-3">>)),
        Auth2 = auth(Second),
        ?assertEqual({ok, {completed, <<"remembered">>}},
            ae_store:begin_turn(Auth2, <<"r1">>, <<"s1">>, <<"remember me">>)),
        ?assertEqual({error, request_conflict},
            ae_store:begin_turn(Auth2, <<"r1">>, <<"other-session">>, <<"remember me">>)),
        ?assertEqual({ok, pending}, ae_store:begin_turn(Auth2, <<"r2">>, <<"s1">>, <<"what did I say?">>)),
        ?assertEqual([#{<<"role">> => <<"user">>, <<"content">> => <<"remember me">>},
                      #{<<"role">> => <<"assistant">>, <<"content">> => <<"remembered">>},
                      #{<<"role">> => <<"user">>, <<"content">> => <<"what did I say?">>}],
                     ae_store:context(<<"r2">>, 20)),
        ?assertEqual({error, pending_turn}, ae_store:begin_turn(Auth2, <<"r3">>, <<"s2">>, <<"new">>)),
        ?assertEqual({ok, reserved}, ae_store:reserve_tool(Auth2, <<"r2">>, <<"llm">>)),
        ?assertEqual({error, tool_outcome_unknown}, ae_store:reserve_tool(Auth2, <<"r2">>, <<"llm">>)),
        ?assertEqual(2, length([ok || {_, <<"user_message">>, _} <- ae_store:events()])),
        ?assertEqual(1, length([ok || {_, <<"assistant_reply">>, _} <- ae_store:events()])),
        gen_server:stop(Pid2)
    after
        case whereis(ae_store) of undefined -> ok; P -> gen_server:stop(P) end,
        file:del_dir_r(Root)
    end.

auth(R) -> {maps:get(<<"slot">>, R), maps:get(<<"runtime_instance_id">>, R), maps:get(<<"epoch">>, R)}.
