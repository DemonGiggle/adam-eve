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
