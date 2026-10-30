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
        "models" -> ae_llm:models(maps:get(default_provider, Config), Config)
    end,
    io:put_chars([jsx:encode(render(Result)), "\n"]).
render({ok, Value}) -> #{<<"ok">> => Value};
render({error, Reason}) -> #{<<"error">> => atom_to_binary(Reason, utf8)}.
