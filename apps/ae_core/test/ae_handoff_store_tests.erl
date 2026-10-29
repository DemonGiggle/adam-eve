-module(ae_handoff_store_tests).
-include_lib("eunit/include/eunit.hrl").

promotion_recovery_preserves_acknowledged_work_test() ->
    Root = filename:join("/tmp", "ae-handoff-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        G1 = #{<<"digest">> => <<"g1">>, <<"parent">> => null},
        Initial = ae_store:boot(G1),
        {ok, Base} = ae_store:activate(Initial, <<"adam-1">>),
        G2 = #{<<"digest">> => <<"g2">>, <<"parent">> => <<"g1">>},
        Limits = #{<<"approval_ttl_ms">> => 60000, <<"observe_ms">> => 60000},
        ?assertEqual({error, independent_evaluation_required},
            ae_store:new_deployment(Base, G2#{<<"authoring">> => <<"llm">>}, Limits)),
        {ok, Job} = ae_store:new_deployment(Base, G2, Limits),
        Id = maps:get(<<"id">>, Job),
        ?assertEqual({error, deployment_in_progress}, ae_store:new_deployment(Base, G2, Limits)),
        Standby = #{<<"slot">> => <<"eve">>, <<"runtime_instance_id">> => <<"eve-1">>, <<"artifact">> => G2},
        ?assertEqual({error, stale_runtime}, ae_store:authorized({<<"eve">>, <<"eve-1">>, 1})),
        {ok, Staged} = ae_store:staged(Id, Standby, #{<<"contract">> => true, <<"synthetic_turn">> => true}),
        ?assertEqual({error, approval_mismatch}, ae_store:approve(Id, <<"other-artifact-approval">>)),
        {ok, _} = ae_store:approve(Id, ae_policy:binding(Staged)),
        {ok, Closed} = ae_store:quiesce(Base, Id),
        ?assertEqual({error, quiescing}, ae_store:authorized(auth(Base))),
        {ok, CP1} = ae_store:checkpoint(Closed),
        CP1Id = maps:get(<<"checkpoint_id">>, CP1),
        ?assertEqual({error, runtime_changed},
            ae_store:promote(Id, Closed, Standby#{<<"runtime_instance_id">> := <<"replacement">>}, CP1Id)),
        {ok, Promoted} = ae_store:promote(Id, Closed, Standby, CP1Id),
        ?assertEqual(2, maps:get(<<"epoch">>, Promoted)),
        ?assertEqual({error, stale_runtime}, ae_store:begin_turn(auth(Base), <<"stale">>, <<"s">>, <<"denied">>)),
        Auth = auth(Promoted),
        {ok, pending} = ae_store:begin_turn(Auth, <<"committed-by-candidate">>, <<"s">>, <<"remember">>),
        {ok, reserved} = ae_store:reserve_tool(Auth, <<"committed-by-candidate">>, <<"llm">>),
        Result = #{<<"text">> => <<"retained result">>},
        {ok, Result} = ae_store:finish_tool(Auth, <<"committed-by-candidate">>, <<"llm">>, Result),
        {ok, _} = ae_store:finish_turn(Auth, <<"committed-by-candidate">>, <<"retained reply">>),
        {ok, pending} = ae_store:begin_turn(Auth, <<"pending">>, <<"s">>, <<"continue later">>),
        {ok, reserved} = ae_store:reserve_tool(Auth, <<"pending">>, <<"llm">>),
        gen_server:stop(ae_store),
        {ok, _} = ae_store:start_link(Root),
        ?assertMatch({rollback, #{<<"id">> := Id}}, ae_store:recover_handoff()),
        {ok, RollbackBase} = ae_store:quiesce(Promoted, null),
        {ok, CP2} = ae_store:checkpoint(RollbackBase),
        ?assertEqual([<<"pending">>], maps:get(<<"pending_task_ids">>, CP2)),
        ?assert(maps:get(<<"last_event_seq">>, CP2) > maps:get(<<"last_event_seq">>, CP1)),
        Previous = #{<<"slot">> => <<"adam">>, <<"runtime_instance_id">> => <<"adam-2">>, <<"artifact">> => G1},
        {ok, Restored} = ae_store:rollback(Id, RollbackBase, Previous,
            maps:get(<<"checkpoint_id">>, CP2), <<"controller_restart">>),
        ?assertEqual(3, maps:get(<<"epoch">>, Restored)),
        ?assertEqual({ok, {completed, <<"retained reply">>}}, ae_store:begin_turn(auth(Restored),
            <<"committed-by-candidate">>, <<"s">>, <<"remember">>)),
        ?assertEqual({ok, pending}, ae_store:begin_turn(auth(Restored), <<"pending">>, <<"s">>, <<"continue later">>)),
        ?assertEqual({error, tool_outcome_unknown}, ae_store:reserve_tool(auth(Restored), <<"pending">>, <<"llm">>)),
        ?assertEqual({error, stale_runtime}, ae_store:finish_turn(Auth, <<"pending">>, <<"late reply">>)),
        ?assertEqual(1, length([ok || {_, <<"tool_result">>, _} <- ae_store:events()])),
        ?assertEqual(<<"rolled_back">>, maps:get(<<"status">>, ae_store:deployment(Id))),
        ?assertEqual(undefined, ae_store:active_deployment()),
        ?assertEqual({error, stale_candidate}, ae_store:new_deployment(Restored,
            #{<<"digest">> => <<"g3">>, <<"parent">> => <<"g2">>}, Limits))
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.

checkpoint_and_approval_are_invalidated_test() ->
    Root = filename:join("/tmp", "ae-stale-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Initial = ae_store:boot(#{<<"digest">> => <<"g1">>}),
        {ok, Base} = ae_store:activate(Initial, <<"adam">>),
        G2 = #{<<"digest">> => <<"g2">>, <<"parent">> => <<"g1">>},
        {ok, Job} = ae_store:new_deployment(Base, G2,
            #{<<"approval_ttl_ms">> => 60000, <<"observe_ms">> => 60000}),
        Id = maps:get(<<"id">>, Job),
        Desc = #{<<"slot">> => <<"eve">>, <<"runtime_instance_id">> => <<"eve">>, <<"artifact">> => G2},
        {ok, Staged} = ae_store:staged(Id, Desc, #{}),
        {ok, _} = ae_store:approve(Id, ae_policy:binding(Staged)),
        {ok, Closed} = ae_store:quiesce(Base, Id),
        ok = ae_store:preparing_promotion(Id, Closed),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(Root),
        ?assertEqual(<<"promoting">>, maps:get(<<"status">>, ae_store:deployment(Id))),
        {ok, CP} = ae_store:checkpoint(Closed),
        %% An operator ledger mutation after the snapshot invalidates that high-watermark.
        {ok, _} = ae_store:checkpoint(Closed),
        ?assertEqual({error, stale_checkpoint}, ae_store:promote(Id, Closed, Desc, maps:get(<<"checkpoint_id">>, CP))),
        {ok, _} = ae_store:activate(Closed, <<"replacement-adam">>),
        ?assertEqual({error, stale_routing}, ae_store:promote(Id, Closed, Desc, maps:get(<<"checkpoint_id">>, CP))),
        ?assertEqual(normal, ae_store:recover_handoff()),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, ae_store:deployment(Id)))
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.

auth(Route) -> {maps:get(<<"slot">>, Route), maps:get(<<"runtime_instance_id">>, Route), maps:get(<<"epoch">>, Route)}.
