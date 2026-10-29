-module(ae_protocol_tests).
-include_lib("eunit/include/eunit.hrl").

validation_test() ->
    Message = #{<<"protocol_version">> => 1, <<"type">> => <<"health_check">>,
                <<"request_id">> => <<"probe-1">>},
    ?assertEqual({ok, Message}, ae_protocol:decode(jsx:encode(Message))),
    ?assertEqual({error, unsupported_protocol},
                 ae_protocol:validate(Message#{<<"protocol_version">> := 2})),
    ?assertEqual({error, invalid_message},
                 ae_protocol:validate(Message#{<<"privilege">> => <<"shell">>})),
    ?assertEqual({error, invalid_message},
                 ae_protocol:validate(maps:remove(<<"request_id">>, Message))),
    ?assertMatch({error, _}, ae_protocol:decode(<<"{broken">>)),
    ?assertMatch({error, _}, ae_protocol:decode(<<"{/* comment */}">>)),
    ?assertEqual({error, oversized_message},
                 ae_protocol:decode(binary:copy(<<"x">>, ae_protocol:max_bytes() + 1))).

evolution_schema_test() ->
    Proposal = #{<<"protocol_version">> => 1, <<"type">> => <<"evolution_proposal">>,
        <<"job_id">> => <<"authorized-job">>, <<"proposal_id">> => <<"attempt-1">>,
        <<"epoch">> => 1, <<"base_artifact">> => <<"artifact">>, <<"base_source_revision">> => <<"revision">>,
        <<"patch">> => <<"bounded diff">>, <<"hypothesis">> => <<"improve">>,
        <<"expected_benefit">> => <<"improved recall">>, <<"risks">> => [], <<"requested_tests">> => [<<"replay">>]},
    ?assertEqual({ok, Proposal}, ae_protocol:decode(jsx:encode(Proposal))),
    ?assertEqual({error, invalid_message}, ae_protocol:validate(Proposal#{<<"epoch">> := 0})),
    ?assertEqual({error, invalid_message}, ae_protocol:validate(maps:remove(<<"job_id">>, Proposal))),
    ?assertEqual({error, invalid_message}, ae_protocol:validate(Proposal#{<<"patch">> := binary:copy(<<"x">>, 262145)})),
    ?assertEqual({error, invalid_message}, ae_protocol:validate(Proposal#{<<"requested_tests">> := lists:duplicate(33, <<"x">>)})).

framing_test() ->
    {ok, Listen} = gen_tcp:listen(0, ae_protocol:socket_options()),
    {ok, Port} = inet:port(Listen),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, ae_protocol:socket_options()),
    {ok, Server} = gen_tcp:accept(Listen),
    try
        Message = #{<<"protocol_version">> => 1, <<"type">> => <<"health_check">>,
                    <<"request_id">> => <<"a">>},
        ok = ae_protocol:send(Client, Message),
        ok = ae_protocol:send(Client, Message),
        ?assertEqual({ok, Message}, ae_protocol:recv(Server, 1000)),
        ?assertEqual({ok, Message}, ae_protocol:recv(Server, 1000)),
        ?assertEqual({error, timeout}, ae_protocol:recv(Server, 10))
    after gen_tcp:close(Client), gen_tcp:close(Server), gen_tcp:close(Listen) end.
