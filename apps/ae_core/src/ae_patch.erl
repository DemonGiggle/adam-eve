-module(ae_patch).
-export([validate/2, writable/1, readable/1, canonical/1]).

%% A deliberately small unified-diff grammar. Git must still check/apply the
%% accepted diff to the pinned tree in a disposable workspace before a build.
validate(Patch, MaxBytes) when is_binary(Patch), byte_size(Patch) > 0, byte_size(Patch) =< MaxBytes ->
    try
        Lines = binary:split(Patch, <<"\n">>, [global]),
        Files = parse(Lines, undefined, header, []),
        true = Files =/= [],
        true = length(Files) =< 64,
        true = length(Files) =:= length(lists:usort(Files)),
        {ok, Files}
    catch _:_ -> {error, protected_patch} end;
validate(_, _) -> {error, patch_size}.

canonical(Path) when is_binary(Path), byte_size(Path) > 0, byte_size(Path) =< 240 ->
    re:run(Path, <<"^[A-Za-z0-9_./-]+$">>, [{capture, none}]) =:= match andalso
    lists:all(fun(P) -> P =/= <<>> andalso P =/= <<".">> andalso P =/= <<"..">> end,
              binary:split(Path, <<"/">>, [global]));
canonical(_) -> false.
writable(Path) ->
    canonical(Path) andalso
    (prefix(Path, <<"apps/ae_seed/src/">>) orelse prefix(Path, <<"apps/ae_seed/test/">>)) andalso
    lists:member(filename:extension(Path), [<<".erl">>, <<".hrl">>]).
readable(Path) ->
    canonical(Path) andalso
    (writable(Path) orelse
     lists:member(Path, [<<"apps/ae_seed/rebar.config">>, <<"apps/ae_seed/rebar.lock">>,
         <<"apps/ae_seed/src/ae_seed.app.src">>,
         <<"apps/ae_protocol/src/ae_protocol.erl">>, <<"apps/ae_protocol/src/ae_protocol.app.src">>,
         <<"docs/PROTOCOL.md">>])).
prefix(Path, Prefix) -> binary:longest_common_prefix([Path, Prefix]) =:= byte_size(Prefix).

parse([], undefined, header, []) -> error(empty_patch);
parse([], _, hunk, Files) -> lists:reverse(Files);
parse([<<>>], _, hunk, Files) -> lists:reverse(Files);
parse([<<"diff --git a/", Rest/binary>> | Lines], Previous, Phase, Files)
        when Previous =:= undefined; Phase =:= hunk ->
    [Path, Path] = binary:split(Rest, <<" b/">>),
    true = writable(Path), parse(Lines, Path, metadata, [Path | Files]);
parse([<<"index ", Value/binary>> | Lines], Path, metadata, Files) ->
    match = re:run(Value, <<"^[0-9a-f]+\\.\\.[0-9a-f]+( 100644)?$">>, [{capture, none}]),
    parse(Lines, Path, metadata, Files);
parse([Mode | Lines], Path, metadata, Files)
        when Mode =:= <<"new file mode 100644">>; Mode =:= <<"deleted file mode 100644">> ->
    parse(Lines, Path, metadata, Files);
parse([<<"--- ", Old/binary>>, <<"+++ ", New/binary>> | Lines], Path, metadata, Files) ->
    true = (Old =:= <<"a/", Path/binary>> orelse Old =:= <<"/dev/null">>),
    true = (New =:= <<"b/", Path/binary>> orelse New =:= <<"/dev/null">>),
    true = not (Old =:= <<"/dev/null">> andalso New =:= <<"/dev/null">>),
    parse(Lines, Path, body, Files);
parse([<<"@@ ", Rest/binary>> | Lines], Path, Phase, Files) when Phase =:= body; Phase =:= hunk ->
    match = re:run(Rest, <<"^-[0-9]+(,[0-9]+)? \\+[0-9]+(,[0-9]+)? @@.*$">>, [{capture, none}]),
    parse(Lines, Path, hunk, Files);
parse([<<Prefix, _/binary>> | Lines], Path, hunk, Files) when Prefix =:= $+; Prefix =:= $-; Prefix =:= $  ->
    parse(Lines, Path, hunk, Files);
parse([<<"\\ No newline at end of file">> | Lines], Path, hunk, Files) -> parse(Lines, Path, hunk, Files);
parse(_, _, _, _) -> error(unsupported_diff).
