#!/usr/bin/env escript
%%! +S 2:2 +A 1
main([Scenario, LimitsPath]) ->
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    logger:remove_handler(default),
    application:load(ae_core), Config = ae_config:load(),
    application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core),
    {ok, Encoded} = file:read_file(LimitsPath), Limits = jsx:decode(Encoded, [return_maps]),
    {ok, Job} = ae_store:evolution({create, ae_store:routing(), list_to_binary(Scenario),
        <<"Improve the greeting; preserve existing behavior.">>, Limits}),
    Id = maps:get(<<"id">>, Job),
    Result = case Scenario of
        "cache" -> check_cache(Id);
        "builder-unavailable" ->
            {ok, _} = ae_router:author(Id),
            {ok, Pid} = ae_build_sup:start_job(Id, Config, self()),
            Ref = monitor(process, Pid),
            BuildResult = receive {ae_build_result, Id, R} -> R after 15000 -> error(builder_did_not_finish) end,
            receive {'DOWN', Ref, process, Pid, normal} -> ok after 5000 -> error(builder_did_not_stop) end,
            BuildResult;
        Scenario0 when Scenario0 =:= "builder-success"; Scenario0 =:= "evaluator-success"; Scenario0 =:= "evaluator-unavailable" ->
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
                    false = code:is_loaded(seed_agent), Evaluated
            end;
        "repair" ->
            {ok, #{<<"attempt">> := 1}} = ae_router:author(Id),
            {ok, _} = ae_store:evolution({attempt_result, Id, 1, <<"build_failed">>, <<"public compiler diagnostic">>}),
            ae_router:author(Id);
        _ -> ae_router:author(Id)
    end,
    Saved = ae_store:evolution({get, Id}),
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
