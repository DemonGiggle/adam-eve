-module(ae_tool_broker_tests).
-include_lib("eunit/include/eunit.hrl").

denial_test() ->
    Root = filename:join("/tmp", "ae-broker-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Base = ae_store:boot(#{<<"digest">> => <<"seed">>}),
        {ok, _} = ae_store:activate(Base, <<"instance">>),
        Auth = {<<"adam">>, <<"instance">>, 1},
        {ok, pending} = ae_store:begin_turn(Auth, <<"r1">>, <<"s1">>, <<"hello">>),
        {ok, _} = ae_tool_broker:start_link(#{context_turns => 8}),
        Request = #{<<"protocol_version">> => 1, <<"type">> => <<"tool_request">>,
            <<"request_id">> => <<"r1">>, <<"epoch">> => 1, <<"tool">> => <<"memory_read">>,
            <<"args">> => #{}, <<"idempotency_key">> => <<"memory_read">>},
        ?assertMatch({ok, #{<<"messages">> := [_]}}, ae_tool_broker:request(Auth, <<"r1">>, Request)),
        Before = ae_store:last_seq(),
        ?assertEqual({error, denied}, ae_tool_broker:request(Auth, <<"r1">>, Request#{<<"tool">> := <<"shell">>})),
        ?assertEqual({error, denied}, ae_tool_broker:request(Auth, <<"invented">>, Request)),
        ?assertEqual({error, denied}, ae_tool_broker:request(Auth, <<"r1">>, Request#{<<"epoch">> := 2})),
        ?assertEqual({error, stale_runtime}, ae_tool_broker:request({<<"adam">>, <<"stale">>, 1}, <<"r1">>, Request)),
        ?assertEqual({error, context_mismatch}, ae_tool_broker:request(Auth, <<"r1">>,
            Request#{<<"tool">> := <<"llm">>, <<"idempotency_key">> := <<"llm">>,
                     <<"args">> := #{<<"messages">> => []}})),
        ?assertEqual(Before, ae_store:last_seq())
    after
        case whereis(ae_tool_broker) of undefined -> ok; B -> gen_server:stop(B) end,
        case whereis(ae_store) of undefined -> ok; S -> gen_server:stop(S) end,
        file:del_dir_r(Root)
    end.
