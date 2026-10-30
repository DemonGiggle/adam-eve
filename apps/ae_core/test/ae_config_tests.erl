-module(ae_config_tests).
-include_lib("eunit/include/eunit.hrl").

defaults_and_overrides_test() ->
    Home = filename:join("/tmp", "ae-config-" ++ integer_to_list(erlang:unique_integer([positive]))),
    DefaultRoot = filename:join([Home, ".local", "share", "adam-eve"]),
    OverrideRoot = filename:join(Home, "custom-identity"),
    Names = ["HOME", "AE_DATA_ROOT", "AE_LLM_TIMEOUT_MS", "AE_EVOLUTION_LLM_TIMEOUT_MS",
        "AE_LLM_MODEL", "AE_CONFIG_FILE", "AE_PROVIDERS_JSON", "AE_LLM_PROVIDER", "AE_RUNTIME_ISOLATION"],
    Before = [{Name, os:getenv(Name)} || Name <- Names],
    try
        [os:unsetenv(Name) || Name <- Names],
        os:putenv("HOME", Home), os:putenv("AE_LLM_MODEL", "fixture"),
        %% Loading a default must not create an unprovisioned identity.
        ?assertError({badmatch, {error, enoent}}, ae_config:load()),
        ?assertNot(filelib:is_dir(DefaultRoot)),
        ok = filelib:ensure_dir(filename:join(DefaultRoot, "placeholder")),
        ok = file:change_mode(DefaultRoot, 8#700),
        Config = ae_config:load(),
        ?assertEqual(DefaultRoot, maps:get(root, Config)),
        ?assertEqual(120000, maps:get(llm_timeout, Config)),
        ?assertEqual(120000, maps:get(evolution_llm_timeout, Config)),
        ok = file:make_dir(OverrideRoot), ok = file:change_mode(OverrideRoot, 8#700),
        os:putenv("AE_DATA_ROOT", OverrideRoot), os:putenv("AE_LLM_TIMEOUT_MS", "45000"),
        Override = ae_config:load(),
        ?assertEqual(OverrideRoot, maps:get(root, Override)),
        ?assertEqual(45000, maps:get(llm_timeout, Override)),
        ?assertEqual(45000, maps:get(evolution_llm_timeout, Override)),
        os:putenv("AE_LLM_TIMEOUT_MS", "0"),
        ?assertError({badmatch, false}, ae_config:load()),
        os:putenv("AE_LLM_TIMEOUT_MS", "45000"),
        ok = file:change_mode(OverrideRoot, 8#755),
        ?assertError({badmatch, _}, ae_config:load())
    after
        lists:foreach(fun({Name, false}) -> os:unsetenv(Name); ({Name, Value}) -> os:putenv(Name, Value) end, Before),
        file:del_dir_r(Home)
    end.
