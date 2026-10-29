-module(ae_recovery_store_tests).
-include_lib("eunit/include/eunit.hrl").

restore_requires_replay_and_a_new_epoch_test() ->
    Root = filename:join("/tmp", "ae-recovery-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Initial = ae_store:boot(#{<<"digest">> => <<"seed">>}),
        {ok, First} = ae_store:activate(Initial, <<"original">>),
        {ok, pending} = ae_store:begin_turn(auth(First), <<"done">>, <<"s">>, <<"remember">>),
        {ok, reserved} = ae_store:reserve_tool(auth(First), <<"done">>, <<"llm">>),
        Result = #{<<"text">> => <<"retained">>},
        {ok, Result} = ae_store:finish_tool(auth(First), <<"done">>, <<"llm">>, Result),
        {ok, _} = ae_store:finish_turn(auth(First), <<"done">>, <<"retained">>),
        {ok, pending} = ae_store:begin_turn(auth(First), <<"unknown">>, <<"s">>, <<"pending">>),
        {ok, reserved} = ae_store:reserve_tool(auth(First), <<"unknown">>, <<"llm">>),
        Seq = ae_store:last_seq(),
        gen_server:stop(ae_store),
        %% Model the offline restore tool's durable fence, before any runtime boots.
        Id = binary:copy(<<"a">>, 64),
        Record = #{<<"schema_version">> => 1, <<"backup_id">> => Id, <<"pending">> => true,
                   <<"source_event_seq">> => Seq, <<"epoch_floor">> => 1000},
        {ok, Db} = sqlite3:open(anonymous, [{file, filename:join([Root, "state", "agent.sqlite3"])}]),
        ae_sql:exec(Db, "INSERT INTO control VALUES('restore',?)", [jsx:encode(Record)]),
        sqlite3:close(Db),
        {ok, _} = ae_store:start_link(Root),
        ?assertEqual({error, restore_verification_required}, ae_store:authorized(auth(First))),
        ?assertEqual({error, restore_verification_required},
            ae_store:finish_tool(auth(First), <<"unknown">>, <<"llm">>, Result)),
        ?assertEqual({error, missing_checkpoint}, ae_store:verify_recovery(First, Id, <<"operator">>)),
        {ok, CP} = ae_store:checkpoint(First),
        Desc = maps:with([<<"slot">>, <<"artifact">>], First),
        {ok, Restored} = ae_store:activate_checkpoint(First,
            Desc#{<<"runtime_instance_id">> => <<"restored">>}, maps:get(<<"checkpoint_id">>, CP)),
        ?assertEqual(1001, maps:get(<<"epoch">>, Restored)),
        ?assertEqual(<<"closed">>, maps:get(<<"admission">>, Restored)),
        ?assertEqual({error, restore_verification_required},
            ae_store:begin_turn(auth(Restored), <<"done">>, <<"s">>, <<"remember">>)),
        ?assertEqual({error, backup_mismatch}, ae_store:verify_recovery(Restored, <<"wrong">>, <<"operator">>)),
        ?assertEqual(ok, ae_store:verify_recovery(Restored, Id, <<"operator fenced original and reconciled effects">>)),
        ?assertEqual(ok, ae_store:verify_recovery(Restored, Id, <<"duplicate acknowledgement">>)),
        ?assertEqual({ok, {completed, <<"retained">>}},
            ae_store:begin_turn(auth(Restored), <<"done">>, <<"s">>, <<"remember">>)),
        ?assertEqual({error, tool_outcome_unknown}, ae_store:reserve_tool(auth(Restored), <<"unknown">>, <<"llm">>)),
        ?assertEqual({error, stale_runtime}, ae_store:finish_turn(auth(First), <<"unknown">>, <<"late">>)),
        ?assertEqual(false, maps:get(<<"pending">>, ae_store:recovery())),
        ?assertEqual(1, length([ok || {_, <<"restore_verified">>, _} <- ae_store:events()])),
        {ok, Next} = ae_store:activate(ae_store:routing(), <<"replacement">>),
        ?assertEqual(1002, maps:get(<<"epoch">>, Next))
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.

auth(Route) -> {maps:get(<<"slot">>, Route), maps:get(<<"runtime_instance_id">>, Route), maps:get(<<"epoch">>, Route)}.
