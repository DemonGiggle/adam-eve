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

batch_order_and_atomic_failure_test() ->
    Files = #{path() => #{data => <<"call(old).\nend.\n">>, complete => true}},
    Edits = [replacement(path(), <<"call(old)">>, <<"call(helper)">>),
        replacement(path(), <<"end.\n">>, <<"end.\nhelper() -> new.\n">>)],
    {ok, Patch} = seed_edits:prepare(Edits, Files, 4096),
    ?assertEqual(<<"@@ -1,2 +1,3 @@\n-call(old).\n-end.\n+call(helper).\n+end.\n+helper() -> new.\n">>, hunk(Patch)),
    ?assertMatch({error, _}, seed_edits:prepare(Edits ++ [replacement(path(), <<"absent">>, <<"bad">>)], Files, 4096)),
    ?assertEqual({ok, Patch}, seed_edits:prepare(Edits, Files, 4096)),
    ?assertMatch({error, _}, seed_edits:prepare([replacement(path(), <<"old">>, <<"new">>),
        replacement(path(), <<"new">>, <<"old">>)], Files, 4096)),
    ?assertMatch({error, _}, seed_edits:prepare(Edits, #{path() => #{data => <<"partial">>, complete => false}}, 4096)).

multiple_files_share_one_patch_budget_test() ->
    Other = <<"apps/ae_seed/src/other.erl">>,
    Files = #{path() => #{data => <<"old\n">>, complete => true}, Other => #{data => <<"old\n">>, complete => true}},
    One = [replacement(path(), <<"old">>, <<"new">>)],
    {ok, Single} = seed_edits:prepare(One, Files, 4096),
    Both = One ++ [replacement(Other, <<"old">>, <<"new">>)],
    ?assertEqual({error, <<"edit_patch_too_large">>}, seed_edits:prepare(Both, Files, byte_size(Single))),
    {ok, Patch} = seed_edits:prepare(Both, Files, 4096),
    ?assertEqual(2, length(binary:matches(Patch, <<"diff --git ">>))),
    ?assertMatch({error, _}, seed_edits:prepare(lists:duplicate(33, hd(One)), Files, 4096)).

replacement(Path, Old, New) -> #{<<"path">> => Path, <<"old_text">> => Old, <<"new_text">> => New}.
edit(Source, Old, New) -> seed_edits:replace(path(), Source, Old, New, 4096).
path() -> <<"apps/ae_seed/src/example.erl">>.
hunk(Patch) ->
    [_, Hunk] = binary:split(Patch, <<"@@ ">>), <<"@@ ", Hunk/binary>>.
