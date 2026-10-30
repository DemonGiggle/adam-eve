-module(ae_native_controller_tests).
-include_lib("eunit/include/eunit.hrl").

controller_sources_do_not_launch_python_helpers_test() ->
    Paths = filelib:wildcard("apps/ae_core/src/*.erl"),
    ?assert(Paths =/= []),
    lists:foreach(fun(Path) ->
        {ok, Bytes} = file:read_file(Path),
        ?assertEqual(nomatch, binary:match(Bytes, <<"/usr/bin/python">>)),
        ?assertEqual(nomatch, binary:match(Bytes, <<".py\"">>))
    end, Paths).

explicit_removed_sandbox_is_not_silently_run_on_host_test() ->
    Root = filename:join("/tmp", "ae-host-config-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root), ok = file:change_mode(Root, 8#700),
    Names = ["HOME", "AE_DATA_ROOT", "AE_LLM_MODEL", "AE_CONFIG_FILE", "AE_PROVIDERS_JSON", "AE_LLM_PROVIDER", "AE_RUNTIME_ISOLATION"],
    Before = [{Name, os:getenv(Name)} || Name <- Names],
    try
        [os:unsetenv(Name) || Name <- Names],
        os:putenv("HOME", Root),
        os:putenv("AE_DATA_ROOT", Root), os:putenv("AE_LLM_MODEL", "fixture"),
        host = maps:get(runtime_isolation, ae_config:load()),
        os:putenv("AE_RUNTIME_ISOLATION", "development"),
        host = maps:get(runtime_isolation, ae_config:load()),
        os:putenv("AE_RUNTIME_ISOLATION", "bubblewrap"),
        ?assertError({badmatch, false}, ae_config:load())
    after
        lists:foreach(fun({Name, false}) -> os:unsetenv(Name); ({Name, Value}) -> os:putenv(Name, Value) end, Before),
        file:del_dir_r(Root)
    end.
