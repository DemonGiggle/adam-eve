-module(ae_login).
-export([main/0]).
main() ->
    try
        {ok, _} = application:ensure_all_started(ssl), {ok, _} = application:ensure_all_started(inets),
        [Name] = init:get_plain_arguments(),
        Config = ae_provider_config:load(),
        P = maps:get(list_to_binary(Name), maps:get(providers, Config)), chatgpt = maps:get(adapter, P),
        {Url, Session} = ae_chatgpt:begin_login(P),
        io:format("Open this URL in your browser and approve sign-in:~n~s~nThe localhost redirect may not connect; paste its complete URL here.~n", [Url]),
        Callback = unicode:characters_to_binary(io:get_line("Callback URL: ")),
        case ae_chatgpt:finish_login(P, Session, Callback) of
            ok -> io:put_chars("ChatGPT credentials saved in the configured private file.\n"), halt(0);
            {error, Reason} -> io:format(standard_error, "Login failed: ~p~n", [Reason]), halt(1)
        end
    catch _:_ -> io:put_chars(standard_error, "Login requires a configured ChatGPT provider profile.\n"), halt(1) end.
