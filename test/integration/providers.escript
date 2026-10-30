#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Mode]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")), logger:remove_handler(default),
    {ok, _} = application:ensure_all_started(ssl), {ok, _} = application:ensure_all_started(inets),
    Config = (ae_provider_config:load())#{llm_timeout => 5000, max_tokens => 512},
    Messages = [#{<<"role">> => <<"system">>, <<"content">> => <<"Return JSON when requested.">>},
        #{<<"role">> => <<"user">>, <<"content">> => <<"hello">>}],
    Result = case Mode of
        "complete" -> ae_llm:complete(Messages, Config);
        "budget" -> ae_llm:complete_budgeted(Messages, Config, 8192);
        "models" -> ae_llm:models(maps:get(default_provider, Config), Config);
        "oauth" -> oauth(Config)
    end,
    io:put_chars([jsx:encode(render(Result)), "\n"]).
render({ok, Value}) -> #{<<"ok">> => Value};
render({error, Reason}) -> #{<<"error">> => atom_to_binary(Reason, utf8)}.
oauth(Config) ->
    P = ae_llm:profile(Config),
    {Url, Session} = ae_chatgpt:begin_login(P), true = byte_size(Url) > 100,
    {error, invalid_oauth_callback} = ae_chatgpt:finish_login(P, Session,
        <<"http://localhost:1455/auth/callback?code=test&state=wrong">>),
    Callback = <<"http://localhost:1455/auth/callback?code=approved-by-test&state=", (maps:get(state, Session))/binary>>,
    ok = ae_chatgpt:finish_login(P, Session, Callback),
    {ok, _} = ae_chatgpt:headers(P),
    {ok, #{<<"saved">> => true, <<"state_verified">> => true}}.
