-module(ae_settings).
-export([get/2, set/4, change/4, providers/1]).

get(Session, Config) ->
    Preferences = maps:without([<<"context_start">>], ae_store:session({get, Session})),
    case ae_llm:select(Preferences, Config) of
        {ok, Selected} -> {ok, #{<<"effective">> => ae_llm:public(Selected), <<"overrides">> => Preferences}};
        Error -> Error
    end.
set(Session, Field, Value, Config) ->
    Preferences = maps:without([<<"context_start">>], ae_store:session({get, Session})),
    case change(Preferences, Field, Value, Config) of
        {ok, Next} -> {ok, _} = ae_store:session({set, Session, Next}), get(Session, Config);
        Error -> Error
    end.
change(Preferences, Field, Value, Config) ->
    Next = case Field of
        <<"default">> -> #{};
        <<"provider">> -> #{<<"provider">> => Value};
        <<"model">> -> (maps:remove(<<"thinking">>, Preferences))#{<<"model">> => Value};
        <<"thinking">> -> case Value of
            <<"default">> -> maps:remove(<<"thinking">>, Preferences);
            _ -> Preferences#{<<"thinking">> => Value}
        end;
        _ -> invalid
    end,
    case Next of
        invalid -> {error, invalid_session_settings};
        _ -> case ae_llm:select(Next, Config) of
            {ok, _} -> {ok, Next};
            Error -> Error
        end
    end.
providers(Config) ->
    [ae_provider_config:public(P) || {_, P} <- lists:sort(maps:to_list(maps:get(providers, Config)))].
