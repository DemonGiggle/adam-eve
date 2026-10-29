#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Root, Digest]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    application:ensure_all_started(crypto),
    ok = ae_artifacts:verify(Root, ae_artifacts:bootstrap(Root)),
    Available = try ae_artifacts:load(Root, list_to_binary(Digest)), true catch _:_ -> false end,
    io:put_chars([jsx:encode(#{<<"baseline_verified">> => true, <<"available">> => Available}), "\n"]).
