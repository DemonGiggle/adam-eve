#!/usr/bin/env escript
%%! +S 2:2 +A 1
%% Test-only driver. Real author/build/evaluate/stage gates run normally. Then
%% pause the coordinators and use their trusted store APIs to stop exactly at
%% a durable boundary, avoiding scheduler races and production test hooks.
main([Phase0]) ->
    Phase = list_to_binary(Phase0),
    ok = code:add_pathsa(filelib:wildcard("_build/default/lib/*/ebin")),
    logger:remove_handler(default), application:load(ae_core),
    Config = ae_config:load(), application:set_env(ae_core, config, Config),
    {ok, _} = application:ensure_all_started(ae_core), wait_engine(),
    Base = ae_store:routing(),
    {ok, Ack0} = ae_router:turn(<<"baseline-ack">>, <<"main">>, <<"hello">>),
    {ok, Evolution} = ae_evolution:trigger(Phase, <<"Improve the greeting; preserve existing behavior.">>),
    Id = maps:get(<<"id">>, Evolution),
    Staged = wait_staged(Id, erlang:monotonic_time(millisecond) + 180000),
    Dep = maps:get(<<"deployment_id">>, Staged), Binding = maps:get(<<"approval_binding">>, Staged),
    {AckId, Ack} = case Phase of
        <<"rollback_intent">> -> promote_and_ack(Dep, Binding);
        <<"rollback_committed">> -> promote_and_ack(Dep, Binding);
        _ -> {<<"baseline-ack">>, Ack0}
    end,
    ok = sys:suspend(ae_evolution), ok = sys:suspend(ae_deployment),
    boundary(Phase, Dep, Binding, Base, Config),
    Output = #{<<"before">> => Base, <<"boundary_route">> => ae_store:routing(),
        <<"job">> => ae_store:evolution({get, Id}), <<"acknowledged">> =>
            #{<<"request_id">> => AckId, <<"text">> => Ack, <<"committed">> => true}},
    io:put_chars([jsx:encode(Output), "\n"]),
    %% The parent SIGKILLs this entire BEAM after reading the durable evidence.
    io:get_line(""), halt(1).

promote_and_ack(Dep, Binding) ->
    {ok, _} = ae_deployment:approve(Dep, Binding),
    {ok, Ack} = ae_router:turn(<<"candidate-ack">>, <<"main">>, <<"hello">>),
    {<<"candidate-ack">>, Ack}.

boundary(<<"approved">>, Dep, Binding, _, _) -> {ok, _} = ae_store:approve(Dep, Binding), ok;
boundary(Phase, Dep, Binding, Base, _)
        when Phase =:= <<"quiescing">>; Phase =:= <<"promoting">>; Phase =:= <<"committed">> ->
    {ok, _} = ae_store:approve(Dep, Binding),
    {ok, Closed} = ae_store:quiesce(Base, Dep),
    case Phase of
        <<"quiescing">> -> ok;
        _ ->
            ok = ae_store:preparing_promotion(Dep, Closed),
            {ok, CP} = ae_store:checkpoint(Closed),
            case Phase of
                <<"promoting">> -> ok;
                <<"committed">> ->
                    Job = ae_store:deployment(Dep), Desc = maps:get(<<"runtime">>, Job),
                    [Candidate] = [Pid || {_, Pid, _, _} <- supervisor:which_children(ae_runtime_sup),
                        ae_runtime_worker:descriptor(Pid) =:= Desc],
                    ok = ae_runtime_worker:restore(Candidate, CP), ok = ae_runtime_worker:health(Candidate),
                    {ok, _} = ae_store:promote(Dep, Closed, Desc, maps:get(<<"checkpoint_id">>, CP)),
                    %% No activate call: crash after routing commit, before activation.
                    ok
            end
    end;
boundary(Phase, Dep, _, Base, Config) when Phase =:= <<"rollback_intent">>; Phase =:= <<"rollback_committed">> ->
    ok = ae_store:starting_rollback(Dep, <<"boundary_injection">>),
    case Phase of
        <<"rollback_intent">> -> ok;
        <<"rollback_committed">> ->
            {ok, Closed} = ae_store:quiesce(ae_store:routing(), null),
            {ok, CP} = ae_store:checkpoint(Closed),
            {ok, Previous} = ae_runtime_sup:start_runtime(maps:get(root, Config), Base, Config#{restore_checkpoint => CP}),
            ok = ae_runtime_worker:health(Previous),
            {ok, _} = ae_store:rollback(Dep, Closed, ae_runtime_worker:descriptor(Previous),
                maps:get(<<"checkpoint_id">>, CP), <<"boundary_injection">>),
            %% No activate call after the rollback commit either.
            ok
    end.

wait_engine() ->
    case ae_evolution:status() of
        #{<<"state">> := <<"recovering">>} -> receive after 20 -> wait_engine() end;
        _ -> ok
    end.
wait_staged(Id, Deadline) ->
    Job = ae_store:evolution({get, Id}),
    case maps:get(<<"status">>, Job) of
        <<"awaiting_approval">> -> {ok, Result} = ae_evolution:job(Id), Result;
        Phase ->
            false = lists:member(Phase, [<<"rejected">>, <<"cancelled">>, <<"degraded">>]),
            true = erlang:monotonic_time(millisecond) < Deadline,
            receive after 20 -> wait_staged(Id, Deadline) end
    end.
