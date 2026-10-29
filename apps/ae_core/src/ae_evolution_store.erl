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
dispatch(Db, active) -> active(Db);
dispatch(Db, {attempt, Id, Number}) ->
    case ae_sql:rows(Db, "SELECT data FROM evolution_proposals WHERE job_id=? AND attempt=?", [Id, Number]) of
        [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end;
dispatch(Db, {authorize, Auth, Id}) -> authorized(Db, Auth, Id);
dispatch(Db, {source_violation, Auth, Id}) ->
    case authorized(Db, Auth, Id) of
        {ok, Job} -> finish(Db, Job, <<"rejected">>, <<"protected_source">>), {error, protected_source};
        Error -> Error
    end;
dispatch(Db, {cancel, Id, Reason}) ->
    Job = must_get(Db, Id), need(not terminal(Job), job_finished),
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
            case terminal(Job) of true -> ok; false -> finish(Db, Job, <<"cancelled">>, Reason) end,
            {error, Reason}
    end;
dispatch(Db, reconcile) ->
    case active(Db) of
        undefined -> ok;
        Job -> case current(Db, Job) of
            ok -> {ok, Job};
            Reason -> finish(Db, Job, <<"cancelled">>, Reason), {error, Reason}
        end
    end;
dispatch(_, _) -> {error, invalid_evolution_operation}.

attempt_result(Db, Job, Attempt, Outcome, PublicDiagnostics) ->
    Id = maps:get(<<"id">>, Job),
    need(maps:get(<<"status">>, Job) =:= <<"building">> andalso maps:get(<<"attempts">>, Job) =:= Attempt,
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
    case current(Db, Job) of
        ok -> {ok, Job};
        Reason ->
            case terminal(Job) of true -> ok; false -> finish(Db, Job, <<"cancelled">>, Reason) end,
            {error, Reason}
    end;
authorized(_, _, _) -> {error, stale_runtime}.
current(Db, Job) ->
    case terminal(Job) of
        true -> job_finished;
        false -> case ae_policy:same_baseline(route(Db), maps:get(<<"baseline">>, Job)) of
            false -> stale_baseline;
            true -> case now_ms() < maps:get(<<"deadline">>, Job) of true -> ok; false -> job_expired end
        end
    end.
rationale(P) ->
    lists:all(fun(K) -> text(maps:get(K, P, null), 4096) end, [<<"hypothesis">>, <<"expected_benefit">>]) andalso
    lists:all(fun(K) -> V = maps:get(K, P, null), is_list(V) andalso length(V) =< 32 andalso
        lists:all(fun(X) -> text(X, 256) end, V) end, [<<"risks">>, <<"requested_tests">>]).
need_limits(Limits) -> case ae_evolution_limits:validate(Limits) of {ok, _} = Ok -> Ok; Error -> throw(Error) end.
text(V, Max) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< Max.
text_or_empty(V, Max) -> is_binary(V) andalso byte_size(V) =< Max.
hex(V) -> is_binary(V) andalso re:run(V, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match.
need(true, _) -> ok;
need(false, Reason) -> throw({error, Reason}).
now_ms() -> erlang:system_time(millisecond).
terminal(Job) -> lists:member(maps:get(<<"status">>, Job), [<<"rejected">>, <<"cancelled">>, <<"completed">>]).
get(Db, Id) -> case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE id=?", [Id]) of
    [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
must_get(Db, Id) -> Job = get(Db, Id), need(is_map(Job), unknown_job), Job.
active(Db) -> case ae_sql:rows(Db, "SELECT data FROM evolution_jobs WHERE status NOT IN ('rejected','cancelled','completed')", []) of
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
