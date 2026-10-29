-module(ae_evolution_store_tests).
-include_lib("eunit/include/eunit.hrl").

reservation_and_repair_survive_restart_test() ->
    with_store(fun(Base, Auth) ->
        ?assertEqual({error, evolution_limits_required}, e({create, Base, <<"operator">>, <<"improve">>, #{}})),
        {ok, Job} = e({create, Base, <<"operator-command-1">>, <<"improve">>, limits()}),
        Id = maps:get(<<"id">>, Job),
        ?assertEqual({error, evolution_in_progress}, e({create, Base, <<"operator">>, <<"other">>, limits()})),
        ?assertEqual({error, evolution_in_progress}, ae_store:new_deployment(Base,
            #{<<"digest">> => <<"g2">>, <<"parent">> => <<"g1">>}, #{<<"approval_ttl_ms">> => 1000})),
        Hash = ae_policy:digest(<<"prompt">>),
        ?assertEqual({ok, reserved}, e({reserve_llm, Auth, Id, <<"call-1">>, Hash})),
        ?assertEqual({error, llm_outcome_unknown}, e({reserve_llm, Auth, Id, <<"call-1">>, Hash})),
        Result = #{<<"text">> => <<"a structured patch">>},
        {ok, _} = e({finish_llm, Auth, Id, <<"call-1">>, Result}),
        ?assertEqual({ok, {completed, Result}}, e({reserve_llm, Auth, Id, <<"call-1">>, Hash})),
        ?assertEqual({error, call_conflict}, e({reserve_llm, Auth, Id, <<"call-1">>, ae_policy:digest(<<"changed">>)})),
        Proposal = proposal(<<"p1">>, patch()),
        {ok, Accepted} = e({proposal, Auth, Id, Proposal}),
        ?assertEqual(ae_policy:sha256(patch()), maps:get(<<"patch_hash">>, Accepted)),
        ?assertEqual({ok, {existing, Accepted}}, e({proposal, Auth, Id, Proposal})),
        ?assertEqual({error, proposal_conflict}, e({proposal, Auth, Id, Proposal#{<<"hypothesis">> := <<"changed">>}})),
        ?assertEqual({error, invalid_job_state}, e({source_reserve, Auth, Id})),
        {ok, _} = e({attempt_result, Id, 1, <<"build_failed">>, <<"public compiler error">>}),
        ?assertEqual({ok, {existing, Accepted}}, e({proposal, Auth, Id, Proposal})),
        Root = get(test_root), gen_server:stop(ae_store), {ok, _} = ae_store:start_link(Root),
        Resumed = e({get, Id}),
        ?assertEqual(1, maps:get(<<"llm_calls">>, Resumed)),
        ?assertEqual(100, maps:get(<<"reserved_tokens">>, Resumed)),
        ?assertEqual(1, maps:get(<<"reserved_cost_microunits">>, Resumed)),
        ?assertEqual(1, maps:get(<<"attempts">>, Resumed)),
        ?assertEqual(Accepted, e({attempt, Id, 1})),
        ?assertEqual({ok, {existing, Resumed}}, e({create, Base, <<"operator-command-1">>, <<"improve">>, limits()})),
        ?assertEqual({error, origin_conflict}, e({create, Base, <<"operator-command-1">>, <<"different objective">>, limits()})),
        ?assertEqual({ok, {existing, Accepted}}, e({proposal, Auth, Id, Proposal})),
        {ok, Second} = e({proposal, Auth, Id, proposal(<<"p2">>, patch())}),
        ?assertEqual(2, maps:get(<<"attempt">>, Second)),
        ?assertEqual({error, job_rejected}, e({attempt_result, Id, 2, <<"tests_failed">>, <<"public aggregate failure">>})),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, e({get, Id})))
    end).

budgets_and_fencing_test() ->
    with_store(fun(Base, Auth) ->
        {ok, Job} = e({create, Base, <<"operator">>, <<"improve">>, (limits())#{<<"max_llm_calls">> := 1}}),
        Id = maps:get(<<"id">>, Job), Hash = ae_policy:digest(<<"prompt">>),
        {ok, reserved} = e({reserve_llm, Auth, Id, <<"call">>, Hash}),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(get(test_root)),
        ?assertEqual({error, llm_outcome_unknown}, e({reserve_llm, Auth, Id, <<"call">>, Hash})),
        ?assertEqual({error, budget_exhausted}, e({reserve_llm, Auth, Id, <<"new-call">>, Hash})),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, e({get, Id}))),
        {ok, Job2} = e({create, Base, <<"operator-2">>, <<"improve">>, limits()}),
        Id2 = maps:get(<<"id">>, Job2),
        {ok, _} = ae_store:activate(Base, <<"new-instance">>),
        ?assertEqual(<<"cancelled">>, maps:get(<<"status">>, e({get, Id2}))),
        ?assertEqual({error, stale_runtime}, e({authorize, Auth, Id2}))
    end).

protected_paths_terminate_job_test() ->
    with_store(fun(Base, Auth) ->
        {ok, Job} = e({create, Base, <<"operator">>, <<"improve">>, limits()}),
        Id = maps:get(<<"id">>, Job),
        Bad = binary:replace(patch(), <<"apps/ae_seed/src/seed_agent.erl">>, <<"apps/ae_core/src/ae_store.erl">>, [global]),
        ?assertEqual({error, protected_patch}, e({proposal, Auth, Id, proposal(<<"bad">>, Bad)})),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, e({get, Id}))),
        ?assert(lists:any(fun({_, Kind, _}) -> Kind =:= <<"evolution_proposal_rejected">> end, ae_store:events()))
    end).

source_budget_and_time_test() ->
    with_store(fun(Base, Auth) ->
        {ok, Job} = e({create, Base, <<"operator">>, <<"improve">>, (limits())#{<<"max_source_calls">> := 1}}),
        Id = maps:get(<<"id">>, Job), {ok, _} = e({source_reserve, Auth, Id}),
        ?assertEqual({error, budget_exhausted}, e({source_reserve, Auth, Id})),
        {ok, Expiring} = e({create, Base, <<"operator-2">>, <<"improve">>, (limits())#{<<"total_ms">> := 1}}),
        receive after 5 -> ok end,
        ?assertEqual({error, job_expired}, e({attempt_result, maps:get(<<"id">>, Expiring), 0, <<"build_failed">>, <<"late result">>})),
        ?assertEqual(undefined, e(active))
    end).

execution_reservations_survive_failure_and_restart_test() ->
    with_store(fun(Base, Auth) ->
        {ok, Job} = e({create, Base, <<"execution-test">>, <<"improve">>, limits()}),
        Id = maps:get(<<"id">>, Job),
        {ok, _} = e({proposal, Auth, Id, proposal(<<"p1">>, patch())}),
        {ok, Lease1} = e({reserve_execution, Id, 1, <<"build">>, 2000, 1000}),
        ?assertEqual({error, execution_outcome_unknown}, e({reserve_execution, Id, 1, <<"build">>, 2000, 1000})),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(get(test_root)),
        ?assertEqual(2000, maps:get(<<"reserved_cpu_ms">>, e({get, Id}))),
        ?assertEqual({error, execution_outcome_unknown}, e({reserve_execution, Id, 1, <<"build">>, 2000, 1000})),
        ?assertEqual({error, invalid_execution_lease},
            e({execution_failed, Id, 1, <<"build">>, <<"wrong">>, <<"compile_failed">>, <<"public diagnostic">>})),
        {ok, _} = e({execution_failed, Id, 1, <<"build">>, maps:get(<<"id">>, Lease1),
            <<"compile_failed">>, <<"public diagnostic">>}),
        {ok, Accepted} = e({proposal, Auth, Id, proposal(<<"p2">>, patch())}),
        {ok, Lease2} = e({reserve_execution, Id, 2, <<"build">>, 2000, 1000}),
        Manifest = #{<<"authoring">> => <<"llm">>, <<"digest">> => binary:copy(<<"a">>, 64),
            <<"source_revision">> => binary:copy(<<"b">>, 40), <<"source_tree">> => binary:copy(<<"c">>, 40),
            <<"parent">> => <<"g1">>, <<"producing_job">> => Id, <<"producing_attempt">> => 2,
            <<"patch_hash">> => maps:get(<<"patch_hash">>, Accepted), <<"capabilities">> => [],
            <<"state_schema_versions">> => [1], <<"evaluation">> => null},
        ?assertEqual({error, invalid_build_manifest}, e({finish_build, Id, 2, maps:get(<<"id">>, Lease2),
            Manifest#{<<"producing_job">> := <<"wrong-job">>}})),
        {ok, Built} = e({finish_build, Id, 2, maps:get(<<"id">>, Lease2), Manifest}),
        ?assertEqual(<<"testing">>, maps:get(<<"status">>, Built)),
        ?assertEqual(4000, maps:get(<<"reserved_cpu_ms">>, Built)),
        ?assertEqual({error, budget_exhausted}, e({reserve_execution, Id, 2, <<"evaluate">>, 2000, 1000})),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, e({get, Id})))
    end).

evaluation_binding_and_results_survive_restart_test() ->
    with_store(fun(Base, Auth) ->
        {Id, Built} = built_job(Base, Auth),
        Binding = evaluation_binding(),
        ?assertEqual({error, invalid_evaluation_binding}, e({reserve_evaluation, Id, 1, 1000, 1000, #{}, evaluation_configuration()})),
        ?assertEqual({error, invalid_evaluation_configuration}, e({reserve_evaluation, Id, 1, 1000, 1000, Binding, <<"{}">>})),
        {ok, Lease} = e({reserve_evaluation, Id, 1, 1000, 1000, Binding, evaluation_configuration()}),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(get(test_root)),
        ?assertEqual({error, execution_outcome_unknown}, e({reserve_evaluation, Id, 1, 1000, 1000, Binding, evaluation_configuration()})),
        Score = scorecard(Built, Lease), LeaseId = maps:get(<<"id">>, Lease),
        ?assertEqual({error, invalid_evaluation_result}, e({finish_evaluation, Id, 1, LeaseId,
            Score#{<<"configuration_hash">> := binary:copy(<<"f">>, 64)}})),
        ?assertEqual({error, invalid_evaluation_result}, e({finish_evaluation, Id, 1, LeaseId,
            Score#{<<"baseline_digest">> := <<"changed-baseline">>}})),
        ?assertEqual({error, invalid_evaluation_result}, e({finish_evaluation, Id, 1, LeaseId,
            Score#{<<"gates">> := (maps:get(<<"gates">>, Score))#{<<"isolation">> := false}}})),
        {ok, Evaluated} = e({finish_evaluation, Id, 1, LeaseId, Score}),
        ?assertEqual(<<"evaluated">>, maps:get(<<"status">>, Evaluated)),
        ?assertEqual(2000, maps:get(<<"reserved_cpu_ms">>, Evaluated)),
        ?assertEqual(evaluation_configuration(), maps:get(<<"evaluation_configuration">>, Lease)),
        Hash = ae_policy:digest(Score), ?assertEqual(Hash, maps:get(<<"evaluation_digest">>, Evaluated)),
        ?assertEqual(null, maps:get(<<"evaluation">>, maps:get(<<"built_artifact">>, Evaluated))),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(get(test_root)),
        Saved = e({get, Id}),
        ?assertEqual(#{<<"digest">> => Hash, <<"scorecard">> => Score}, maps:get(<<"1">>, maps:get(<<"evaluations">>, Saved))),
        ?assertEqual({error, invalid_job_state}, e({reserve_evaluation, Id, 1, 1000, 1000, Binding, evaluation_configuration()}))
    end).

failed_evaluation_retains_scorecard_and_consumes_repair_budget_test() ->
    with_store(fun(Base, Auth) ->
        {Id, Built} = built_job(Base, Auth),
        {ok, Lease} = e({reserve_evaluation, Id, 1, 1000, 1000, evaluation_binding(), evaluation_configuration()}),
        Score = (scorecard(Built, Lease))#{<<"passed">> := false},
        {ok, Repaired} = e({finish_evaluation, Id, 1, maps:get(<<"id">>, Lease), Score}),
        ?assertEqual(<<"proposing">>, maps:get(<<"status">>, Repaired)),
        ?assertEqual(2000, maps:get(<<"reserved_cpu_ms">>, Repaired)),
        ?assertEqual(1, maps:get(<<"attempts">>, Repaired)),
        ?assertEqual(1, map_size(maps:get(<<"evaluations">>, Repaired))),
        ?assertEqual(<<"Independent evaluation did not meet the configured gates.">>, maps:get(<<"public_diagnostics">>, Repaired)),
        ?assertEqual({error, invalid_job_state}, e({reserve_evaluation, Id, 1, 1000, 1000, evaluation_binding(), evaluation_configuration()}))
    end).

small_feedback_budget_still_retains_scorecard_test() ->
    with_store(fun(Base, Auth) ->
        {Id, Built} = built_job(Base, Auth, (limits())#{<<"max_diagnostic_bytes">> := 4}),
        {ok, Lease} = e({reserve_evaluation, Id, 1, 1000, 1000, evaluation_binding(), evaluation_configuration()}),
        Score = (scorecard(Built, Lease))#{<<"passed">> := false},
        {ok, Repaired} = e({finish_evaluation, Id, 1, maps:get(<<"id">>, Lease), Score}),
        ?assertEqual(<<"Inde">>, maps:get(<<"public_diagnostics">>, Repaired)),
        ?assertEqual(Score, maps:get(<<"scorecard">>, maps:get(<<"1">>, maps:get(<<"evaluations">>, Repaired))))
    end).

built_job(Base, Auth) -> built_job(Base, Auth, limits()).
built_job(Base, Auth, Limits) ->
    {ok, Job} = e({create, Base, <<"evaluation-test">>, <<"improve">>, Limits}), Id = maps:get(<<"id">>, Job),
    {ok, Accepted} = e({proposal, Auth, Id, proposal(<<"p1">>, patch())}),
    {ok, Lease} = e({reserve_execution, Id, 1, <<"build">>, 1000, 1000}),
    Manifest = #{<<"authoring">> => <<"llm">>, <<"digest">> => binary:copy(<<"a">>, 64),
        <<"source_revision">> => binary:copy(<<"b">>, 40), <<"source_tree">> => binary:copy(<<"c">>, 40),
        <<"parent">> => <<"g1">>, <<"producing_job">> => Id, <<"producing_attempt">> => 1,
        <<"patch_hash">> => maps:get(<<"patch_hash">>, Accepted), <<"capabilities">> => [],
        <<"state_schema_versions">> => [1], <<"evaluation">> => null},
    {ok, Built} = e({finish_build, Id, 1, maps:get(<<"id">>, Lease), Manifest}), {Id, Built}.
evaluation_binding() -> (maps:from_list([{Key, binary:copy(<<"d">>, 64)} || Key <-
    [<<"harness_hash">>, <<"test_recipe_hash">>, <<"sandbox_hash">>, <<"source_helper_hash">>]]))#{
        <<"configuration_hash">> => ae_policy:sha256(evaluation_configuration())}.
evaluation_configuration() ->
    {ok, Bytes} = file:read_file("test/evaluation/policy.json"), Policy = jsx:decode(Bytes, [return_maps]),
    jsx:encode(#{<<"cgroup_root">> => <<"/sys/fs/cgroup/test">>, <<"source_bytes">> => 2097152,
        <<"source_files">> => 128, <<"artifact_bytes">> => 8388608, <<"startup_ms">> => 30000,
        <<"turn_ms">> => 15000, <<"policy">> => Policy, <<"sandbox_limits">> => #{
            <<"memory_bytes">> => 536870912, <<"pids">> => 64, <<"cpu_percent">> => 100,
            <<"cpu_seconds">> => 15, <<"address_space_bytes">> => 1073741824, <<"file_bytes">> => 33554432,
            <<"open_files">> => 128, <<"output_bytes">> => 1048576, <<"wall_ms">> => 180000}}).
scorecard(Job, Lease) ->
    Rate = #{<<"passed">> => 1, <<"total">> => 1, <<"rate_ppm">> => 1000000, <<"wilson95_ppm">> => [200000, 1000000]},
    Zero = #{<<"passed">> => 0, <<"total">> => 1, <<"rate_ppm">> => 0, <<"wilson95_ppm">> => [0, 800000]},
    Measurement = #{<<"success">> => Rate, <<"objective">> => Rate, <<"task_success">> => Rate,
        <<"memory_retrieval">> => Rate, <<"tool_correctness">> => Rate, <<"required_failed">> => 0,
        <<"crash_timeout">> => Zero, <<"latency_us">> => #{<<"samples">> => 1, <<"mean">> => 100, <<"min">> => 100, <<"max">> => 100},
        <<"mock_model">> => #{<<"calls">> => 1, <<"input_tokens">> => 10, <<"output_tokens">> => 10, <<"cost_microunits">> => 1}},
    maps:merge(evaluation_binding(), #{<<"version">> => 1, <<"job_id">> => maps:get(<<"id">>, Job), <<"attempt">> => 1,
        <<"execution_id">> => maps:get(<<"id">>, Lease), <<"baseline_digest">> => <<"g1">>,
        <<"candidate_digest">> => binary:copy(<<"a">>, 64), <<"policy_hash">> => binary:copy(<<"e">>, 64), <<"trial_seed">> => binary:copy(<<"a">>, 64),
        <<"gates">> => maps:from_list([{Key, true} || Key <- [<<"isolation">>, <<"candidate_tests">>, <<"baseline_contract">>,
            <<"candidate_contract">>, <<"rollback_restore">>]]),
        <<"baseline">> => Measurement#{<<"success">> := Zero, <<"objective">> := Zero}, <<"candidate">> => Measurement,
        <<"passed">> => true, <<"measured_at_ms">> => erlang:system_time(millisecond),
        <<"measurement_scope">> => <<"synthetic_mock_tools">>, <<"uncertainty">> => <<"test fixture only">>}).

patch_scope_test() ->
    ?assertMatch({ok, [_]}, ae_patch:validate(patch(), 4096)),
    [begin
        Bad = binary:replace(patch(), <<"apps/ae_seed/src/seed_agent.erl">>, Path, [global]),
        ?assertMatch({error, _}, ae_patch:validate(Bad, 4096))
     end || Path <- [<<"../seed_agent.erl">>, <<"apps/ae_seed/src/../../ae_core/src/ae_store.erl">>,
         <<"apps/ae_seed/rebar.config">>, <<"apps/ae_seed/src/ae_seed.app.src">>, <<"/etc/passwd">>]],
    ?assertMatch({error, _}, ae_patch:validate(<<"diff --git a/apps/ae_seed/src/new.erl b/apps/ae_seed/src/new.erl\nnew file mode 120000\n">>, 4096)),
    ?assertEqual({error, patch_size}, ae_patch:validate(patch(), 1)).

e(Operation) -> ae_store:evolution(Operation).
patch() -> <<"diff --git a/apps/ae_seed/src/seed_agent.erl b/apps/ae_seed/src/seed_agent.erl\n"
    "--- a/apps/ae_seed/src/seed_agent.erl\n+++ b/apps/ae_seed/src/seed_agent.erl\n@@ -1 +1 @@\n-old\n+new\n">>.
proposal(Id, Patch) -> #{<<"proposal_id">> => Id, <<"base_artifact">> => <<"g1">>,
    <<"base_source_revision">> => <<"source-1">>, <<"epoch">> => 1, <<"patch">> => Patch,
    <<"hypothesis">> => <<"preserve context better">>, <<"expected_benefit">> => <<"improved recall">>,
    <<"risks">> => [<<"regression">>], <<"requested_tests">> => [<<"contract">>]}.
limits() -> #{<<"max_attempts">> => 2, <<"total_ms">> => 60000, <<"max_llm_calls">> => 2,
    <<"tokens_per_call">> => 100, <<"max_tokens">> => 200, <<"max_cost_microunits">> => 2,
    <<"cost_per_call_microunits">> => 1, <<"max_patch_bytes">> => 4096,
    <<"max_diagnostic_bytes">> => 1024, <<"max_source_calls">> => 8, <<"max_source_bytes">> => 8192,
    <<"source_page_bytes">> => 1024, <<"build_ms">> => 5000, <<"evaluation_ms">> => 5000,
    <<"cpu_ms">> => 5000, <<"memory_bytes">> => 536870912, <<"processes">> => 32,
    <<"disk_reserve_bytes">> => 1048576}.
with_store(Fun) ->
    Root = filename:join("/tmp", "ae-evolve-" ++ integer_to_list(erlang:unique_integer([positive]))),
    put(test_root, Root),
    try
        {ok, _} = ae_store:start_link(Root),
        Seed = ae_store:boot(#{<<"digest">> => <<"g1">>, <<"source_revision">> => <<"source-1">>}),
        {ok, Base} = ae_store:activate(Seed, <<"instance">>),
        Fun(Base, {<<"adam">>, <<"instance">>, 1})
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root), erase(test_root)
    end.
