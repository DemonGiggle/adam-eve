-module(ae_provider_config_tests).
-include_lib("eunit/include/eunit.hrl").

config_file_discovery_test() ->
    Root = filename:join("/tmp", "ae-provider-config-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Default = filename:join([Root, ".config", "adam-eve", "config.json"]),
    Override = filename:join(Root, "override.json"),
    Names = ["HOME", "AE_CONFIG_FILE", "AE_PROVIDERS_JSON", "AE_LLM_PROVIDER",
        "AE_LLM_MODEL", "AE_LLM_URL", "AE_EVOLUTION_PROVIDER"],
    Before = [{Name, os:getenv(Name)} || Name <- Names],
    try
        [os:unsetenv(Name) || Name <- Names],
        os:putenv("HOME", Root),
        os:putenv("AE_LLM_MODEL", "environment-model"),
        ?assertEqual(<<"environment-model">>, maps:get(model, ae_provider_config:load())),
        ok = filelib:ensure_dir(Default),
        ok = file:write_file(Default, document(<<"default-model">>)),
        ?assertEqual(<<"default-model">>, maps:get(model, ae_provider_config:load())),
        ok = file:write_file(Override, document(<<"override-model">>)),
        os:putenv("AE_CONFIG_FILE", Override),
        ?assertEqual(<<"override-model">>, maps:get(model, ae_provider_config:load())),
        ok = file:delete(Override),
        ?assertError({badmatch, {error, enoent}}, ae_provider_config:load()),
        os:unsetenv("AE_CONFIG_FILE"),
        ok = file:write_file(Default, <<"invalid json">>),
        ?assertException(error, _, ae_provider_config:load())
    after
        lists:foreach(fun({Name, false}) -> os:unsetenv(Name); ({Name, Value}) -> os:putenv(Name, Value) end, Before),
        file:del_dir_r(Root)
    end.

document(Model) ->
    jsx:encode(#{<<"providers">> => #{<<"ollama">> => #{<<"model">> => Model}}}).
