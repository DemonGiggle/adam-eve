-module(ae_deployment).
-behaviour(gen_statem).
-export([start_link/1, stage/1, approve/2, reject/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

start_link(Config) -> gen_statem:start_link({local, ?MODULE}, ?MODULE, Config, []).
stage(Digest) -> gen_statem:call(?MODULE, {stage, Digest}, 65000).
approve(Id, Binding) -> gen_statem:call(?MODULE, {approve, Id, Binding}, 410000).
reject(Id) -> gen_statem:call(?MODULE, {reject, Id}, 10000).
callback_mode() -> handle_event_function.

init(Config) ->
    Data = #{config => Config, candidate => undefined, monitor => undefined, job => undefined},
    case ae_store:recover_handoff() of
        {rollback, #{<<"id">> := Id}} ->
            {ok, observing, Data#{job := Id}, [{state_timeout, 0, poll}]};
        normal ->
            ae_runtime_sup:stop_inactive(maps:get(<<"slot">>, ae_store:routing())),
            {ok, idle, Data}
    end.

handle_event({call, From}, {stage, Digest}, idle, #{config := Config} = Data) ->
    case maps:get(handoff_limits, Config, undefined) of
        undefined -> {keep_state_and_data, [{reply, From, {error, handoff_not_configured}}]};
        Limits ->
            case stage_candidate(Digest, Limits, Data) of
                {ok, Job, Next} ->
                    {next_state, awaiting_approval, Next, [{reply, From, {ok, summary(Job, Next)}} | poll(Next)]};
                Error -> {keep_state_and_data, [{reply, From, Error}]}
            end
    end;
handle_event({call, From}, {approve, Id, Binding}, awaiting_approval, #{job := Id} = Data) ->
    case ae_store:approve(Id, Binding) of
        {ok, _} ->
            case ae_router:promote(Id, maps:get(candidate, Data)) of
                {ok, Route} ->
                    {next_state, observing, Data, [{reply, From, {ok, Route}} | poll(Data)]};
                Error ->
                    case ae_store:deployment(Id) of
                        #{<<"status">> := <<"observing">>} ->
                            {NextState, Next} = rollback(Data, <<"activation_failed">>),
                            {next_state, NextState, Next, [{reply, From, Error}]};
                        _ ->
                            ae_store:reject(Id, <<"promotion_failed">>),
                            {next_state, idle, release(Data, true), [{reply, From, Error}]}
                    end
            end;
        Error -> {keep_state_and_data, [{reply, From, Error}]}
    end;
handle_event({call, From}, {reject, Id}, awaiting_approval, #{job := Id} = Data) ->
    Reply = ae_store:reject(Id, <<"operator_denied">>),
    {next_state, idle, release(Data, true), [{reply, From, Reply}]};
handle_event({call, From}, _, _, _) ->
    {keep_state_and_data, [{reply, From, {error, invalid_deployment_state}}]};
handle_event(state_timeout, poll, awaiting_approval, Data) ->
    Job = ae_store:deployment(maps:get(job, Data)),
    Valid = erlang:system_time(millisecond) < maps:get(<<"expires_at">>, Job) andalso
        ae_policy:same_baseline(ae_store:routing(), maps:get(<<"baseline">>, Job)) andalso
        safe_health(maps:get(candidate, Data)) =:= ok,
    case Valid of
        true -> {keep_state_and_data, poll(Data)};
        false ->
            ae_store:reject(maps:get(job, Data), <<"expired_stale_or_unhealthy">>),
            {next_state, idle, release(Data, true)}
    end;
handle_event(state_timeout, poll, observing, Data) ->
    Job = ae_store:deployment(maps:get(job, Data)),
    Expected = maps:get(<<"promoted_route">>, Job),
    case ae_router:check(Expected) of
        ok ->
            case erlang:system_time(millisecond) >= maps:get(<<"observe_until">>, Job) of
                true ->
                    case ae_store:complete(maps:get(job, Data), Expected) of
                        ok -> {next_state, idle, release(Data, false)};
                        _ -> rollback_result(Data, <<"observation_commit_failed">>)
                    end;
                false -> {keep_state_and_data, poll(Data)}
            end;
        busy -> {keep_state_and_data, poll(Data)};
        _ -> rollback_result(Data, <<"failed_health_gate">>)
    end;
handle_event(cast, {runtime_failed, Id}, observing, #{job := Id} = Data) ->
    rollback_result(Data, <<"candidate_crashed">>);
handle_event(cast, baseline_changed, awaiting_approval, Data) ->
    ae_store:reject(maps:get(job, Data), <<"baseline_changed">>),
    {next_state, idle, release(Data, true)};
handle_event(info, {'DOWN', Ref, process, _, _}, awaiting_approval, #{monitor := Ref} = Data) ->
    ae_store:reject(maps:get(job, Data), <<"standby_crashed">>),
    {next_state, idle, release(Data, true)};
handle_event(info, {'DOWN', Ref, process, _, _}, observing, #{monitor := Ref} = Data) ->
    rollback_result(Data, <<"candidate_crashed">>);
handle_event(_, _, _, _) -> keep_state_and_data.

terminate(_, awaiting_approval, Data) -> release(Data, true), ok;
terminate(_, _, Data) -> release(Data, false), ok.

stage_candidate(Digest, Limits, #{config := #{root := Root} = Config} = Data) ->
    try
        Manifest = ae_artifacts:load(Root, Digest),
        Base = ae_store:routing(),
        ok = ae_artifacts:verify_parent(Root, Manifest, maps:get(<<"artifact">>, Base)),
        case ae_store:new_deployment(Base, Manifest, Limits) of
            {ok, Job} ->
                Id = maps:get(<<"id">>, Job),
                Spec = #{<<"slot">> => maps:get(<<"target_slot">>, Job), <<"artifact">> => Manifest},
                try
                    {ok, Candidate} = ae_runtime_sup:start_runtime(Root, Spec, Config),
                    try
                        ok = ae_runtime_worker:health(Candidate),
                        {ok, Reply} = ae_runtime_worker:simulate(Candidate),
                        Evaluation = #{<<"protocol_v1">> => true, <<"schema_v1">> => true,
                            <<"synthetic_turn">> => true, <<"production_tools">> => false,
                            <<"reply_digest">> => ae_policy:digest(Reply)},
                        {ok, Staged} = ae_store:staged(Id, ae_runtime_worker:descriptor(Candidate), Evaluation),
                        OsPid = ae_runtime_worker:os_pid(Candidate),
                        {ok, Staged, Data#{candidate := Candidate, monitor := monitor(process, Candidate),
                                           candidate_os_pid => OsPid, job := Id}}
                    catch C:R:S -> ae_runtime_sup:stop_runtime(Candidate), erlang:raise(C, R, S) end
                catch _:_ -> ae_store:reject(Id, <<"staging_failed">>), {error, staging_failed} end;
            Error -> Error
        end
    catch _:_ -> {error, invalid_artifact} end.

summary(Job, #{candidate_os_pid := OsPid}) ->
    #{<<"deployment_id">> => maps:get(<<"id">>, Job), <<"approval_binding">> => ae_policy:binding(Job),
      <<"artifact">> => maps:get(<<"candidate">>, Job), <<"baseline">> => maps:get(<<"baseline">>, Job),
      <<"evaluation">> => maps:get(<<"evaluation">>, Job), <<"expires_at">> => maps:get(<<"expires_at">>, Job),
      <<"standby_os_pid">> => OsPid}.
poll(#{config := #{handoff_limits := Limits}}) ->
    [{state_timeout, maps:get(<<"health_interval_ms">>, Limits), poll}].
safe_health(Pid) -> try ae_runtime_worker:health(Pid) catch exit:_ -> {error, unhealthy} end.
rollback_result(Data, Reason) ->
    {State, Next} = rollback(Data, Reason), {next_state, State, Next}.
rollback(#{job := Id} = Data, Reason) ->
    case ae_router:rollback(Id, Reason) of
        {ok, _} -> {idle, release(Data, true)};
        _ -> {degraded, release(Data, true)}
    end.
release(#{candidate := Candidate, monitor := Ref} = Data, Stop) ->
    case Ref of undefined -> ok; _ -> demonitor(Ref, [flush]) end,
    case Stop andalso is_pid(Candidate) of true -> ae_runtime_sup:stop_runtime(Candidate); false -> ok end,
    Data#{candidate := undefined, monitor := undefined, job := undefined}.
