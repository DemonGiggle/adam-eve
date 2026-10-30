-module(ae_provider_config).
-export([load/0, normalize/2, public/1]).

load() ->
    Document = document(),
    Profiles = case os:getenv("AE_PROVIDERS_JSON") of
        false -> maps:get(<<"providers">>, Document, #{});
        Value -> jsx:decode(list_to_binary(Value), [return_maps, strict])
    end,
    Default = env("AE_LLM_PROVIDER", maps:get(<<"default_provider">>, Document, <<"ollama">>)),
    Raw = case map_size(Profiles) of
        0 -> #{Default => #{<<"adapter">> => Default, <<"model">> => env("AE_LLM_MODEL", <<>>),
            <<"base_url">> => env("AE_LLM_URL", <<>>)}};
        _ -> Profiles
    end,
    true = map_size(Raw) > 0 andalso map_size(Raw) =< 32,
    Providers = maps:map(fun normalize/2, Raw),
    Selected = maps:get(Default, Providers),
    #{providers => Providers, default_provider => Default,
        model => maps:get(model, Selected), url => maps:get(url, Selected),
        telegram_config => maps:get(<<"telegram">>, Document, #{}),
        evolution_provider => env("AE_EVOLUTION_PROVIDER", maps:get(<<"evolution_provider">>, Document, Default))}.

document() ->
    case os:getenv("AE_CONFIG_FILE") of
        false ->
            case os:getenv("HOME") of
                false -> #{};
                Home -> read_document(filename:join([Home, ".config", "adam-eve", "config.json"]), true)
            end;
        Path -> read_document(Path, false)
    end.

read_document(Path, Optional) ->
    case file:read_file(Path) of
        {error, enoent} when Optional -> #{};
        Result ->
            {ok, Data} = Result,
            true = byte_size(Data) =< 1048576,
            jsx:decode(Data, [return_maps, strict])
    end.

normalize(Name, Raw) ->
    true = text(Name, 64) andalso is_map(Raw),
    Adapter = adapter(maps:get(<<"adapter">>, Raw, Name)),
    Model = maps:get(<<"model">>, Raw), true = text(Model, 256),
    Base0 = maps:get(<<"base_url">>, Raw, <<>>),
    Base = binary_to_list(case Base0 of <<>> -> base(Adapter); _ -> Base0 end),
    Parsed = ae_http:url(Base), true = not maps:is_key(query, Parsed),
    Path = maps:get(<<"api_key_path">>, Raw, <<>>),
    Env = maps:get(<<"api_key_env">>, Raw, case Path of <<>> -> key_env(Adapter); _ -> <<>> end),
    true = is_binary(Env) andalso is_binary(Path),
    true = Env =:= <<>> orelse Path =:= <<>>,
    case {Env, Path, maps:get(scheme, Parsed)} of
        {<<>>, <<>>, _} -> ok;
        {_, _, "https"} -> ok;
        _ -> true = lists:member(maps:get(host, Parsed), ["127.0.0.1", "localhost", "::1"])
    end,
    Thinking = maps:get(<<"thinking">>, Raw, <<>>), true = valid_thinking(Thinking),
    Wire = wire(maps:get(<<"wire">>, Raw, default_wire(Adapter))),
    Url = case Adapter of
        ollama -> suffix(Base, "/api/chat");
        _ -> string:trim(Base, trailing, "/")
    end,
    Models = maps:get(<<"models">>, Raw, #{}), true = is_map(Models) andalso map_size(Models) =< 1024,
    #{name => Name, adapter => Adapter, model => Model, url => Url, thinking => Thinking,
        api_key_env => Env, api_key_path => Path, wire => Wire, models => Models,
        model_routes => maps:get(<<"model_routes">>, Raw, #{}),
        session_id => uuid()}.

public(Profile) -> maps:with([name, adapter, model, thinking, wire], Profile).
adapter(<<"ollama">>) -> ollama;
adapter(<<"openai">>) -> openai;
adapter(<<"opencode-go">>) -> opencode_go;
adapter(<<"anthropic">>) -> anthropic.
wire(<<"chat_completions">>) -> chat_completions;
wire(<<"responses">>) -> responses;
wire(<<"messages">>) -> messages.
default_wire(ollama) -> <<"chat_completions">>;
default_wire(anthropic) -> <<"messages">>;
default_wire(_) -> <<"responses">>.
base(ollama) -> <<"http://127.0.0.1:11434">>;
base(openai) -> <<"https://api.openai.com/v1">>;
base(opencode_go) -> <<"https://opencode.ai/inference/go/openai/v1">>;
base(anthropic) -> <<"https://api.anthropic.com/v1">>.
key_env(openai) -> <<"OPENAI_API_KEY">>;
key_env(opencode_go) -> <<"OPENCODE_GO_API_KEY">>;
key_env(anthropic) -> <<"ANTHROPIC_API_KEY">>;
key_env(_) -> <<>>.
suffix(Base, Ending) -> case lists:suffix(Ending, Base) of true -> Base; false -> string:trim(Base, trailing, "/") ++ Ending end.
env(Name, Default) -> case os:getenv(Name) of false -> Default; Value -> list_to_binary(Value) end.
text(Value, Max) -> is_binary(Value) andalso byte_size(Value) > 0 andalso byte_size(Value) =< Max.
valid_thinking(Level) -> lists:member(Level, [<<>>, <<"auto">>, <<"off">>, <<"on">>, <<"none">>, <<"minimal">>,
    <<"low">>, <<"medium">>, <<"high">>, <<"xhigh">>, <<"max">>]).
uuid() ->
    <<A:48, _:4, B:12, _:2, C:62>> = crypto:strong_rand_bytes(16),
    Hex = binary:encode_hex(<<A:48, 4:4, B:12, 2:2, C:62>>),
    <<P1:8/binary, P2:4/binary, P3:4/binary, P4:4/binary, P5:12/binary>> = Hex,
    <<P1/binary, "-", P2/binary, "-", P3/binary, "-", P4/binary, "-", P5/binary>>.
