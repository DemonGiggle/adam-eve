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
    #{root => Root, model => Model, url => Url,
      llm_timeout => integer_env("AE_LLM_TIMEOUT_MS", 30000, 100, 300000),
      max_tokens => integer_env("AE_LLM_MAX_TOKENS", 512, 1, 8192),
      context_turns => integer_env("AE_CONTEXT_TURNS", 8, 1, 8),
      max_llm_attempts => integer_env("AE_MAX_LLM_ATTEMPTS", 3, 1, 10)}.

required(Name) ->
    case os:getenv(Name) of false -> error({required_configuration, Name}); "" -> error({required_configuration, Name}); V -> V end.
env(Name, Default) -> case os:getenv(Name) of false -> Default; V -> V end.
integer_env(Name, Default, Min, Max) ->
    Value = list_to_integer(env(Name, integer_to_list(Default))),
    true = Value >= Min andalso Value =< Max,
    Value.
