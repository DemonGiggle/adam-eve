-module(seed_edits).
-export([replace/5]).

%% The model supplies an exact replacement; the agent supplies diff syntax from
%% the immutable bytes it read. The controller still validates and applies it.
replace(Path, Source, Old, New, MaxBytes)
        when is_binary(Path), is_binary(Source), is_binary(Old), byte_size(Old) > 0,
             is_binary(New), Old =/= New ->
    case unique_match(Source, Old) of
        {Offset, Length} ->
            <<Before:Offset/binary, _:Length/binary, After/binary>> = Source,
            Changed = <<Before/binary, New/binary, After/binary>>,
            {OldCount, OldLines} = lines(Source, $-),
            {NewCount, NewLines} = lines(Changed, $+),
            Patch = iolist_to_binary([<<"diff --git a/">>, Path, <<" b/">>, Path,
                <<"\n--- a/">>, Path, <<"\n+++ b/">>, Path, <<"\n@@ -">>, range(OldCount),
                <<" +">>, range(NewCount), <<" @@\n">>, OldLines, NewLines]),
            case byte_size(Patch) =< MaxBytes of
                true -> {ok, Patch};
                false -> {error, <<"edit_patch_too_large">>}
            end;
        _ -> {error, <<"edit_requires_unique_old_text">>}
    end;
replace(_, _, _, _, _) -> {error, <<"edit_requires_changed_nonempty_old_text">>}.

unique_match(Source, Old) ->
    case binary:match(Source, Old) of
        {Offset, _} = Match ->
            %% Count overlapping matches too ("aa" occurs twice in "aaa").
            case binary:match(Source, Old, [{scope, {Offset + 1, byte_size(Source) - Offset - 1}}]) of
                nomatch -> Match;
                _ -> nomatch
            end;
        nomatch -> nomatch
    end.

range(0) -> <<"0,0">>;
range(Count) -> [<<"1,">>, integer_to_binary(Count)].
lines(<<>>, _) -> {0, []};
lines(Text, Prefix) ->
    Parts = binary:split(Text, <<"\n">>, [global]),
    {Lines, End} = case binary:last(Text) of
        $\n -> {lists:droplast(Parts), []};
        _ -> {Parts, <<"\\ No newline at end of file\n">>}
    end,
    {length(Lines), [[[Prefix, Line, $\n] || Line <- Lines], End]}.
