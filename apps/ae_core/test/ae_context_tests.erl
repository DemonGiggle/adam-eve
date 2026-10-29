-module(ae_context_tests).
-include_lib("eunit/include/eunit.hrl").

escaped_history_budget_test() ->
    Root = filename:join("/tmp", "ae-context-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Base = ae_store:boot(#{<<"digest">> => <<"seed">>}),
        {ok, _} = ae_store:activate(Base, <<"instance">>),
        Auth = {<<"adam">>, <<"instance">>, 1},
        Text = binary:copy(<<0>>, 65536),
        {ok, pending} = ae_store:begin_turn(Auth, <<"old">>, <<"s1">>, Text),
        {ok, Text} = ae_store:finish_turn(Auth, <<"old">>, Text),
        {ok, pending} = ae_store:begin_turn(Auth, <<"current">>, <<"s1">>, Text),
        Full = ae_store:context(<<"current">>, 8),
        ?assert(byte_size(jsx:encode(Full)) > ae_protocol:max_bytes()),
        Bounded = ae_context:messages(<<"current">>, #{context_turns => 8}),
        ?assertEqual([#{<<"role">> => <<"user">>, <<"content">> => Text}], Bounded),
        ?assert(byte_size(jsx:encode(Bounded)) < ae_protocol:max_bytes() - 4096)
    after
        case whereis(ae_store) of undefined -> ok; S -> gen_server:stop(S) end,
        file:del_dir_r(Root)
    end.
