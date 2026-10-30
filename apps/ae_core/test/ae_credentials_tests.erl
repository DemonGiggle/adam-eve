-module(ae_credentials_tests).
-include_lib("eunit/include/eunit.hrl").

private_files_and_header_injection_test() ->
    Root = filename:join("/tmp", "ae-credentials-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root), ok = file:change_mode(Root, 8#700),
    Key = list_to_binary(filename:join(Root, "key")), Link = list_to_binary(filename:join(Root, "link")),
    try
        ok = file:write_file(Key, <<"fixture-key\n">>),
        ok = file:change_mode(Key, 8#644),
        ?assertEqual({error, credential_file_invalid}, ae_credentials:read(Key)),
        ok = file:change_mode(Key, 8#600),
        ?assertEqual({ok, <<"fixture-key">>}, ae_credentials:resolve(<<>>, Key)),
        ok = file:make_symlink(Key, Link),
        ?assertEqual({error, credential_file_invalid}, ae_credentials:read(Link)),
        ok = file:write_file(Key, <<"fixture\r\ninjected: value">>),
        ?assertEqual({error, credential_invalid}, ae_credentials:resolve(<<>>, Key)),
        ?assertEqual({error, conflicting_credentials}, ae_credentials:resolve(<<"KEY">>, Key))
    after file:del_dir_r(Root) end.

profile_selection_never_exposes_credentials_test() ->
    P = ae_provider_config:normalize(<<"primary">>, #{<<"adapter">> => <<"openai">>, <<"model">> => <<"fixture">>,
        <<"api_key_env">> => <<"AE_FIXTURE_SECRET">>}),
    Config = #{providers => #{<<"primary">> => P}, default_provider => <<"primary">>, model => <<"fixture">>, url => maps:get(url, P)},
    ?assertEqual(false, maps:is_key(<<"api_key_env">>, ae_llm:public(Config))),
    ?assertEqual({error, invalid_provider_selection}, ae_llm:select(#{<<"provider">> => <<"unconfigured">>}, Config)),
    ?assertException(error, _, ae_provider_config:normalize(<<"bad">>, #{<<"adapter">> => <<"openai">>,
        <<"model">> => <<"fixture">>, <<"base_url">> => <<"http://192.0.2.1/v1">>})).
