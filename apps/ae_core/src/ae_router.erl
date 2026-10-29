-module(ae_router).
-behaviour(gen_server).
-export([start_link/1, turn/3, restart/0, status/0, promote/2, rollback/2, check/1, restore_ready/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
turn(Request, Session, Message) -> gen_server:call(?MODULE, {turn, Request, Session, Message}, 320000).
restart() -> gen_server:call(?MODULE, restart, 65000).
status() -> gen_server:call(?MODULE, status, 10000).
promote(Id, Pid) -> gen_server:call(?MODULE, {promote, Id, Pid}, 400000).
rollback(Id, Reason) -> gen_server:call(?MODULE, {rollback, Id, Reason}, 65000).
check(Expected) -> gen_server:call(?MODULE, {check, Expected}, 10000).
restore_ready(BackupId, Origin) -> gen_server:call(?MODULE, {restore_ready, BackupId, Origin}, 15000).

init(#{root := Root} = Config) ->
    ok = ae_runtime_sup:stop_all(),
    case ae_store:routing() of
        undefined ->
            Manifest = ae_artifacts:bootstrap(Root),
            ok = ae_artifacts:verify(Root, Manifest), ae_store:boot(Manifest);
        _ -> ok
    end,
    State = #{runtime => undefined, monitor => undefined, config => Config,
              inflight => undefined, handoff => undefined, restarts => []},
    case ae_store:recover_handoff() of
        {rollback, Job} ->
            {_, Restored} = restore_previous(maps:get(<<"id">>, Job), <<"controller_restarted_during_observation">>, State),
            {ok, Restored};
        normal ->
            %% Storage integrity errors refuse boot; valid but broken agent code
            %% leaves the trusted control plane available in degraded mode.
            ok = ae_artifacts:verify(Root, maps:get(<<"artifact">>, ae_store:routing())),
            try {ok, boot_current(State)}
            catch _:_ ->
                ae_store:runtime_failed(ae_store:routing(), <<"runtime_boot_failed">>), {ok, State}
            end
    end.

handle_call({turn, Request, Session, Message}, From, State) ->
    Validation = case ae_store:recovery() of
        #{<<"pending">> := true} -> {error, restore_verification_required};
        _ -> ae_protocol:validate(#{<<"protocol_version">> => 1, <<"type">> => <<"user_turn">>,
            <<"request_id">> => Request, <<"session_id">> => Session, <<"message">> => Message,
            <<"epoch">> => 1, <<"memory_cursor">> => 0})
    end,
    case {Validation, maps:get(runtime, State), maps:get(inflight, State), maps:get(handoff, State)} of
        {ok, undefined, _, _} -> {reply, {error, runtime_unavailable}, State};
        {ok, _, _, Handoff} when Handoff =/= undefined -> {reply, {error, quiescing}, State};
        {ok, _, Inflight, _} when Inflight =/= undefined -> {reply, {error, busy}, State};
        {ok, Runtime, undefined, undefined} ->
            case safe_auth(Runtime) of
                {ok, Auth} -> admit_turn(Runtime, Auth, {Request, Session, Message}, From, State);
                Error -> {reply, Error, State}
            end;
        {Error, _, _, _} -> {reply, Error, State}
    end;
handle_call({restore_ready, BackupId, Origin}, _, State) ->
    Reply = case maps:get(runtime, State) of
        undefined -> {error, runtime_unavailable};
        Runtime ->
            case safe_health(Runtime) of
                ok ->
                    case ae_store:verify_recovery(ae_store:routing(), BackupId, Origin) of
                        ok ->
                            try ae_runtime_worker:activate(Runtime, ae_store:routing())
                            catch exit:_ -> {error, runtime_unavailable} end;
                        Error -> Error
                    end;
                Error -> Error
            end
    end,
    {reply, Reply, State};
handle_call(status, _, State) ->
    Health = case {maps:get(runtime, State), maps:get(inflight, State)} of
        {undefined, _} -> <<"degraded">>;
        {_, Busy} when Busy =/= undefined -> <<"busy">>;
        {Runtime, _} -> case safe_health(Runtime) of ok -> <<"ok">>; _ -> <<"unhealthy">> end
    end,
    Recovery = case ae_store:recovery() of undefined -> null; Record -> Record end,
    Reply = #{<<"routing">> => ae_store:routing(), <<"os_pid">> => maps:get(os_pid, State, null),
        <<"recovery">> => Recovery,
        <<"runtime_health">> => Health, <<"evolution_enabled">> => false,
        <<"runtime_isolation">> => atom_to_binary(maps:get(runtime_isolation, maps:get(config, State), development), utf8),
        <<"handoff_enabled">> => maps:get(handoff_limits, maps:get(config, State), undefined) =/= undefined,
        <<"deployment">> => ae_store:active_deployment(),
        <<"last_event_seq">> => ae_store:last_seq()},
    {reply, Reply, State};
handle_call({check, Expected}, _, State) ->
    Reply = case ae_policy:same_baseline(Expected, ae_store:routing()) of
        false -> {error, stale_routing};
        true -> case {maps:get(runtime, State), maps:get(inflight, State)} of
            {undefined, _} -> {error, runtime_unavailable};
            {_, Busy} when Busy =/= undefined -> busy;
            {Runtime, _} -> safe_health(Runtime)
        end
    end,
    {reply, Reply, State};
handle_call(restart, _, State) ->
    case {maps:get(inflight, State), ae_store:active_deployment()} of
        {undefined, undefined} ->
            Stopped = stop_active(State),
            try {reply, ok, boot_current(Stopped)}
            catch _:_ -> {reply, {error, recovery_failed}, Stopped} end;
        _ -> {reply, {error, service_busy}, State}
    end;
handle_call({promote, Id, Candidate}, From, State) ->
    Job = ae_store:deployment(Id),
    case ae_store:quiesce(maps:get(<<"baseline">>, Job), Id) of
        {ok, Closed} ->
            Timer = erlang:send_after(maps:get(<<"quiesce_ms">>, maps:get(<<"limits">>, Job)), self(), {drain_timeout, Id}),
            Next = State#{handoff := #{from => From, id => Id, candidate => Candidate,
                                      closed => Closed, timer => Timer}},
            case maps:get(inflight, Next) of
                undefined -> finish_handoff(Next);
                _ -> {noreply, Next}
            end;
        Error -> {reply, Error, State}
    end;
handle_call({rollback, Id, Reason}, _, State) ->
    {Reply, Next} = restore_previous(Id, Reason, State), {reply, Reply, Next}.

handle_cast(_, State) -> {noreply, State}.
handle_info({turn_result, Ref, Result}, #{inflight := #{ref := Ref} = Turn} = State) ->
    Reply = case Result of
        {ok, Text} -> ae_store:finish_turn(maps:get(auth, Turn), maps:get(request, Turn), Text);
        Error -> Error
    end,
    gen_server:reply(maps:get(from, Turn), Reply),
    Next = State#{inflight := undefined},
    case maps:get(handoff, Next) of undefined -> {noreply, Next}; _ -> finish_handoff(Next) end;
handle_info({drain_timeout, Id}, #{handoff := #{id := Id}} = State) ->
    finish_handoff(stop_active(cancel_turn(State)));
handle_info({'DOWN', Ref, process, _, Reason}, #{monitor := Ref} = State) when Ref =/= undefined ->
    ae_store:runtime_failed(ae_store:routing(), list_to_binary(io_lib:format("~0P", [Reason, 5]))),
    Next = (cancel_turn(State))#{runtime := undefined, monitor := undefined, os_pid => null},
    case maps:get(handoff, Next) of
        Handoff when Handoff =/= undefined -> finish_handoff(Next);
        undefined ->
            case ae_store:active_deployment() of
                #{<<"id">> := Id, <<"status">> := <<"observing">>} ->
                    ae_store:quiesce(ae_store:routing(), null),
                    gen_statem:cast(ae_deployment, {runtime_failed, Id}), {noreply, Next};
                _ ->
                    gen_statem:cast(ae_deployment, baseline_changed),
                    Now = erlang:monotonic_time(millisecond),
                    Recent = [T || T <- maps:get(restarts, Next), Now - T < 30000],
                    case length(Recent) < 3 of
                        true ->
                            try {noreply, boot_current(Next#{restarts := [Now | Recent]})}
                            catch _:_ -> ae_store:quiesce(ae_store:routing(), null), {noreply, Next} end;
                        false -> ae_store:quiesce(ae_store:routing(), null), {noreply, Next}
                    end
            end
    end;
handle_info(_, State) -> {noreply, State}.
terminate(_, State) -> catch stop_active(cancel_turn(State)), ok.

boot_current(#{config := #{root := Root} = Config} = State) ->
    Route = ae_store:routing(),
    {ok, CP} = ae_store:checkpoint(Route),
    {ok, Runtime} = ae_runtime_sup:start_runtime(Root, Route, Config#{restore_checkpoint => CP}),
    try
        Desc = ae_runtime_worker:descriptor(Runtime),
        {ok, New} = ae_store:activate_checkpoint(Route, Desc, maps:get(<<"checkpoint_id">>, CP)),
        ok = enable_runtime(Runtime, New), bind_runtime(Runtime, State)
    catch C:R:S -> ae_runtime_sup:stop_runtime(Runtime), erlang:raise(C, R, S) end.

finish_handoff(#{handoff := #{from := From, id := Id, candidate := Candidate, timer := Timer}} = State) ->
    erlang:cancel_timer(Timer),
    try
        Job = ae_store:deployment(Id),
        #{config := #{root := Root}} = State,
        ok = ae_artifacts:verify(Root, maps:get(<<"candidate">>, Job)),
        Closed = ae_store:routing(),
        {ok, CP} = ae_store:checkpoint(Closed),
        ok = ae_runtime_worker:restore(Candidate, CP),
        ok = ae_runtime_worker:health(Candidate),
        Desc = ae_runtime_worker:descriptor(Candidate),
        {ok, Route} = ae_store:promote(Id, Closed, Desc, maps:get(<<"checkpoint_id">>, CP)),
        ok = ae_runtime_worker:activate(Candidate, Route),
        Next = bind_runtime(Candidate, stop_active(State)),
        gen_server:reply(From, {ok, Route}), {noreply, Next#{handoff := undefined}}
    catch _:_ ->
        Cleared = State#{handoff := undefined},
        Recovered = case {maps:get(runtime, Cleared), ae_store:deployment(Id)} of
            {undefined, #{<<"status">> := <<"quiescing">>}} ->
                ae_store:reject(Id, <<"promotion_failed">>),
                try boot_current(Cleared) catch _:_ -> Cleared end;
            _ -> Cleared
        end,
        gen_server:reply(From, {error, promotion_failed}), {noreply, Recovered}
    end.

restore_previous(Id, Reason, State) ->
    Stopped = stop_active(cancel_turn(State)),
    try
        Job = ae_store:deployment(Id),
        {ok, Closed} = ae_store:quiesce(ae_store:routing(), null),
        {ok, CP} = ae_store:checkpoint(Closed),
        Base = maps:get(<<"baseline">>, Job),
        #{config := #{root := Root} = Config} = State,
        {ok, Runtime} = ae_runtime_sup:start_runtime(Root, Base, Config#{restore_checkpoint => CP}),
        try
            ok = ae_runtime_worker:health(Runtime),
            Desc = ae_runtime_worker:descriptor(Runtime),
            {ok, Route} = ae_store:rollback(Id, Closed, Desc, maps:get(<<"checkpoint_id">>, CP), Reason),
            ok = enable_runtime(Runtime, Route),
            {{ok, Route}, bind_runtime(Runtime, Stopped)}
        catch C:R:S -> ae_runtime_sup:stop_runtime(Runtime), erlang:raise(C, R, S) end
    catch _:_ -> {{error, rollback_failed}, Stopped} end.

enable_runtime(Runtime, Route) ->
    case ae_store:recovery() of
        #{<<"pending">> := true} -> ok; % Restored, health-checked standby; no production lease yet.
        _ -> ae_runtime_worker:activate(Runtime, Route)
    end.

bind_runtime(Runtime, State) ->
    State#{runtime := Runtime, monitor := monitor(process, Runtime), os_pid => ae_runtime_worker:os_pid(Runtime)}.
stop_active(#{runtime := Runtime, monitor := Ref} = State) ->
    case Ref of undefined -> ok; _ -> demonitor(Ref, [flush]) end,
    case Runtime of undefined -> ok; _ -> ae_runtime_sup:stop_runtime(Runtime) end,
    State#{runtime := undefined, monitor := undefined, os_pid => null}.
cancel_turn(#{inflight := undefined} = State) -> State;
cancel_turn(#{inflight := Turn} = State) ->
    exit(maps:get(worker, Turn), kill),
    gen_server:reply(maps:get(from, Turn), {error, runtime_unavailable}), State#{inflight := undefined}.
safe_health(Runtime) -> try ae_runtime_worker:health(Runtime) catch exit:_ -> {error, runtime_unavailable} end.


safe_auth(Runtime) ->
    try {ok, ae_runtime_worker:auth(Runtime)} catch exit:_ -> {error, runtime_unavailable} end.

admit_turn(Runtime, Auth, {Request, Session, Message}, From, State) ->
    case ae_store:begin_turn(Auth, Request, Session, Message) of
        {ok, {completed, Text}} -> {reply, {ok, Text}, State};
        {ok, pending} ->
            Parent = self(), Ref = make_ref(),
            Worker = spawn(fun() ->
                Reply = try ae_runtime_worker:turn(Runtime, Request, Session, Message)
                        catch exit:_ -> {error, runtime_unavailable} end,
                Parent ! {turn_result, Ref, Reply}
            end),
            {noreply, State#{inflight := #{ref => Ref, worker => Worker, from => From,
                                           request => Request, auth => Auth}}};
        Error -> {reply, Error, State}
    end.
