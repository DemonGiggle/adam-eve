-module(seed_edits_tests).
-include_lib("eunit/include/eunit.hrl").

%% These cases cover the byte/line boundary rules needed by git apply, including
%% missing final newlines and deleting every byte of an existing file.
newline_test() ->
    {ok, Patch} = edit(<<"one\n\ntwo\n">>, <<"two">>, <<"three\nfour">>),
    ?assertEqual(<<"@@ -1,3 +1,4 @@\n-one\n-\n-two\n+one\n+\n+three\n+four\n">>, hunk(Patch)).

missing_final_newline_test() ->
    {ok, Patch} = edit(<<"one\ntwo">>, <<"two">>, <<"three\n">>),
    ?assertEqual(<<"@@ -1,2 +1,2 @@\n-one\n-two\n\\ No newline at end of file\n+one\n+three\n">>, hunk(Patch)),
    {ok, Other} = edit(<<"one\n">>, <<"one\n">>, <<"two">>),
    ?assertEqual(<<"@@ -1,1 +1,1 @@\n-one\n+two\n\\ No newline at end of file\n">>, hunk(Other)).

empty_result_test() ->
    {ok, Patch} = edit(<<"one\n">>, <<"one\n">>, <<>>),
    ?assertEqual(<<"@@ -1,1 +0,0 @@\n-one\n">>, hunk(Patch)).

ambiguous_or_missing_text_test() ->
    ?assertEqual({error, <<"edit_requires_unique_old_text">>}, edit(<<"one one">>, <<"one">>, <<"two">>)),
    ?assertEqual({error, <<"edit_requires_unique_old_text">>}, edit(<<"aaa">>, <<"aa">>, <<"two">>)),
    ?assertEqual({error, <<"edit_requires_unique_old_text">>}, edit(<<"one">>, <<"absent">>, <<"two">>)),
    ?assertMatch({error, _}, edit(<<"one">>, <<>>, <<"two">>)),
    ?assertMatch({error, _}, edit(<<"one">>, <<"one">>, <<"one">>)).

patch_budget_test() ->
    ?assertEqual({error, <<"edit_patch_too_large">>}, seed_edits:replace(path(), <<"one">>, <<"one">>, <<"two">>, 16)).

edit(Source, Old, New) -> seed_edits:replace(path(), Source, Old, New, 4096).
path() -> <<"apps/ae_seed/src/example.erl">>.
hunk(Patch) ->
    [_, Hunk] = binary:split(Patch, <<"@@ ">>), <<"@@ ", Hunk/binary>>.
