#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Root, "probe", Digest]) ->
    setup(),
    ok = ae_artifacts:verify(Root, ae_artifacts:bootstrap(Root)),
    Available = try ae_artifacts:load(Root, list_to_binary(Digest)), true catch _:_ -> false end,
    io:put_chars([jsx:encode(#{<<"baseline_verified">> => true, <<"available">> => Available}), "\n"]);
main([Root, Mode, RequestPath, Boundary]) ->
    setup(),
    {ok, Bytes} = file:read_file(RequestPath), Request = jsx:decode(Bytes, [return_maps, strict]),
    Observer = fun(Event) ->
        case atom_to_list(Event) =:= Boundary of
            true -> io:put_chars([jsx:encode(#{<<"boundary">> => list_to_binary(Boundary)}), "\n"]), receive release -> ok end;
            false -> ok end
    end,
    try
        Args = [Root, base64:decode(maps:get(<<"executable">>, Request)), maps:get(<<"manifest">>, Request), maps:get(<<"job">>, Request)],
        ok = case Mode of "interrupt" -> apply(ae_host_publish, publish, Args ++ [Observer]); "recover" -> apply(ae_host_publish, publish, Args) end,
        io:put_chars([jsx:encode(#{<<"published">> => true}), "\n"])
    catch error:Reason -> io:put_chars([jsx:encode(#{<<"error">> => atom_to_binary(Reason, utf8)}), "\n"]), halt(1) end.
setup() ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    {ok, _} = application:ensure_all_started(crypto), ok.
