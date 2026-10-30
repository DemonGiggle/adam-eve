-module(ae_llm).
-export([complete/2, complete_budgeted/3, profile/1, select/2, public/1, models/2, defaults/1, authoring_supported/1]).

profile(#{selected_provider := Selected}) -> Selected;
profile(#{providers := Providers, default_provider := Name}) -> maps:get(Name, Providers);
profile(#{model := Model, url := Url}) ->
    %% Directly constructed development/test configs predate provider profiles.
    #{name => <<"ollama">>, adapter => ollama, model => Model, url => Url, thinking => <<>>,
      api_key_env => <<>>, api_key_path => <<>>, models => #{}}.

defaults(Config) ->
    P = profile(Config), #{<<"provider">> => maps:get(name, P), <<"model">> => maps:get(model, P),
        <<"thinking">> => maps:get(thinking, P)}.

authoring_supported(Config) ->
    try
        Name = maps:get(evolution_provider, Config, maps:get(name, profile(Config))),
        {ok, Selected} = select(#{<<"provider">> => Name}, Config),
        maps:get(adapter, profile(Selected)) =/= chatgpt
    catch _:_ -> false end.

select(Selection, Config) ->
    try
        Default = profile(Config), Name = maps:get(<<"provider">>, Selection, maps:get(name, Default)),
        Providers = maps:get(providers, Config, #{maps:get(name, Default) => Default}),
        P = maps:get(Name, Providers),
        Model = maps:get(<<"model">>, Selection, maps:get(model, P)),
        Thinking = maps:get(<<"thinking">>, Selection, maps:get(thinking, P)),
        true = is_binary(Model) andalso byte_size(Model) > 0 andalso byte_size(Model) =< 256,
        true = lists:member(Thinking, [<<>>, <<"auto">>, <<"off">>, <<"on">>, <<"none">>, <<"minimal">>,
            <<"low">>, <<"medium">>, <<"high">>, <<"xhigh">>, <<"max">>]),
        Metadata = maps:get(Model, maps:get(models, P, #{}), #{}),
        case maps:find(<<"thinking_levels">>, Metadata) of
            {ok, Levels} when Thinking =/= <<>>, Thinking =/= <<"auto">> -> true = lists:member(Thinking, Levels);
            _ -> ok end,
        Selected = P#{model := Model, thinking := Thinking},
        {ok, Config#{selected_provider => Selected, model := Model, url := maps:get(url, Selected)}}
    catch _:_ -> {error, invalid_provider_selection} end.

public(Config) ->
    P = profile(Config), maps:from_list([{atom_to_binary(K, utf8), value(V)} ||
        {K, V} <- maps:to_list(ae_provider_config:public(P))]).
value(V) when is_atom(V) -> atom_to_binary(V, utf8);
value(V) -> V.

complete(Messages, Config) ->
    P = profile(Config),
    case maps:get(adapter, P) of
        ollama -> ae_llm_ollama:complete(Messages, bind(P, Config));
        _ -> ae_llm_api:complete(Messages, Config#{selected_provider => P}, ordinary)
    end.
complete_budgeted(Messages, Config, Tokens) ->
    Name = maps:get(evolution_provider, Config, maps:get(name, profile(Config))),
    case select(#{<<"provider">> => Name}, maps:remove(selected_provider, Config)) of
        {ok, Selected} ->
            P = profile(Selected),
            case maps:get(adapter, P) of
                ollama -> ae_llm_ollama:complete_budgeted(Messages, bind(P, Selected), Tokens);
                _ -> ae_llm_api:complete(Messages, Selected, {budget, Tokens})
            end;
        Error -> Error
    end.
bind(P, Config) -> maps:merge(Config, P).

models(Name, Config) ->
    case select(#{<<"provider">> => Name}, Config) of
        {ok, Selected} -> ae_llm_api:models(profile(Selected), maps:get(llm_timeout, Config));
        Error -> Error
    end.
