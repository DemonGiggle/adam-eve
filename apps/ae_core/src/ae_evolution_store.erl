-module(ae_evolution_store).
-export([schema/0, dispatch/2]).

%% Called ONLY inside ae_store's transaction. No agent can call this module over
%% IPC. Reservations pessimistically consume budget; a crash never refunds them.
dispatch(Db, {create, Expected, Origin, Objective, Limits}) ->
    {ok, _} = need_limits(Limits),
    need(text(Origin, 256) andalso text(Objective, 16384), invalid_objective),
    case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE origin_ref=?", [Origin]) of
        [{Data}] ->
            Existing = jsx:decode(Data, [return_maps]),
            need(maps:get(<<"objective">>, Existing) =:= Objective andalso
                 maps:get(<<"limits">>, Existing) =:= Limits andalso
                 ae_policy:same_baseline(maps:get(<<"baseline">>, Existing), Expected), origin_conflict),
            {ok, {existing, Existing}};
        [] -> create(Db, Expected, Origin, Objective, Limits)
    end;
dispatch(Db, {get, Id}) -> get(Db, Id);
dispatch(Db, {find_origin, Origin}) ->
    need(text(Origin, 256), invalid_objective),
    case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE origin_ref=?", [Origin]) of
        [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end;
dispatch(Db, mode) ->
    case ae_sql:rows(Db, "SELECT data FROM control WHERE name='evolution_enabled'", []) of
        [] -> true; [{Data}] -> jsx:decode(Data) end;
dispatch(Db, {set_retention, Policy}) ->
    need(ae_storage:validate_retention(Policy) =:= {ok, Policy}, retention_policy_required),
    Encoded = jsx:encode(Policy),
    case ae_sql:rows(Db, "SELECT data FROM control WHERE name='retention_policy'", []) of
        [{Encoded}] -> ok;
        _ -> ae_sql:exec(Db, "INSERT OR REPLACE INTO control VALUES('retention_policy',?)", [Encoded]),
            event(Db, <<"retention_policy_configured">>, Policy), ok
    end;
dispatch(Db, {set_mode, Value}) when is_boolean(Value) ->
    ae_sql:exec(Db, "INSERT OR REPLACE INTO control VALUES('evolution_enabled',?)", [jsx:encode(Value)]),
    case {Value, active(Db)} of
        {false, Job} when is_map(Job) -> close_candidate_admission(Db, Job);
        _ -> ok end,
    event(Db, <<"evolution_mode_changed">>, #{<<"enabled">> => Value}), ok;
dispatch(Db, {request_cancel, Id, Reason}) ->
    Job = must_get(Db, Id), need(text(Reason, 256), invalid_cancellation_reason),
    case {terminal(Job), maps:is_key(<<"deployment_id">>, Job)} of
        {true, _} -> {ok, Job};
        {false, false} -> finish(Db, Job, <<"cancelled">>, Reason), {ok, get(Db, Id)};
        {false, true} ->
            New = Job#{<<"cancel_requested">> => true, <<"cancellation_reason">> => Reason},
            close_candidate_admission(Db, Job), save(Db, New),
            event(Db, <<"evolution_cancel_requested">>, #{<<"job_id">> => Id, <<"reason">> => Reason}), {ok, New}
    end;
dispatch(Db, {degraded, Id, Reason}) ->
    Job = must_get(Db, Id), need(not terminal(Job) andalso maps:is_key(<<"deployment_id">>, Job), invalid_job_state),
    close_candidate_admission(Db, Job),
    New = Job#{<<"status">> := <<"degraded">>, <<"reason">> => Reason}, save(Db, New),
    event(Db, <<"evolution_degraded">>, #{<<"job_id">> => Id, <<"reason">> => Reason}), {ok, New};
dispatch(Db, active) -> active(Db);
dispatch(Db, {reserve_staging, Id, host}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    need(maps:get(<<"status">>, Job) =:= <<"evaluated">>, invalid_job_state),
    Limits = maps:get(<<"limits">>, Job),
    StageKey = execution_key(maps:get(<<"attempts">>, Job), <<"stage">>),
    need(not maps:is_key(StageKey, maps:get(<<"executions">>, Job, #{})), execution_outcome_unknown),
    Remaining = maps:get(<<"cpu_ms">>, Limits) - maps:get(<<"reserved_cpu_ms">>, Job, 0),
    case Remaining > 0 of
        false -> exhaust(Db, Job, <<"staging_cpu_budget">>);
        true ->
            Wall = maps:get(<<"deadline">>, Job) - now_ms(),
            Attempt = maps:get(<<"attempts">>, Job),
            case reserve_execution(Db, Job, Attempt, <<"stage">>, Remaining, Wall) of
                {ok, Lease} when is_map(Lease) ->
                    Bound = Lease#{<<"execution_mode">> => <<"host">>},
                    Reserved = must_get(Db, Id), Executions = maps:get(<<"executions">>, Reserved),
                    save(Db, Reserved#{<<"executions">> := Executions#{StageKey := Bound}}), {ok, Bound};
                Error -> Error
            end
    end;
dispatch(Db, {reserve_staging, Id, RuntimeLimits}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    need(maps:get(<<"status">>, Job) =:= <<"evaluated">>, invalid_job_state),
    Keys = [<<"memory_bytes">>, <<"pids">>, <<"cpu_percent">>, <<"cpu_seconds">>,
        <<"address_space_bytes">>, <<"file_bytes">>, <<"open_files">>, <<"output_bytes">>, <<"wall_ms">>],
    need(is_map(RuntimeLimits) andalso lists:sort(maps:keys(RuntimeLimits)) =:= lists:sort(Keys) andalso
        lists:all(fun(V) -> is_integer(V) andalso V > 0 andalso V < (1 bsl 63) end, maps:values(RuntimeLimits)),
        invalid_staging_limits),
    Limits = maps:get(<<"limits">>, Job),
    StageKey = execution_key(maps:get(<<"attempts">>, Job), <<"stage">>),
    need(not maps:is_key(StageKey, maps:get(<<"executions">>, Job, #{})), execution_outcome_unknown),
    Remaining = maps:get(<<"cpu_ms">>, Limits) - maps:get(<<"reserved_cpu_ms">>, Job, 0),
    case Remaining > 0 of
        false -> exhaust(Db, Job, <<"staging_cpu_budget">>);
        true ->
            Cpu = min(Remaining, maps:get(<<"cpu_seconds">>, RuntimeLimits) * 1000),
            Wall = min(maps:get(<<"wall_ms">>, RuntimeLimits), maps:get(<<"deadline">>, Job) - now_ms()),
            Attempt = maps:get(<<"attempts">>, Job),
            case reserve_execution(Db, Job, Attempt, <<"stage">>, Cpu, Wall) of
                {ok, Lease} when is_map(Lease) ->
                    Effective = RuntimeLimits#{<<"cpu_seconds">> := (Cpu + 999) div 1000, <<"wall_ms">> := maps:get(<<"wall_ms">>, Lease),
                        <<"memory_bytes">> := min(maps:get(<<"memory_bytes">>, RuntimeLimits), maps:get(<<"memory_bytes">>, Limits)),
                        <<"pids">> := min(maps:get(<<"pids">>, RuntimeLimits), maps:get(<<"processes">>, Limits))},
                    Bound = Lease#{<<"runtime_limits">> => Effective},
                    Reserved = must_get(Db, Id), Executions = maps:get(<<"executions">>, Reserved),
                    save(Db, Reserved#{<<"executions">> := Executions#{execution_key(Attempt, <<"stage">>) := Bound}}),
                    {ok, Bound};
                Error -> Error
            end
    end;
dispatch(Db, {for_deployment, Id, Expected}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    need(ae_policy:same_baseline(Expected, maps:get(<<"baseline">>, Job)), stale_baseline),
    need(maps:get(<<"status">>, Job) =:= <<"evaluated">>, independent_evaluation_required),
    {ok, Job, evaluation_record(Job)};
dispatch(Db, {check_deployment, Deployment}) ->
    Job = must_get(Db, maps:get(<<"evolution_job">>, Deployment)),
    need(dispatch(Db, mode) andalso not maps:get(<<"cancel_requested">>, Job, false), evolution_disabled_or_cancelled),
    need(current(Db, Job) =:= ok, stale_or_expired_job),
    need(maps:get(<<"deployment_id">>, Job, null) =:= maps:get(<<"id">>, Deployment), deployment_mismatch),
    check_deployment(Job, Deployment), ok;
dispatch(Db, {deployment_transition, Deployment}) ->
    Id = maps:get(<<"evolution_job">>, Deployment), Job = must_get(Db, Id),
    [{Saved}] = ae_sql:rows(Db, "SELECT data FROM deployments WHERE id=?", [maps:get(<<"id">>, Deployment)]),
    need(jsx:decode(Saved, [return_maps]) =:= Deployment, deployment_mismatch),
    check_deployment(Job, Deployment),
    Phase = maps:get(<<"status">>, Deployment),
    case maps:get(<<"deployment_id">>, Job, undefined) of
        undefined -> need(maps:get(<<"status">>, Job) =:= <<"evaluated">> andalso Phase =:= <<"staging">>, invalid_job_state);
        DepId -> need(DepId =:= maps:get(<<"id">>, Deployment) andalso not terminal(Job), invalid_job_state)
    end,
    Fields = maps:with([<<"promoted_route">>, <<"rollback_route">>, <<"reason">>, <<"approval_binding">>], Deployment),
    New = maps:merge(Job#{<<"status">> := Phase, <<"deployment_id">> => maps:get(<<"id">>, Deployment)}, Fields),
    Finished = case Phase of
        <<"awaiting_approval">> -> finish_staging(New, <<"completed">>);
        <<"rejected">> -> finish_staging(New, <<"failed">>);
        _ -> New end,
    save(Db, Finished), event(Db, <<"evolution_transition">>, #{<<"job_id">> => Id, <<"status">> => Phase,
        <<"deployment_id">> => maps:get(<<"id">>, Deployment)}), {ok, Finished};
dispatch(Db, {attempt, Id, Number}) ->
    case ae_sql:rows(Db, "SELECT data FROM evolution_proposals WHERE job_id=? AND attempt=?", [Id, Number]) of
        [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end;
dispatch(Db, {reserve_evaluation, Id, Attempt, CpuMs, WallMs, Binding, Configuration}) ->
    need(ae_evaluator:valid_binding(Binding), invalid_evaluation_binding),
    need(ae_evaluator:valid_configuration(Configuration, Binding), invalid_evaluation_configuration),
    case dispatch(Db, {reserve_execution, Id, Attempt, <<"evaluate">>, CpuMs, WallMs}) of
        {ok, Lease} when is_map(Lease) ->
            Job = must_get(Db, Id), Key = execution_key(Attempt, <<"evaluate">>),
            Bound = Lease#{<<"evaluation_binding">> => Binding, <<"evaluation_configuration">> => Configuration},
            Executions = maps:get(<<"executions">>, Job),
            save(Db, Job#{<<"executions">> := Executions#{Key := Bound}}), {ok, Bound};
        Error -> Error
    end;
dispatch(Db, {reserve_execution, Id, Attempt, Kind, CpuMs, WallMs}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    need(lists:member(Kind, [<<"build">>, <<"evaluate">>]), invalid_execution_kind),
    need(maps:get(<<"attempts">>, Job) =:= Attempt andalso Attempt > 0, invalid_attempt),
    Expected = case Kind of <<"build">> -> <<"building">>; <<"evaluate">> -> <<"testing">> end,
    need(maps:get(<<"status">>, Job) =:= Expected, invalid_job_state),
    reserve_execution(Db, Job, Attempt, Kind, CpuMs, WallMs);
dispatch(Db, {finish_build, Id, Attempt, LeaseId, Manifest}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    {Key, Lease} = execution(Job, Attempt, <<"build">>, LeaseId),
    need(maps:get(<<"status">>, Job) =:= <<"building">>, invalid_job_state),
    need(maps:get(<<"status">>, Lease) =:= <<"reserved">>, execution_finished),
    need(now_ms() =< maps:get(<<"expires_at_ms">>, Lease), execution_expired),
    Base = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
    Proposal = dispatch(Db, {attempt, Id, Attempt}),
    need(is_map(Manifest) andalso byte_size(jsx:encode(Manifest)) =< 65536, invalid_build_manifest),
    need(maps:get(<<"authoring">>, Manifest, null) =:= <<"llm">> andalso
        maps:get(<<"parent">>, Manifest, null) =:= maps:get(<<"digest">>, Base) andalso
        maps:get(<<"producing_job">>, Manifest, null) =:= Id andalso
        maps:get(<<"producing_attempt">>, Manifest, null) =:= Attempt andalso
        maps:get(<<"patch_hash">>, Manifest, null) =:= maps:get(<<"patch_hash">>, Proposal) andalso
        maps:get(<<"capabilities">>, Manifest, null) =:= maps:get(<<"capabilities">>, Base, []) andalso
        maps:get(<<"state_schema_versions">>, Manifest, null) =:= [1] andalso
        maps:get(<<"evaluation">>, Manifest, missing) =:= null andalso
        hex(maps:get(<<"digest">>, Manifest, null)) andalso
        hex40(maps:get(<<"source_revision">>, Manifest, null)) andalso
        hex40(maps:get(<<"source_tree">>, Manifest, null)), invalid_build_manifest),
    Executions = maps:get(<<"executions">>, Job),
    New = Job#{<<"status">> := <<"testing">>, <<"built_artifact">> => Manifest,
        <<"executions">> := Executions#{Key := Lease#{<<"status">> := <<"completed">>,
            <<"artifact_digest">> => maps:get(<<"digest">>, Manifest)}}},
    save(Db, New), event(Db, <<"candidate_built">>, #{<<"job_id">> => Id, <<"attempt">> => Attempt,
        <<"artifact_digest">> => maps:get(<<"digest">>, Manifest), <<"execution_id">> => LeaseId}), {ok, New};
dispatch(Db, {finish_evaluation, Id, Attempt, LeaseId, Scorecard}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    {Key, Lease} = execution(Job, Attempt, <<"evaluate">>, LeaseId),
    need(maps:get(<<"status">>, Job) =:= <<"testing">>, invalid_job_state),
    need(maps:get(<<"status">>, Lease) =:= <<"reserved">>, execution_finished),
    need(now_ms() =< maps:get(<<"expires_at_ms">>, Lease), execution_expired),
    need(ae_evaluator:valid_result(Scorecard, Job, Lease), invalid_evaluation_result),
    Hash = ae_policy:digest(Scorecard), Executions = maps:get(<<"executions">>, Job),
    Results = maps:get(<<"evaluations">>, Job, #{}),
    Updated = Job#{<<"evaluations">> => Results#{integer_to_binary(Attempt) =>
            #{<<"digest">> => Hash, <<"scorecard">> => Scorecard}},
        <<"executions">> := Executions#{Key := Lease#{<<"status">> := <<"completed">>, <<"evaluation_digest">> => Hash}}},
    save(Db, Updated), event(Db, <<"candidate_evaluated">>, #{<<"job_id">> => Id,
        <<"attempt">> => Attempt, <<"evaluation_digest">> => Hash, <<"passed">> => maps:get(<<"passed">>, Scorecard)}),
    case maps:get(<<"passed">>, Scorecard) of
        true -> New = Updated#{<<"status">> := <<"evaluated">>, <<"evaluation_digest">> => Hash},
            save(Db, New), {ok, New};
        false ->
            Summary = <<"Independent evaluation did not meet the configured gates.">>,
            Max = maps:get(<<"max_diagnostic_bytes">>, maps:get(<<"limits">>, Job)),
            attempt_result(Db, Updated, Attempt, <<"tests_failed">>, binary:part(Summary, 0, min(Max, byte_size(Summary))))
    end;
dispatch(Db, {execution_failed, Id, Attempt, Kind, LeaseId, Reason, PublicDiagnostics}) ->
    Job = must_get(Db, Id), need(current(Db, Job) =:= ok, stale_or_expired_job),
    {Key, Lease} = execution(Job, Attempt, Kind, LeaseId),
    need(maps:get(<<"status">>, Lease) =:= <<"reserved">>, execution_finished),
    need(text(Reason, 256), invalid_execution_reason),
    Protected = lists:member(Reason, [<<"protected_patch">>, <<"unsafe_source_tree">>, <<"patch_scope_mismatch">>,
        <<"protected_source_tree">>, <<"attempt_source_conflict">>]),
    Outcome = case {Protected, Kind} of
        {true, _} -> <<"rejected">>; {false, <<"build">>} -> <<"build_failed">>; {false, <<"evaluate">>} -> <<"tests_failed">> end,
    Executions = maps:get(<<"executions">>, Job),
    Updated = Job#{<<"executions">> := Executions#{Key := Lease#{<<"status">> := <<"failed">>, <<"reason">> => Reason}}},
    save(Db, Updated), attempt_result(Db, Updated, Attempt, Outcome, PublicDiagnostics);
dispatch(Db, {authorize, Auth, Id}) -> authorized(Db, Auth, Id);
dispatch(Db, {source_violation, Auth, Id}) ->
    case authorized(Db, Auth, Id) of
        {ok, #{<<"status">> := <<"proposing">>} = Job} ->
            finish(Db, Job, <<"rejected">>, <<"protected_source">>), {error, protected_source};
        {ok, _} -> {error, invalid_job_state};
        Error -> Error
    end;
dispatch(Db, {cancel, Id, Reason}) ->
    Job = must_get(Db, Id), need(not terminal(Job), job_finished),
    need(not maps:is_key(<<"deployment_id">>, Job), job_in_deployment),
    finish(Db, Job, <<"cancelled">>, Reason), ok;
dispatch(Db, {source_reserve, Auth, Id}) ->
    case authorized(Db, Auth, Id) of
        {ok, #{<<"status">> := <<"proposing">>} = Job} ->
            Limits = maps:get(<<"limits">>, Job),
            Bytes = maps:get(<<"source_page_bytes">>, Limits),
            case maps:get(<<"source_calls">>, Job) < maps:get(<<"max_source_calls">>, Limits) andalso
                 maps:get(<<"source_bytes">>, Job) + Bytes =< maps:get(<<"max_source_bytes">>, Limits) of
                true ->
                    New = Job#{<<"source_calls">> := maps:get(<<"source_calls">>, Job) + 1,
                               <<"source_bytes">> := maps:get(<<"source_bytes">>, Job) + Bytes},
                    save(Db, New), event(Db, <<"source_budget_reserved">>, #{<<"job_id">> => Id, <<"bytes">> => Bytes}),
                    {ok, New};
                false -> exhaust(Db, Job, <<"source_budget">>)
            end;
        {ok, _} -> {error, invalid_job_state};
        Error -> Error
    end;
dispatch(Db, {reserve_llm, Auth, Id, CallId, RequestHash}) ->
    need(text(CallId, 256) andalso hex(RequestHash), invalid_call),
    case authorized(Db, Auth, Id) of
        {ok, #{<<"status">> := <<"proposing">>} = Job} -> reserve_llm(Db, Job, CallId, RequestHash);
        {ok, _} -> {error, invalid_job_state}; Error -> Error
    end;
dispatch(Db, {finish_llm, Auth, Id, CallId, Result}) ->
    case authorized(Db, Auth, Id) of
        {ok, Job} ->
            need(is_map(Result) andalso byte_size(jsx:encode(Result)) =< 1048576, oversized_result),
            case call_record(Db, Id, CallId) of
                #{<<"status">> := <<"reserved">>} = Call ->
                    store_call(Db, Id, CallId, Call#{<<"status">> := <<"completed">>, <<"result">> => Result}),
                    event(Db, <<"evolution_llm_result">>, #{<<"job_id">> => Id, <<"call_id">> => CallId}),
                    {ok, Job};
                #{<<"status">> := <<"completed">>, <<"result">> := Result} -> {ok, Job};
                _ -> {error, invalid_call_state}
            end;
        Error -> Error
    end;
dispatch(Db, {proposal, Auth, Id, Proposal}) ->
    case authorized(Db, Auth, Id) of
        {ok, Job} -> accept_proposal(Db, Job, Proposal);
        Error -> Error
    end;
dispatch(Db, {attempt_result, Id, Attempt, Outcome, PublicDiagnostics}) ->
    Job = must_get(Db, Id),
    case current(Db, Job) of
        ok -> attempt_result(Db, Job, Attempt, Outcome, PublicDiagnostics);
        Reason ->
            cancel_unlinked(Db, Job, Reason),
            {error, Reason}
    end;
dispatch(Db, reconcile) ->
    case active(Db) of
        undefined -> ok;
        %% A linked deployment owns its own expiry, recovery and rollback. Never
        %% cancel it between the routing commit and its transactional job update.
        #{<<"deployment_id">> := _} = Job -> {ok, Job};
        Job -> case current(Db, Job) of
            ok -> {ok, Job};
            Reason -> finish(Db, Job, <<"cancelled">>, Reason), {error, Reason}
        end
    end;
dispatch(_, _) -> {error, invalid_evolution_operation}.

attempt_result(Db, Job, Attempt, Outcome, PublicDiagnostics) ->
    Id = maps:get(<<"id">>, Job),
    need(lists:member(maps:get(<<"status">>, Job), [<<"building">>, <<"testing">>]) andalso maps:get(<<"attempts">>, Job) =:= Attempt,
         invalid_attempt),
    need(lists:member(Outcome, [<<"build_failed">>, <<"tests_failed">>, <<"rejected">>]), invalid_outcome),
    %% Only public compiler/test summaries belong here. Private evaluator output
    %% is stored separately and must never be passed into this interface.
    need(text_or_empty(PublicDiagnostics, maps:get(<<"max_diagnostic_bytes">>, maps:get(<<"limits">>, Job))),
         oversized_diagnostics),
    event(Db, <<"evolution_attempt_result">>, #{<<"job_id">> => Id, <<"attempt">> => Attempt, <<"outcome">> => Outcome}),
    Limits = maps:get(<<"limits">>, Job),
    case Outcome =/= <<"rejected">> andalso maps:get(<<"attempts">>, Job) < maps:get(<<"max_attempts">>, Limits) of
        true -> New = Job#{<<"status">> := <<"proposing">>, <<"public_diagnostics">> => PublicDiagnostics},
            save(Db, New), {ok, New};
        false -> finish(Db, Job, <<"rejected">>, Outcome), {error, job_rejected}
    end.

create(Db, Expected, Origin, Objective, Limits) ->
    need(ae_policy:same_baseline(route(Db), Expected), stale_baseline),
    need(not ae_sql:recovery_pending(Db), restore_verification_required),
    need(maps:get(<<"admission">>, route(Db), <<"open">>) =:= <<"open">>, quiescing),
    need(active(Db) =:= undefined, evolution_in_progress),
    need(ae_sql:rows(Db, "SELECT id FROM deployments WHERE status NOT IN ('completed','rejected','rolled_back')", []) =:= [],
         deployment_in_progress),
    Id = ae_policy:digest(#{<<"nonce">> => base64:encode(crypto:strong_rand_bytes(32))}),
    Job = #{<<"id">> => Id, <<"status">> => <<"proposing">>, <<"origin_ref">> => Origin,
        <<"objective">> => Objective, <<"baseline">> => ae_policy:baseline(Expected), <<"limits">> => Limits,
        <<"target_slot">> => ae_policy:other_slot(maps:get(<<"slot">>, Expected)),
        <<"deadline">> => now_ms() + maps:get(<<"total_ms">>, Limits),
        <<"attempts">> => 0, <<"llm_calls">> => 0, <<"reserved_tokens">> => 0,
        <<"reserved_cost_microunits">> => 0, <<"source_calls">> => 0, <<"source_bytes">> => 0},
    save(Db, Job), event(Db, <<"evolution_started">>, Job), {ok, Job}.

reserve_llm(Db, Job, CallId, Hash) ->
    Id = maps:get(<<"id">>, Job),
    case call_record(Db, Id, CallId) of
        #{<<"request_hash">> := Hash, <<"status">> := <<"completed">>, <<"result">> := Result} -> {ok, {completed, Result}};
        #{<<"request_hash">> := Hash} -> {error, llm_outcome_unknown};
        Existing when Existing =/= undefined -> {error, call_conflict};
        undefined ->
            Limits = maps:get(<<"limits">>, Job),
            Tokens = maps:get(<<"tokens_per_call">>, Limits), Cost = maps:get(<<"cost_per_call_microunits">>, Limits),
            case maps:get(<<"llm_calls">>, Job) < maps:get(<<"max_llm_calls">>, Limits) andalso
                 maps:get(<<"reserved_tokens">>, Job) + Tokens =< maps:get(<<"max_tokens">>, Limits) andalso
                 maps:get(<<"reserved_cost_microunits">>, Job) + Cost =< maps:get(<<"max_cost_microunits">>, Limits) of
                true ->
                    New = Job#{<<"llm_calls">> := maps:get(<<"llm_calls">>, Job) + 1,
                        <<"reserved_tokens">> := maps:get(<<"reserved_tokens">>, Job) + Tokens,
                        <<"reserved_cost_microunits">> := maps:get(<<"reserved_cost_microunits">>, Job) + Cost},
                    save(Db, New), store_call(Db, Id, CallId, #{<<"request_hash">> => Hash, <<"status">> => <<"reserved">>}),
                    event(Db, <<"evolution_llm_reserved">>, #{<<"job_id">> => Id, <<"call_id">> => CallId,
                        <<"tokens">> => Tokens, <<"cost_microunits">> => Cost}), {ok, reserved};
                false -> exhaust(Db, Job, <<"llm_budget">>)
            end
    end.

accept_proposal(Db, Job, Proposal) ->
    need(is_map(Proposal) andalso byte_size(jsx:encode(Proposal)) =< 1048576, invalid_proposal),
    Id = maps:get(<<"id">>, Job),
    Key = maps:get(<<"proposal_id">>, Proposal, null), need(text(Key, 256), invalid_proposal),
    Fingerprint = ae_policy:digest(Proposal),
    Existing = ae_sql:rows(Db, "SELECT fingerprint,data FROM evolution_proposals WHERE job_id=? AND proposal_id=?", [Id, Key]),
    case Existing of
        [{Fingerprint, Data}] -> {ok, {existing, jsx:decode(Data, [return_maps])}};
        [_] -> {error, proposal_conflict};
        [] ->
            need(maps:get(<<"status">>, Job) =:= <<"proposing">>, invalid_job_state),
            need(lists:sort(maps:keys(Proposal)) =:= lists:sort([<<"proposal_id">>, <<"base_artifact">>,
                <<"base_source_revision">>, <<"epoch">>, <<"patch">>, <<"hypothesis">>,
                <<"expected_benefit">>, <<"risks">>, <<"requested_tests">>]), invalid_proposal),
            Limits = maps:get(<<"limits">>, Job),
            need(maps:get(<<"attempts">>, Job) < maps:get(<<"max_attempts">>, Limits), attempt_limit),
            Base = maps:get(<<"baseline">>, Job), Artifact = maps:get(<<"artifact">>, Base),
            need(maps:get(<<"base_artifact">>, Proposal, null) =:= maps:get(<<"digest">>, Artifact) andalso
                maps:get(<<"base_source_revision">>, Proposal, null) =:= maps:get(<<"source_revision">>, Artifact) andalso
                maps:get(<<"epoch">>, Proposal, null) =:= maps:get(<<"epoch">>, Base), stale_proposal),
            need(rationale(Proposal), invalid_rationale),
            case ae_patch:validate(maps:get(<<"patch">>, Proposal, null), maps:get(<<"max_patch_bytes">>, Limits)) of
                {ok, Paths} ->
                    Number = maps:get(<<"attempts">>, Job) + 1,
                    Record = Proposal#{<<"attempt">> => Number, <<"patch_hash">> => ae_policy:sha256(maps:get(<<"patch">>, Proposal)),
                                       <<"paths">> => Paths},
                    ae_sql:exec(Db, "INSERT INTO evolution_proposals VALUES(?,?,?,?,?)", [Id, Key, Fingerprint, Number, jsx:encode(Record)]),
                    save(Db, Job#{<<"status">> := <<"building">>, <<"attempts">> := Number}),
                    event(Db, <<"evolution_proposal_accepted">>, #{<<"job_id">> => Id, <<"attempt">> => Number,
                        <<"proposal_id">> => Key, <<"patch_hash">> => maps:get(<<"patch_hash">>, Record)}), {ok, Record};
                {error, Reason} ->
                    Rejected = #{<<"proposal_id">> => Key, <<"outcome">> => atom_to_binary(Reason, utf8),
                        <<"patch_hash">> => patch_hash(maps:get(<<"patch">>, Proposal, null))},
                    ae_sql:exec(Db, "INSERT INTO evolution_proposals VALUES(?,?,?,?,?)", [Id, Key, Fingerprint, 0, jsx:encode(Rejected)]),
                    event(Db, <<"evolution_proposal_rejected">>, Rejected#{<<"job_id">> => Id}),
                    finish(Db, Job, <<"rejected">>, atom_to_binary(Reason, utf8)), {error, Reason}
            end
    end.

authorized(Db, {Slot, Instance, Epoch}, Id) ->
    Route = route(Db),
    need(is_map(Route) andalso maps:get(<<"slot">>, Route) =:= Slot andalso
         maps:get(<<"runtime_instance_id">>, Route) =:= Instance andalso maps:get(<<"epoch">>, Route) =:= Epoch,
         stale_runtime),
    need(not ae_sql:recovery_pending(Db), restore_verification_required),
    need(maps:get(<<"admission">>, Route, <<"open">>) =:= <<"open">>, quiescing),
    Job = must_get(Db, Id),
    Base = maps:get(<<"baseline">>, Job),
    need({Slot, Instance, Epoch} =:= {maps:get(<<"slot">>, Base), maps:get(<<"runtime_instance_id">>, Base),
        maps:get(<<"epoch">>, Base)}, stale_author),
    case current(Db, Job) of
        ok -> {ok, Job};
        Reason ->
            cancel_unlinked(Db, Job, Reason),
            {error, Reason}
    end;
authorized(_, _, _) -> {error, stale_runtime}.
current(Db, Job) ->
    case {terminal(Job), dispatch(Db, mode) andalso not maps:get(<<"cancel_requested">>, Job, false)} of
        {true, _} -> job_finished;
        {false, false} -> evolution_disabled_or_cancelled;
        {false, true} ->
            Expected = case maps:get(<<"status">>, Job) of
                Phase when Phase =:= <<"observing">>; Phase =:= <<"rollback">>; Phase =:= <<"degraded">> ->
                    maps:get(<<"promoted_route">>, Job, maps:get(<<"baseline">>, Job));
                _ -> maps:get(<<"baseline">>, Job) end,
            case ae_policy:same_baseline(route(Db), Expected) of
            false -> stale_baseline;
            true -> case now_ms() < maps:get(<<"deadline">>, Job) of true -> ok; false -> job_expired end
        end
    end.
cancel_unlinked(Db, Job, Reason) ->
    case terminal(Job) orelse maps:is_key(<<"deployment_id">>, Job) of
        true -> ok;
        false -> finish(Db, Job, <<"cancelled">>, Reason)
    end.
close_candidate_admission(Db, Job) ->
    case maps:find(<<"promoted_route">>, Job) of
        {ok, Promoted} ->
            case ae_policy:same_baseline(route(Db), Promoted) of
                true -> ae_sql:exec(Db, "UPDATE routing SET data=? WHERE id=1", [jsx:encode((route(Db))#{<<"admission">> => <<"closed">>})]);
                false -> ok end;
        error -> ok end.
finish_staging(Job, Status) ->
    Executions = maps:get(<<"executions">>, Job), Key = execution_key(maps:get(<<"attempts">>, Job), <<"stage">>),
    case maps:get(Key, Executions, undefined) of
        #{<<"status">> := <<"reserved">>} = Lease ->
            Job#{<<"executions">> := Executions#{Key := Lease#{<<"status">> := Status}}};
        _ -> Job end.
evaluation_record(Job) ->
    Attempt = maps:get(<<"attempts">>, Job),
    Record = maps:get(integer_to_binary(Attempt), maps:get(<<"evaluations">>, Job, #{}), undefined),
    need(is_map(Record), independent_evaluation_required),
    Score = maps:get(<<"scorecard">>, Record), Hash = maps:get(<<"digest">>, Record),
    Lease = maps:get(execution_key(Attempt, <<"evaluate">>), maps:get(<<"executions">>, Job)),
    need(Hash =:= maps:get(<<"evaluation_digest">>, Job) andalso Hash =:= ae_policy:digest(Score) andalso
        maps:get(<<"passed">>, Score) =:= true andalso maps:get(<<"status">>, Lease) =:= <<"completed">> andalso
        maps:get(<<"evaluation_digest">>, Lease) =:= Hash andalso ae_evaluator:valid_result(Score, Job, Lease),
        invalid_evaluation_result), Record.
check_deployment(Job, Deployment) ->
    need(maps:get(<<"candidate">>, Deployment) =:= maps:get(<<"built_artifact">>, Job) andalso
        ae_policy:same_baseline(maps:get(<<"baseline">>, Deployment), maps:get(<<"baseline">>, Job)) andalso
        maps:get(<<"independent_evaluation">>, Deployment) =:= evaluation_record(Job), evaluation_mismatch).
rationale(P) ->
    lists:all(fun(K) -> text(maps:get(K, P, null), 4096) end, [<<"hypothesis">>, <<"expected_benefit">>]) andalso
    lists:all(fun(K) -> V = maps:get(K, P, null), is_list(V) andalso length(V) =< 32 andalso
        lists:all(fun(X) -> text(X, 256) end, V) end, [<<"risks">>, <<"requested_tests">>]).
need_limits(Limits) -> case ae_evolution_limits:validate(Limits) of {ok, _} = Ok -> Ok; Error -> throw(Error) end.
text(V, Max) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< Max.
text_or_empty(V, Max) -> is_binary(V) andalso byte_size(V) =< Max.
hex(V) -> is_binary(V) andalso re:run(V, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match.
hex40(V) -> is_binary(V) andalso re:run(V, <<"^[0-9a-f]{40}$">>, [{capture, none}]) =:= match.

reserve_execution(Db, Job, Attempt, Kind, CpuMs, RequestedWall) ->
    Limits = maps:get(<<"limits">>, Job),
    Started = now_ms(),
    WallMs = case Kind of <<"stage">> -> min(RequestedWall, maps:get(<<"deadline">>, Job) - Started); _ -> RequestedWall end,
    need(is_integer(CpuMs) andalso CpuMs > 0 andalso is_integer(WallMs) andalso WallMs > 0, invalid_execution_budget),
    Ceiling = case Kind of <<"build">> -> <<"build_ms">>; <<"evaluate">> -> <<"evaluation_ms">>; <<"stage">> -> <<"total_ms">> end,
    need(WallMs =< maps:get(Ceiling, Limits) andalso Started + WallMs =< maps:get(<<"deadline">>, Job), invalid_execution_budget),
    Key = execution_key(Attempt, Kind), Executions = maps:get(<<"executions">>, Job, #{}),
    case maps:get(Key, Executions, undefined) of
        undefined ->
            Reserved = maps:get(<<"reserved_cpu_ms">>, Job, 0),
            case Reserved + CpuMs =< maps:get(<<"cpu_ms">>, Limits) of
                true ->
                    Lease = #{<<"id">> => ae_policy:sha256(crypto:strong_rand_bytes(32)),
                        <<"job_id">> => maps:get(<<"id">>, Job), <<"attempt">> => Attempt, <<"kind">> => Kind,
                        <<"status">> => <<"reserved">>, <<"cpu_ms">> => CpuMs, <<"wall_ms">> => WallMs,
                        <<"reserved_at_ms">> => Started, <<"expires_at_ms">> => Started + WallMs},
                    New = Job#{<<"reserved_cpu_ms">> => Reserved + CpuMs, <<"executions">> => Executions#{Key => Lease}},
                    save(Db, New), event(Db, <<"execution_reserved">>, Lease), {ok, Lease};
                false -> exhaust(Db, Job, <<"cpu_budget">>)
            end;
        #{<<"status">> := <<"reserved">>} -> {error, execution_outcome_unknown};
        Record -> {ok, {completed, Record}}
    end.
execution(Job, Attempt, Kind, LeaseId) ->
    need(maps:get(<<"attempts">>, Job) =:= Attempt, invalid_attempt),
    Key = execution_key(Attempt, Kind),
    Lease = maps:get(Key, maps:get(<<"executions">>, Job, #{}), undefined),
    need(is_map(Lease) andalso maps:get(<<"id">>, Lease) =:= LeaseId, invalid_execution_lease), {Key, Lease}.
execution_key(Attempt, Kind) when is_integer(Attempt), is_binary(Kind) ->
    <<(integer_to_binary(Attempt))/binary, ":", Kind/binary>>.
need(true, _) -> ok;
need(false, Reason) -> throw({error, Reason}).
now_ms() -> erlang:system_time(millisecond).
terminal(Job) -> lists:member(maps:get(<<"status">>, Job), [<<"rejected">>, <<"cancelled">>, <<"completed">>, <<"rolled_back">>]).
get(Db, Id) -> case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE id=?", [Id]) of
    [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
must_get(Db, Id) -> Job = get(Db, Id), need(is_map(Job), unknown_job), Job.
active(Db) -> case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE status NOT IN ('rejected','cancelled','completed','rolled_back')", []) of
    [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
route(Db) -> case ae_sql:rows(Db, "SELECT data FROM routing WHERE id=1", []) of
    [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
save(Db, #{<<"id">> := Id, <<"status">> := Status} = Job) ->
    ae_sql:exec(Db, "INSERT OR REPLACE INTO evolution_jobs VALUES(?,?,?,?)", [Id, maps:get(<<"origin_ref">>, Job), Status, jsx:encode(Job)]).
finish(Db, Job, Status, Reason) ->
    save(Db, Job#{<<"status">> := Status, <<"reason">> => Reason}),
    event(Db, <<"evolution_finished">>, #{<<"job_id">> => maps:get(<<"id">>, Job), <<"status">> => Status, <<"reason">> => Reason}).
exhaust(Db, Job, Reason) -> finish(Db, Job, <<"rejected">>, Reason), {error, budget_exhausted}.
event(Db, Kind, Data) -> ae_sql:event(Db, Kind, Data).
call_record(Db, Id, Call) -> case ae_sql:rows(Db, "SELECT data FROM evolution_llm_calls WHERE job_id=? AND call_id=?", [Id, Call]) of
    [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
store_call(Db, Id, Call, Record) -> ae_sql:exec(Db, "INSERT OR REPLACE INTO evolution_llm_calls VALUES(?,?,?)", [Id, Call, jsx:encode(Record)]).
schema() -> [
    "CREATE TABLE IF NOT EXISTS evolution_jobs(id TEXT PRIMARY KEY,origin_ref TEXT NOT NULL UNIQUE,status TEXT NOT NULL,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS evolution_proposals(job_id TEXT NOT NULL REFERENCES evolution_jobs(id),proposal_id TEXT NOT NULL,"
        "fingerprint TEXT NOT NULL,attempt INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(job_id,proposal_id))",
    "CREATE TABLE IF NOT EXISTS evolution_llm_calls(job_id TEXT NOT NULL REFERENCES evolution_jobs(id),call_id TEXT NOT NULL,"
        "data TEXT NOT NULL,PRIMARY KEY(job_id,call_id))"
].

patch_hash(Patch) when is_binary(Patch) -> ae_policy:sha256(Patch);
patch_hash(Other) -> ae_policy:digest(Other).
