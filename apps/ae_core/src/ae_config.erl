-module(ae_config).
-include_lib("kernel/include/file.hrl").
-export([load/0]).

load() ->
    Root = required("AE_DATA_ROOT"),
    true = filename:pathtype(Root) =:= absolute,
    {ok, Info} = file:read_link_info(Root),
    %% The data root must have been provisioned by publish_seed, never guessed.
    directory = Info#file_info.type,
    0 = Info#file_info.mode band 8#077,
    Model = list_to_binary(required("AE_LLM_MODEL")),
    Url = env("AE_LLM_URL", "http://127.0.0.1:11434/api/chat"),
    #{scheme := "http", host := Host} = uri_string:parse(Url),
    true = lists:member(Host, ["127.0.0.1", "localhost", "::1"]),
    maps:merge(isolation(), #{root => Root, model => Model, url => Url,
      llm_timeout => integer_env("AE_LLM_TIMEOUT_MS", 30000, 100, 300000),
      runtime_start_timeout => integer_env("AE_RUNTIME_START_TIMEOUT_MS", 5000, 100, 30000),
      max_tokens => integer_env("AE_LLM_MAX_TOKENS", 512, 1, 8192),
      context_turns => integer_env("AE_CONTEXT_TURNS", 8, 1, 8),
      max_llm_attempts => integer_env("AE_MAX_LLM_ATTEMPTS", 3, 1, 10),
      handoff_limits => handoff_limits(), candidate_builder => candidate_builder()}).

candidate_builder() ->
    try
        Config = jsx:decode(list_to_binary(required("AE_BUILD_CONFIG_JSON")), [return_maps, strict]),
        {ok, Config} = ae_builder:validate_config(Config), Config
    catch _:_ -> undefined end.

isolation() ->
    case env("AE_RUNTIME_ISOLATION", "development") of
        "development" -> #{runtime_isolation => development};
        "bubblewrap" ->
            CgroupRoot = required("AE_CGROUP_ROOT"),
            true = filename:pathtype(CgroupRoot) =:= absolute,
            Limits = jsx:decode(list_to_binary(required("AE_SANDBOX_LIMITS_JSON")), [return_maps, strict]),
            Keys = [<<"memory_bytes">>, <<"pids">>, <<"cpu_percent">>, <<"cpu_seconds">>,
                <<"address_space_bytes">>, <<"file_bytes">>, <<"open_files">>, <<"output_bytes">>, <<"wall_ms">>],
            true = lists:sort(maps:keys(Limits)) =:= lists:sort(Keys),
            true = lists:all(fun(V) -> is_integer(V) andalso V > 0 andalso V < (1 bsl 63) end, maps:values(Limits)),
            #{runtime_isolation => bubblewrap, sandbox_cgroup_root => CgroupRoot, sandbox_limits => Limits}
    end.

handoff_limits() ->
    try
        maps:from_list([{Key, list_to_integer(required(Name))} || {Key, Name} <-
            [{<<"approval_ttl_ms">>, "AE_APPROVAL_TTL_MS"}, {<<"observe_ms">>, "AE_OBSERVE_MS"},
             {<<"health_interval_ms">>, "AE_HEALTH_INTERVAL_MS"}, {<<"quiesce_ms">>, "AE_QUIESCE_TIMEOUT_MS"}]])
    of
        Limits ->
            true = lists:all(fun(V) -> V > 0 andalso V =< 300000 end, maps:values(Limits)), Limits
    catch _:_ -> undefined end.

required(Name) ->
    case os:getenv(Name) of false -> error({required_configuration, Name}); "" -> error({required_configuration, Name}); V -> V end.
env(Name, Default) -> case os:getenv(Name) of false -> Default; V -> V end.
integer_env(Name, Default, Min, Max) ->
    Value = list_to_integer(env(Name, integer_to_list(Default))),
    true = Value >= Min andalso Value =< Max,
    Value.
