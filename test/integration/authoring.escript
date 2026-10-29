#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Scenario, LimitsPath]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    logger:remove_handler(default),
    application:load(ae_core), Config = ae_config:load(),
    application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core),
    {ok, Encoded} = file:read_file(LimitsPath), Limits = jsx:decode(Encoded, [return_maps]),
    Created = case Scenario of
        "orchestrated-rollback" ->
            wait_engine(erlang:monotonic_time(millisecond) + 10000),
            ae_evolution:trigger(list_to_binary(Scenario), <<"Improve the greeting; preserve existing behavior.">>);
        _ -> ae_store:evolution({create, ae_store:routing(), list_to_binary(Scenario),
            <<"Improve the greeting; preserve existing behavior.">>, Limits}) end,
    {ok, Job} = Created,
    Id = maps:get(<<"id">>, Job),
    Result = case Scenario of
        "orchestrated-rollback" ->
            wait_phase(Id, [<<"testing">>, <<"evaluated">>, <<"staging">>, <<"awaiting_approval">>],
                erlang:monotonic_time(millisecond) + maps:get(<<"total_ms">>, Limits)),
            {ok, <<"conversation still works">>} = ae_router:turn(<<"orchestrated-during-eval">>, <<"test">>, <<"hello">>),
            wait_phase(Id, [<<"awaiting_approval">>], erlang:monotonic_time(millisecond) + maps:get(<<"total_ms">>, Limits)),
            {ok, EJob} = ae_evolution:job(Id),
            Summary = #{<<"evolution_job">> => Id, <<"deployment_id">> => maps:get(<<"deployment_id">>, EJob),
                <<"approval_binding">> => maps:get(<<"approval_binding">>, EJob)},
            R = deploy_and_rollback(Id, Summary), ok = ae_evolution:set_enabled(false),
            {error, evolution_disabled} = ae_evolution:trigger(<<"disabled-trigger">>, <<"must not run">>), R;
        "cache" -> check_cache(Id);
        "builder-unavailable" ->
            {ok, _} = ae_router:author(Id),
            {ok, Pid} = ae_build_sup:start_job(Id, Config, self()),
            Ref = monitor(process, Pid),
            BuildResult = receive {ae_build_result, Id, R} -> R after 15000 -> error(builder_did_not_finish) end,
            receive {'DOWN', Ref, process, Pid, normal} -> ok after 5000 -> error(builder_did_not_stop) end,
            BuildResult;
        Scenario0 when Scenario0 =:= "builder-success"; Scenario0 =:= "evaluator-success";
                Scenario0 =:= "evaluator-unavailable"; Scenario0 =:= "deployment-rollback" ->
            {ok, _} = ae_router:author(Id),
            {ok, Pid} = ae_build_sup:start_job(Id, Config, self()), Ref = monitor(process, Pid),
            Wait = maps:get(<<"total_ms">>, Limits),
            Built = receive {ae_build_result, Id, {ok, J}} -> J;
                            {ae_build_result, Id, Error} -> error(Error)
                    after Wait -> error(builder_did_not_finish) end,
            receive {'DOWN', Ref, process, Pid, normal} -> ok after 5000 -> error(builder_did_not_stop) end,
            Manifest = maps:get(<<"built_artifact">>, Built),
            {error, independent_evaluation_required} = ae_store:new_deployment(ae_store:routing(), Manifest,
                #{<<"approval_ttl_ms">> => 60000, <<"observe_ms">> => 60000}),
            case Scenario of
                "builder-success" -> {ok, Manifest};
                _ ->
                    {ok, EvalPid} = ae_eval_sup:start_job(Id, Config, self()), EvalRef = monitor(process, EvalPid),
                    {ok, <<"conversation still works">>} = ae_router:turn(list_to_binary(Scenario ++ "-during-eval"), <<"test">>, <<"hello">>),
                    Evaluated = receive {ae_evaluation_result, Id, ER} -> ER after Wait -> error(evaluator_did_not_finish) end,
                    receive {'DOWN', EvalRef, process, EvalPid, normal} -> ok after 5000 -> error(evaluator_did_not_stop) end,
                    case Evaluated of
                        {ok, _} -> {error, independent_evaluation_required} = ae_store:new_deployment(ae_store:routing(), Manifest,
                            #{<<"approval_ttl_ms">> => 60000, <<"observe_ms">> => 60000});
                        _ -> ok
                    end,
                    false = code:is_loaded(seed_agent),
                    case Scenario of "deployment-rollback" -> deploy_and_rollback(Id); _ -> Evaluated end
            end;
        "repair" ->
            {ok, #{<<"attempt">> := 1}} = ae_router:author(Id),
            {ok, _} = ae_store:evolution({attempt_result, Id, 1, <<"build_failed">>, <<"public compiler diagnostic">>}),
            ae_router:author(Id);
        _ -> ae_router:author(Id)
    end,
    Saved = ae_store:evolution({get, Id}),
    case maps:get(<<"status">>, Saved) of
        Phase when Phase =:= <<"building">>; Phase =:= <<"testing">>; Phase =:= <<"evaluated">> ->
            {error, invalid_job_state} = ae_router:author(Id);
        _ -> ok
    end,
    %% Accepted proposal retransmission must never allocate a second build.
    Replay = case Result of
        {ok, Record} when is_map_key(<<"patch">>, Record) ->
            Route = ae_store:routing(),
            Auth = {maps:get(<<"slot">>, Route), maps:get(<<"runtime_instance_id">>, Route), maps:get(<<"epoch">>, Route)},
            Proposal = maps:without([<<"attempt">>, <<"patch_hash">>, <<"paths">>], Record),
            {ok, {existing, Record}} = ae_store:evolution({proposal, Auth, Id, Proposal}), true;
        _ -> false
    end,
    %% The production conversation path remains usable after authoring finishes.
    Conversation = ae_router:turn(list_to_binary(Scenario ++ "-turn"), <<"test">>, <<"hello">>),
    io:put_chars([jsx:encode(#{<<"result">> => render(Result), <<"job">> => Saved,
        <<"duplicate_reused">> => Replay, <<"conversation">> => render(Conversation),
        <<"status">> => ae_router:status()}), "\n"]),
    application:stop(ae_core).
deploy_and_rollback(Id) ->
    {ok, Summary} = ae_deployment:stage_evolution(Id),
    deploy_and_rollback(Id, Summary).
deploy_and_rollback(Id, Summary) ->
    Base = ae_store:routing(),
    Id = maps:get(<<"evolution_job">>, Summary), DepId = maps:get(<<"deployment_id">>, Summary),
    {error, approval_mismatch} = ae_deployment:approve(DepId, <<"wrong-evaluation-approval">>),
    Base = ae_store:routing(),
    {ok, <<"conversation still works">>} = ae_router:turn(<<"awaiting-approval">>, <<"test">>, <<"hello">>),
    {ok, Promoted} = ae_deployment:approve(DepId, maps:get(<<"approval_binding">>, Summary)),
    <<"eve">> = maps:get(<<"slot">>, Promoted),
    {ok, <<"authored:conversation still works">>} = ae_router:turn(<<"candidate-ack">>, <<"test">>, <<"hello">>),
    #{<<"os_pid">> := OsPid} = ae_router:status(),
    os:cmd("kill -9 " ++ integer_to_list(OsPid)),
    wait_rollback(Id, erlang:monotonic_time(millisecond) + 120000),
    Restored = ae_store:routing(), <<"adam">> = maps:get(<<"slot">>, Restored),
    true = maps:get(<<"epoch">>, Restored) > maps:get(<<"epoch">>, Promoted),
    {ok, <<"authored:conversation still works">>} = ae_router:turn(<<"candidate-ack">>, <<"test">>, <<"hello">>),
    [#{<<"text">> := <<"conversation still works">>}] = [Result || {_, <<"tool_result">>,
        #{<<"request_id">> := <<"candidate-ack">>, <<"key">> := <<"llm">>, <<"result">> := Result}} <- ae_store:events()],
    {ok, #{<<"rolled_back">> => true, <<"acknowledged_reply_retained">> => true}}.
wait_engine(Deadline) ->
    case ae_evolution:status() of
        #{<<"state">> := <<"recovering">>} -> true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 20 -> wait_engine(Deadline) end;
        _ -> ok end.
wait_phase(Id, Phases, Deadline) ->
    Job = ae_store:evolution({get, Id}), Status = maps:get(<<"status">>, Job),
    case lists:member(Status, Phases) of
        true -> ok;
        false ->
            false = lists:member(Status, [<<"rejected">>, <<"cancelled">>, <<"degraded">>]),
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 50 -> wait_phase(Id, Phases, Deadline) end
    end.
wait_rollback(Id, Deadline) ->
    case ae_store:evolution({get, Id}) of
        #{<<"status">> := <<"rolled_back">>} -> ok;
        _ -> true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 50 -> wait_rollback(Id, Deadline) end
    end.
check_cache(Id) ->
    Route = ae_store:routing(), Artifact = maps:get(<<"artifact">>, Route),
    Auth = {maps:get(<<"slot">>, Route), maps:get(<<"runtime_instance_id">>, Route), maps:get(<<"epoch">>, Route)},
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"cache-test">>}],
    Args = #{<<"job_id">> => Id, <<"base_artifact">> => maps:get(<<"digest">>, Artifact),
        <<"base_source_revision">> => maps:get(<<"source_revision">>, Artifact),
        <<"call_id">> => <<"call-1">>, <<"messages">> => Messages},
    Envelope = #{<<"protocol_version">> => 1, <<"type">> => <<"tool_request">>,
        <<"request_id">> => Id, <<"epoch">> => maps:get(<<"epoch">>, Route), <<"tool">> => <<"evolution_llm">>,
        <<"idempotency_key">> => <<"call-1">>, <<"args">> => Args},
    {ok, Cached} = ae_tool_broker:request_evolution(Auth, Id, Envelope),
    {ok, Cached} = ae_tool_broker:request_evolution(Auth, Id, Envelope),
    {error, call_conflict} = ae_tool_broker:request_evolution(Auth, Id,
        Envelope#{<<"args">> := Args#{<<"messages">> := [#{<<"role">> => <<"user">>, <<"content">> => <<"changed">>}]}}),
    {ok, reserved} = ae_store:evolution({reserve_llm, Auth, Id, <<"unknown">>, ae_policy:digest(Messages)}),
    {error, llm_outcome_unknown} = ae_tool_broker:request_evolution(Auth, Id,
        Envelope#{<<"idempotency_key">> := <<"unknown">>, <<"args">> := Args#{<<"call_id">> := <<"unknown">>}}),
    {ok, #{<<"cached">> => true, <<"unknown_not_reissued">> => true}}.
render({ok, Value}) -> #{<<"ok">> => Value};
render({error, Reason}) when is_atom(Reason) -> #{<<"error">> => atom_to_binary(Reason, utf8)};
render({error, Reason}) -> #{<<"error">> => Reason}.
