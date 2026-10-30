-module(ae_storage_tests).
-include_lib("eunit/include/eunit.hrl").

retention_requires_explicit_preservation_test() ->
    Policy = #{<<"promoted_generations">> => <<"all">>, <<"rejected_attempts">> => <<"all">>, <<"audit">> => <<"all">>},
    ?assertEqual({ok, Policy}, ae_storage:validate_retention(Policy)),
    [?assertEqual({error, retention_policy_required}, ae_storage:validate_retention(Bad)) ||
        Bad <- [undefined, #{}, maps:remove(<<"audit">>, Policy), Policy#{<<"audit">> := 0},
            Policy#{<<"promoted_generations">> := <<"latest">>}]].

headroom_uses_the_declared_reserve_and_fails_closed_test() ->
    Config = #{root => "/tmp", candidate_builder => #{<<"source_bytes">> => 1024, <<"artifact_bytes">> => 1024}},
    Limits = #{<<"max_llm_calls">> => 2, <<"max_tokens">> => 100, <<"tokens_per_call">> => 50,
        <<"max_attempts">> => 2, <<"max_patch_bytes">> => 1024, <<"disk_reserve_bytes">> => 1024},
    ?assertEqual(ok, ae_storage:preflight(Config, Limits)),
    ?assertEqual({error, storage_pressure}, ae_storage:preflight(Config, Limits#{<<"disk_reserve_bytes">> := 1 bsl 62})),
    ?assertEqual({error, storage_unavailable}, ae_storage:preflight(Config#{root := "/nonexistent-adam-eve-storage"}, Limits)).

headroom_accepts_paths_without_shell_interpretation_test() ->
    Name = "ae storage ;$" ++ integer_to_list(erlang:unique_integer([positive])),
    Root = filename:join("/tmp", Name),
    ok = file:make_dir(Root),
    Config = #{root => Root, candidate_builder => #{<<"source_bytes">> => 1024, <<"artifact_bytes">> => 1024}},
    Limits = #{<<"max_llm_calls">> => 2, <<"max_tokens">> => 100, <<"tokens_per_call">> => 50,
        <<"max_attempts">> => 2, <<"max_patch_bytes">> => 1024, <<"disk_reserve_bytes">> => 1024},
    try ?assertEqual(ok, ae_storage:preflight(Config, Limits))
    after file:del_dir(Root) end.
