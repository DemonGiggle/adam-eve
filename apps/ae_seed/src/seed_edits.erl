-module(seed_edits).
-export([replace/5, prepare/3]).

%% The model supplies an exact replacement; the agent supplies diff syntax from
%% the immutable bytes it read. The controller still validates and applies it.
replace(Path, Source, Old, New, MaxBytes) when is_binary(Path) ->
    case replace_source(Source, Old, New) of
        {ok, Changed} -> bounded(diff(Path, Source, Changed), MaxBytes);
        Error -> Error
    end;
replace(_, _, _, _, _) -> {error, <<"invalid_edit_path">>}.

prepare(Edits, Files, MaxBytes) when is_list(Edits), length(Edits) > 0, length(Edits) =< 32 ->
    try
        Changed = lists:foldl(fun(Edit, Acc) -> apply_edit(Edit, Files, Acc) end, #{}, Edits),
        Patches = [diff(Path, Source, New) || {Path, New} <- lists:sort(maps:to_list(Changed)),
            #{data := Source} <- [maps:get(Path, Files)], Source =/= New],
        case Patches of
            [] -> {error, <<"edit_requires_changes">>};
            _ -> bounded(iolist_to_binary(Patches), MaxBytes)
        end
    catch throw:Reason -> {error, Reason} end;
prepare(_, _, _) -> {error, <<"edit_batch_must_contain_1_to_32_replacements">>}.

apply_edit(#{<<"path">> := Path, <<"old_text">> := Old, <<"new_text">> := New} = Edit, Files, Acc)
        when map_size(Edit) =:= 3, is_binary(Path) ->
    case maps:find(Path, Files) of
        {ok, #{data := Original, complete := true}} ->
            case replace_source(maps:get(Path, Acc, Original), Old, New) of
                {ok, Changed} -> Acc#{Path => Changed};
                {error, Reason} -> throw(Reason)
            end;
        _ -> throw(<<"edit_requires_complete_source_read">>)
    end;
apply_edit(_, _, _) -> throw(<<"invalid_edit_replacement">>).

replace_source(Source, Old, New) when is_binary(Source), is_binary(Old), byte_size(Old) > 0,
                                    is_binary(New), Old =/= New ->
    case unique_match(Source, Old) of
        {Offset, Length} ->
            <<Before:Offset/binary, _:Length/binary, After/binary>> = Source,
            {ok, <<Before/binary, New/binary, After/binary>>};
        _ -> {error, <<"edit_requires_unique_old_text">>}
    end;
replace_source(_, _, _) -> {error, <<"edit_requires_changed_nonempty_old_text">>}.

bounded(Patch, MaxBytes) when byte_size(Patch) =< MaxBytes -> {ok, Patch};
bounded(_, _) -> {error, <<"edit_patch_too_large">>}.
diff(Path, Source, Changed) ->
    {OldCount, OldLines} = lines(Source, $-),
    {NewCount, NewLines} = lines(Changed, $+),
    iolist_to_binary([<<"diff --git a/">>, Path, <<" b/">>, Path,
        <<"\n--- a/">>, Path, <<"\n+++ b/">>, Path, <<"\n@@ -">>, range(OldCount),
        <<" +">>, range(NewCount), <<" @@\n">>, OldLines, NewLines]).

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
