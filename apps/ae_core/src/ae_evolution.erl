-module(ae_evolution).
-behaviour(gen_statem).
-export([start_link/1, trigger/2, status/0, job/1, set_enabled/1, cancel/1, configured/1, enabled/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

start_link(Config) -> gen_statem:start_link({local, ?MODULE}, ?MODULE, Config, []).
trigger(Origin, Objective) ->
    case text(Origin, 256) andalso text(Objective, 16384) of
        true -> gen_statem:call(?MODULE, {trigger, Origin, Objective}, 10000);
        false -> {error, invalid_objective} end.
status() -> gen_statem:call(?MODULE, status, 10000).
set_enabled(Value) -> gen_statem:call(?MODULE, {enabled, Value}, 30000).
cancel(Id) -> case valid_id(Id) of true -> gen_statem:call(?MODULE, {cancel, Id}, 30000); false -> {error, invalid_job_id} end.
callback_mode() -> handle_event_function.

configured(Config) ->
    try
        true = maps:get(evolution_requested, Config, false),
        true = ae_llm:authoring_supported(Config),
        {ok, _} = ae_storage:validate_retention(maps:get(retention_policy, Config)),
        ModelTimeout = maps:get(evolution_llm_timeout, Config, maps:get(llm_timeout, Config, 30000)),
        true = is_integer(ModelTimeout) andalso ModelTimeout >= 100 andalso ModelTimeout =< 3600000,
        bubblewrap = maps:get(runtime_isolation, Config),
        {ok, _} = ae_evolution_limits:validate(maps:get(evolution_limits, Config)),
        {ok, _} = ae_builder:validate_config(maps:get(candidate_builder, Config)),
        {ok, _} = ae_evaluator:validate_config(maps:get(candidate_evaluator, Config)),
        Limits = maps:get(handoff_limits, Config),
        true = is_map(Limits) andalso lists:sort(maps:keys(Limits)) =:=
            [<<"approval_ttl_ms">>, <<"health_interval_ms">>, <<"observe_ms">>, <<"quiesce_ms">>],
        lists:all(fun(V) -> is_integer(V) andalso V > 0 andalso V =< 300000 end, maps:values(Limits))
    catch _:_ -> false end.
enabled(Config) ->
    try configured(Config) andalso ae_store:evolution(mode) =:= true
    catch _:_ -> false end.

init(Config) ->
    process_flag(trap_exit, true), self() ! recover,
    case ae_storage:validate_retention(maps:get(retention_policy, Config, undefined)) of
        {ok, Policy} -> ok = ae_store:evolution({set_retention, Policy});
        _ -> ok end,
    {ok, recovering, #{config => Config, job => undefined, task => undefined, recovery_job => ae_store:evolution(active)}}.

handle_event({call, From}, status, State, Data) ->
    Reply = #{<<"enabled">> => enabled(maps:get(config, Data)), <<"state">> => atom_to_binary(State, utf8),
        <<"job_id">> => case maps:get(job, Data) of undefined -> null; Id -> Id end},
    {keep_state_and_data, [{reply, From, Reply}]};
handle_event({call, From}, {trigger, _, _}, recovering, _) ->
    {keep_state_and_data, [{reply, From, {error, evolution_recovering}}]};
handle_event({call, From}, {trigger, Origin, Objective}, _, #{config := Config} = Data) ->
    Reply = case enabled(Config) of
        false -> {error, evolution_disabled};
        true -> start_job(Origin, Objective, Config)
    end,
    case {Reply, maps:get(job, Data)} of
        {{ok, #{<<"id">> := Id} = Job}, undefined} ->
            case terminal(Job) of
                false -> {next_state, proposing, Data#{job := Id}, [{reply, From, Reply}, {next_event, internal, drive}]};
                true -> {keep_state_and_data, [{reply, From, Reply}]}
            end;
        _ -> {keep_state_and_data, [{reply, From, Reply}]}
    end;
handle_event({call, From}, {enabled, Value}, _, #{config := Config} = Data) when is_boolean(Value) ->
    case Value andalso not configured(Config) of
        true -> {keep_state_and_data, [{reply, From, {error, evolution_not_configured}}]};
        false ->
            ok = ae_store:evolution({set_mode, Value}),
            case {Value, maps:get(job, Data)} of
                {false, Id} when Id =/= undefined ->
                    Next = request_cancel(Id, <<"evolution_disabled">>, Data),
                    {keep_state, Next, [{reply, From, ok} | poll(Next)]};
                {true, Id} when Id =/= undefined -> {keep_state, Data, [{reply, From, ok} | poll(Data)]};
                _ -> {next_state, idle_state(Config), Data, [{reply, From, ok}]}
            end
    end;
handle_event({call, From}, {cancel, Id}, _, #{job := Id} = Data) when Id =/= undefined ->
    Next = request_cancel(Id, <<"operator_cancelled">>, Data),
    {keep_state, Next, [{reply, From, ok} | poll(Next)]};
handle_event({call, From}, {cancel, Id}, _, _) ->
    Reply = case ae_store:evolution({get, Id}) of
        Job when is_map(Job) -> case terminal(Job) of true -> ok; false -> {error, evolution_not_owned} end;
        _ -> {error, unknown_job} end,
    {keep_state_and_data, [{reply, From, Reply}]};
handle_event({call, From}, _, _, _) -> {keep_state_and_data, [{reply, From, {error, invalid_evolution_command}}]};
handle_event(info, recover, _, Data) ->
    case maps:get(recovery_job, Data) of
        undefined -> {next_state, idle_state(maps:get(config, Data)), Data};
        #{<<"id">> := Id, <<"deployment_id">> := _} ->
            Next = Data#{job := Id},
            case enabled(maps:get(config, Data)) of
                true -> {keep_state, Next, [{next_event, internal, drive}]};
                false -> {keep_state, request_cancel(Id, <<"evolution_disabled">>, Next), poll(Next)}
            end;
        #{<<"id">> := Id} ->
            Next = request_cancel(Id, <<"evolution_owner_restarted">>, Data#{job := Id}),
            {keep_state, Next, poll(Next)}
    end;
handle_event(internal, drive, _, Data) -> drive(Data);
handle_event(state_timeout, poll, _, Data) -> drive(Data);
handle_event(info, {evolution_step, Token, Kind, Result}, _, #{task := #{token := Token, kind := Kind}} = Data) ->
    step_finished(Kind, Result, clear_task(Data));
handle_event(info, {ae_build_result, Id, Result}, _, #{job := Id, task := #{kind := build}} = Data) ->
    step_finished(build, Result, clear_task(Data));
handle_event(info, {ae_evaluation_result, Id, Result}, _, #{job := Id, task := #{kind := evaluate}} = Data) ->
    step_finished(evaluate, Result, clear_task(Data));
handle_event(info, {'DOWN', Ref, process, _, _}, _, #{job := Id, task := #{ref := Ref}} = Data) ->
    Next = request_cancel(Id, <<"evolution_worker_lost">>, clear_task(Data)), {keep_state, Next, poll(Next)};
handle_event(_, _, _, _) -> keep_state_and_data.

drive(#{job := undefined, config := Config} = Data) -> {next_state, idle_state(Config), Data};
drive(#{job := Id, config := Config} = Data) ->
    Job = ae_store:evolution({get, Id}),
    case {terminal(Job), maps:get(task, Data)} of
        {true, #{kind := cancel}} -> {keep_state, Data, poll(Data)};
        {true, _} -> {next_state, idle_state(Config), (stop_task(Data))#{job := undefined}};
        {false, _} ->
            case not enabled(Config) orelse maps:get(<<"cancel_requested">>, Job, false) orelse
                 erlang:system_time(millisecond) >= maps:get(<<"deadline">>, Job) of
                true -> Next = request_cancel(Id, <<"evolution_stopped_or_expired">>, Data), {keep_state, Next, poll(Next)};
                false -> advance(Job, Data)
            end
    end.

advance(Job, #{task := Task} = Data) when Task =/= undefined -> {next_state, phase(Job), Data, poll(Data)};
advance(#{<<"status">> := Phase, <<"limits">> := Limits}, #{config := Config, job := Id} = Data)
        when Phase =:= <<"proposing">>; Phase =:= <<"building">>; Phase =:= <<"testing">>; Phase =:= <<"evaluated">> ->
    case ae_storage:preflight(Config, Limits) of
        ok -> begin_step(Phase, Data);
        {error, Why} -> Next = request_cancel(Id, atom_to_binary(Why, utf8), Data), {keep_state, Next, poll(Next)}
    end;
advance(Job, Data) -> {next_state, phase(Job), Data, poll(Data)}.

begin_step(<<"proposing">>, Data) ->
    Id = maps:get(job, Data), {next_state, proposing, task(author, fun() -> ae_router:author(Id) end, Data), poll(Data)};
begin_step(<<"building">>, #{job := Id, config := Config} = Data) ->
    start_supervised(build, ae_build_sup:start_job(Id, Config, self()), Data);
begin_step(<<"testing">>, #{job := Id, config := Config} = Data) ->
    start_supervised(evaluate, ae_eval_sup:start_job(Id, Config, self()), Data);
begin_step(<<"evaluated">>, #{job := Id} = Data) ->
    {next_state, staging, task(stage, fun() -> ae_deployment:stage_evolution(Id) end, Data), poll(Data)}.

start_supervised(Kind, {ok, Pid}, Data) ->
    Next = Data#{task := #{kind => Kind, pid => Pid, ref => monitor(process, Pid)}},
    State = case Kind of build -> building; evaluate -> testing end, {next_state, State, Next, poll(Next)};
start_supervised(_, _, #{job := Id} = Data) ->
    Next = request_cancel(Id, <<"evolution_worker_start_failed">>, Data), {keep_state, Next, poll(Next)}.

step_finished(cancel, {error, _}, #{job := Id} = Data) ->
    Job = ae_store:evolution({get, Id}),
    case not terminal(Job) andalso maps:is_key(<<"deployment_id">>, Job) of
        true ->
            _ = ae_store:evolution({degraded, Id, <<"cancellation_recovery_failed">>}), {next_state, degraded, Data};
        false -> {keep_state, Data, [{next_event, internal, drive}]}
    end;
step_finished(author, {error, service_busy}, Data) -> {keep_state, Data, poll(Data)};
step_finished(author, {error, _}, #{job := Id} = Data) ->
    Job = ae_store:evolution({get, Id}),
    case maps:get(<<"status">>, Job) of
        <<"proposing">> -> Next = request_cancel(Id, <<"authoring_failed">>, Data), {keep_state, Next, poll(Next)};
        _ -> {keep_state, Data, [{next_event, internal, drive}]}
    end;
step_finished(Kind, {error, _}, #{job := Id} = Data) when Kind =:= build; Kind =:= evaluate; Kind =:= stage ->
    Job = ae_store:evolution({get, Id}),
    case terminal(Job) orelse maps:get(<<"status">>, Job) =:= <<"proposing">> of
        true -> {keep_state, Data, [{next_event, internal, drive}]};
        false -> Next = request_cancel(Id, <<"evolution_step_failed">>, Data), {keep_state, Next, poll(Next)}
    end;
step_finished(_, _, Data) -> {keep_state, Data, [{next_event, internal, drive}]}.

request_cancel(_, _, #{task := #{kind := cancel}} = Data) -> Data;
request_cancel(Id, Reason, Data) ->
    {ok, Job} = ae_store:evolution({request_cancel, Id, Reason}),
    Next = stop_task(Data),
    task(cancel, fun() ->
        %% An orchestrator-only crash can leave supervised workers alive. Stop
        %% the durable job's children even when this process has no task handle.
        catch supervisor:terminate_child(ae_build_sup, Id),
        catch supervisor:terminate_child(ae_eval_sup, Id),
        case maps:find(<<"deployment_id">>, Job) of
            {ok, Dep} -> ae_deployment:abort(Dep, Reason);
            error -> ae_router:cancel_author(Id)
        end
    end, Next).

task(Kind, Fun, Data) ->
    Parent = self(), Token = make_ref(),
    {Pid, Ref} = spawn_opt(fun() ->
        Result = try Fun() catch _:_ -> {error, evolution_step_failed} end,
        Parent ! {evolution_step, Token, Kind, Result}
    end, [link, monitor]),
    Data#{task := #{kind => Kind, pid => Pid, ref => Ref, token => Token}}.
clear_task(#{task := #{ref := Ref, pid := Pid}} = Data) ->
    demonitor(Ref, [flush]), unlink(Pid), Data#{task := undefined}.
stop_task(#{task := undefined} = Data) -> Data;
stop_task(#{job := Id, task := #{kind := Kind, pid := Pid}} = Data) ->
    Next = clear_task(Data),
    case Kind of
        build -> catch supervisor:terminate_child(ae_build_sup, Id);
        evaluate -> catch supervisor:terminate_child(ae_eval_sup, Id);
        _ -> exit(Pid, shutdown)
    end, Next.
terminate(_, _, Data) -> stop_task(Data), ok.

poll(#{config := Config}) ->
    Limits = maps:get(handoff_limits, Config, undefined),
    Wait = case Limits of #{<<"health_interval_ms">> := N} -> N; _ -> 100 end,
    [{state_timeout, Wait, poll}].
idle_state(Config) -> case enabled(Config) of true -> idle; false -> disabled end.
terminal(Job) -> lists:member(maps:get(<<"status">>, Job), [<<"completed">>, <<"rejected">>, <<"cancelled">>, <<"rolled_back">>]).
phase(Job) ->
    case maps:get(<<"status">>, Job) of
        <<"proposing">> -> proposing; <<"building">> -> building; <<"testing">> -> testing;
        <<"evaluated">> -> staging; <<"staging">> -> staging; <<"awaiting_approval">> -> awaiting_approval;
        <<"approved">> -> quiescing; <<"quiescing">> -> quiescing; <<"promoting">> -> promoting;
        <<"observing">> -> observing; <<"rollback">> -> rollback; <<"degraded">> -> degraded
    end.

start_job(Origin, Objective, Config) ->
    Limits = maps:get(evolution_limits, Config),
    case ae_store:evolution({find_origin, Origin}) of
        Existing when is_map(Existing) ->
            case maps:get(<<"objective">>, Existing) =:= Objective andalso maps:get(<<"limits">>, Existing) =:= Limits of
                true -> {ok, Existing}; false -> {error, origin_conflict} end;
        undefined ->
            Route = ae_store:routing(), Caps = maps:get(<<"capabilities">>, maps:get(<<"artifact">>, Route), []),
            case lists:all(fun(C) -> lists:member(C, Caps) end, [<<"evolution_propose">>, <<"evolution_llm">>, <<"source_read">>, <<"source_list">>, <<"evolution_status">>]) of
                false -> {error, authoring_not_supported};
                true -> case ae_storage:preflight(Config, Limits) of
                    ok -> case ae_store:evolution({create, Route, Origin, Objective, Limits}) of
                        {ok, {existing, Job}} -> {ok, Job}; Other -> Other end;
                    Error -> Error end
            end;
        Error -> Error
    end.

job(Id) -> case valid_id(Id) of false -> {error, invalid_job_id}; true -> get_job(Id) end.
valid_id(Id) -> is_binary(Id) andalso re:run(Id, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match.
text(Value, Max) -> is_binary(Value) andalso byte_size(Value) > 0 andalso byte_size(Value) =< Max.
get_job(Id) ->
    case ae_store:evolution({get, Id}) of
        Stored when is_map(Stored) ->
            Job = case maps:get(<<"attempts">>, Stored) of
                0 -> Stored;
                Attempt -> Stored#{<<"proposal">> => ae_store:evolution({attempt, Id, Attempt})}
            end,
            case maps:find(<<"deployment_id">>, Job) of
                {ok, DepId} ->
                    Dep = ae_store:deployment(DepId), Extra = #{<<"deployment">> => Dep},
                    Fields = case maps:get(<<"status">>, Dep) of
                        <<"awaiting_approval">> -> Extra#{<<"approval_binding">> => ae_policy:binding(Dep)};
                        _ -> Extra end,
                    {ok, maps:merge(Job, Fields)};
                error -> {ok, Job}
            end;
        _ -> {error, unknown_job}
    end.
