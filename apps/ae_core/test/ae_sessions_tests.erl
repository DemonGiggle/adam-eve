-module(ae_sessions_tests).
-include_lib("eunit/include/eunit.hrl").

settings_pin_and_topic_reset_survive_restart_test() ->
    Root = filename:join("/tmp", "ae-sessions-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Boot = ae_store:boot(#{<<"digest">> => <<"g1">>}), {ok, Route} = ae_store:activate(Boot, <<"fixture">>),
        Auth = {<<"adam">>, <<"fixture">>, maps:get(<<"epoch">>, Route)},
        One = ae_provider_config:normalize(<<"one">>, #{<<"adapter">> => <<"ollama">>, <<"model">> => <<"first">>}),
        Two = ae_provider_config:normalize(<<"two">>, #{<<"adapter">> => <<"ollama">>, <<"model">> => <<"second">>}),
        Config = #{default_provider => <<"one">>, providers => #{<<"one">> => One, <<"two">> => Two}},
        Catalog = ae_llm:catalog(Config), A = <<"tg:42:123:0">>, B = <<"tg:42:123:99">>,
        {ok, pending} = ae_store:begin_turn(Auth, <<"a1">>, A, <<"remember">>, Catalog),
        ?assertMatch(#{<<"provider">> := <<"one">>, <<"model">> := <<"first">>}, ae_store:session({turn, <<"a1">>})),
        {ok, _} = ae_store:finish_turn(Auth, <<"a1">>, <<"saved">>),
        {ok, _} = ae_settings:set(B, <<"provider">>, <<"two">>, Config),
        {ok, Settings} = ae_settings:get(A, Config),
        ?assertMatch(#{<<"effective">> := #{<<"name">> := <<"two">>, <<"model">> := <<"second">>}}, Settings),
        ?assertMatch(#{<<"model">> := <<"first">>}, ae_store:session({turn, <<"a1">>})),
        {ok, pending} = ae_store:begin_turn(Auth, <<"b1">>, B, <<"separate topic">>, Catalog),
        {ok, _} = ae_store:finish_turn(Auth, <<"b1">>, <<"topic saved">>),
        {ok, _} = ae_store:session({reset, A}),
        {ok, pending} = ae_store:begin_turn(Auth, <<"a2">>, A, <<"fresh">>, Catalog),
        ?assertEqual([#{<<"role">> => <<"user">>, <<"content">> => <<"fresh">>}], ae_store:context(<<"a2">>, 8)),
        ?assertEqual(2, length(ae_store:context(<<"b1">>, 8))),
        ?assertEqual(2, length(ae_store:context(<<"a1">>, 8))),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(Root),
        ?assertMatch(#{<<"provider">> := <<"two">>, <<"model">> := <<"second">>}, ae_store:session({turn, <<"a2">>})),
        {ok, Again} = ae_settings:get(A, Config), ?assertEqual(Settings, Again),
        ?assertEqual(<<"tg:42:123:">>, ae_sessions:scope(A))
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.
