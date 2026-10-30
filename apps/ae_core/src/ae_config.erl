-module(ae_config).
-include_lib("kernel/include/file.hrl").
-export([load/0]).

load() ->
    Root = case os:getenv("AE_DATA_ROOT") of
        false -> filename:join([required("HOME"), ".local", "share", "adam-eve"]);
        Value -> Value
    end,
    true = filename:pathtype(Root) =:= absolute,
    {ok, Info} = file:read_link_info(Root),
    %% The selected data root must have been provisioned by publish_seed.
    directory = Info#file_info.type,
    0 = Info#file_info.mode band 8#077,
    Providers = ae_provider_config:load(),
    LlmTimeout = integer_env("AE_LLM_TIMEOUT_MS", 120000, 100, 300000),
    maps:merge(maps:merge(isolation(), Providers), #{root => Root,
      llm_timeout => LlmTimeout, evolution_llm_timeout => evolution_llm_timeout(LlmTimeout),
      runtime_start_timeout => integer_env("AE_RUNTIME_START_TIMEOUT_MS", 5000, 100, 30000),
      max_tokens => integer_env("AE_LLM_MAX_TOKENS", 512, 1, 8192),
      context_turns => integer_env("AE_CONTEXT_TURNS", 8, 1, 8),
      max_llm_attempts => integer_env("AE_MAX_LLM_ATTEMPTS", 3, 1, 10),
      handoff_limits => handoff_limits(), candidate_builder => candidate_builder(), candidate_evaluator => candidate_evaluator(),
      retention_policy => retention_policy(),
      evolution_requested => os:getenv("AE_EVOLUTION_ENABLED") =:= "true", evolution_limits => evolution_limits()}).

evolution_llm_timeout(Default) ->
    try integer_env("AE_EVOLUTION_LLM_TIMEOUT_MS", Default, 100, 3600000)
    catch _:_ -> undefined end.

retention_policy() ->
    try
        Policy = jsx:decode(list_to_binary(required("AE_RETENTION_POLICY_JSON")), [return_maps, strict]),
        {ok, Policy} = ae_storage:validate_retention(Policy), Policy
    catch _:_ -> undefined end.

evolution_limits() ->
    try
        Limits = jsx:decode(list_to_binary(required("AE_EVOLUTION_LIMITS_JSON")), [return_maps, strict]),
        {ok, Limits} = ae_evolution_limits:validate(Limits), Limits
    catch _:_ -> undefined end.

candidate_evaluator() ->
    try
        Config = jsx:decode(list_to_binary(required("AE_EVAL_CONFIG_JSON")), [return_maps, strict]),
        {ok, Config} = ae_evaluator:validate_config(Config), Config
    catch _:_ -> undefined end.

candidate_builder() ->
    try
        Config = jsx:decode(list_to_binary(required("AE_BUILD_CONFIG_JSON")), [return_maps, strict]),
        {ok, Config} = ae_builder:validate_config(Config), Config
    catch _:_ -> undefined end.

isolation() ->
    %% `development` was the old trusted-host profile; retain its spelling as
    %% a host alias. Explicit sandbox requests must never silently fall back.
    true = lists:member(env("AE_RUNTIME_ISOLATION", "host"), ["host", "development"]),
    #{runtime_isolation => host}.

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
