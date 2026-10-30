-module(ae_evaluator).
-behaviour(gen_server).
-export([start_link/3, validate_config/1, valid_binding/1, valid_configuration/2, valid_result/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Id, Config, Notify) -> gen_server:start_link(?MODULE, {Id, Config, Notify}, []).
init({Id, Config, Notify}) ->
    self() ! start,
    {ok, #{id => Id, config => Config, notify => Notify, parent => monitor(process, Notify),
        lease => undefined, job => undefined, directory => undefined, port => undefined, timer => undefined, output => <<>>}}.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(start, State) ->
    try prepare(State) of
        {ok, Next} -> {noreply, Next};
        {error, Reason, Next} -> failed(Reason, Next)
    catch _:_ -> failed(<<"evaluator_start_failed">>, State) end;
handle_info({Port, {data, Data}}, #{port := Port, output := Acc} = State) ->
    case byte_size(Acc) + byte_size(Data) =< 1048576 of
        true -> {noreply, State#{output := <<Acc/binary, Data/binary>>}};
        false -> failed(<<"evaluator_output_limit">>, State)
    end;
handle_info({Port, {exit_status, Code}}, #{port := Port, output := Output} = State) ->
    try jsx:decode(Output, [return_maps, strict]) of
        #{<<"ok">> := true, <<"scorecard">> := Scorecard} when Code =:= 0 ->
            #{id := Id, job := Job, lease := Lease} = State,
            Result = ae_store:evolution({finish_evaluation, Id, maps:get(<<"attempts">>, Job), maps:get(<<"id">>, Lease), Scorecard}),
            case Result of {ok, _} -> notify(Result, State); {error, Why} -> failed(reason(Why), State) end;
        #{<<"ok">> := false, <<"error">> := Reason} when is_binary(Reason), byte_size(Reason) > 0, byte_size(Reason) =< 256 ->
            failed(Reason, State);
        _ -> failed(<<"invalid_evaluator_result">>, State)
    catch _:_ -> failed(<<"invalid_evaluator_result">>, State) end;
handle_info(evaluation_timeout, State) -> failed(<<"evaluation_timeout">>, State);
handle_info({'DOWN', Ref, process, _, _}, #{parent := Ref} = State) -> failed(<<"evaluation_owner_lost">>, State);
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    case maps:get(timer, State) of undefined -> ok; Timer -> erlang:cancel_timer(Timer) end,
    case maps:get(port, State) of undefined -> ok; Port -> catch port_close(Port) end,
    case maps:get(directory, State) of undefined -> ok; Directory -> file:del_dir_r(Directory) end, ok.

prepare(#{config := Config, id := Id} = State) ->
    Evaluator = maps:get(candidate_evaluator, Config, undefined),
    case validate_config(Evaluator) of
        {error, _} -> {error, <<"evaluation_not_configured">>, State};
        {ok, Evaluator} ->
            Job = ae_store:evolution({get, Id}),
            case Job of
                #{<<"status">> := <<"testing">>, <<"attempts">> := Attempt, <<"limits">> := Limits} ->
                    Root = maps:get(root, Config),
                    ok = ae_artifacts:verify(Root, maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job))),
                    ok = ae_artifacts:verify(Root, maps:get(<<"built_artifact">>, Job)),
                    Sandbox = maps:get(<<"sandbox_limits">>, Evaluator),
                    Cpu = max(4, min(maps:get(<<"cpu_seconds">>, Sandbox) * 4000,
                        maps:get(<<"cpu_ms">>, Limits) - maps:get(<<"reserved_cpu_ms">>, Job, 0))),
                    Remaining = maps:get(<<"deadline">>, Job) - erlang:system_time(millisecond),
                    Wall = min(min(maps:get(<<"wall_ms">>, Sandbox), maps:get(<<"evaluation_ms">>, Limits)), max(1, Remaining div 2)),
                    Encoded = jsx:encode(Evaluator),
                    Binding = maps:from_list([{Key, file_hash(Name)} || {Key, Name} <-
                        [{<<"harness_hash">>, "ae_evaluate.py"}, {<<"test_recipe_hash">>, "test_seed.escript"},
                         {<<"sandbox_hash">>, "ae_sandbox.py"}, {<<"source_helper_hash">>, "ae_candidate.py"}]]),
                    Bound = Binding#{<<"configuration_hash">> => ae_policy:sha256(Encoded)},
                    case ae_store:evolution({reserve_evaluation, Id, Attempt, Cpu, Wall, Bound, Encoded}) of
                        {ok, Lease} when is_map(Lease) ->
                            Reserved = State#{job := Job, lease := Lease},
                            try launch(Encoded, Reserved)
                            catch _:_ -> {error, <<"evaluator_launch_failed">>, Reserved} end;
                        {error, Reason} -> {error, reason(Reason), State}
                    end;
                _ -> {error, <<"invalid_job_state">>, State}
            end
    end.

launch(Encoded, #{config := #{root := Root}, job := Job, lease := Lease} = State) ->
    Directory = filename:join([Root, "workspaces", "evaluator-" ++ binary_to_list(maps:get(<<"id">>, Lease))]),
    ok = file:make_dir(Directory), ok = file:change_mode(Directory, 8#700),
    Next = State#{directory := Directory},
    try
        Request = filename:join(Directory, "request.json"), Config = filename:join(Directory, "config.json"),
        ok = file:write_file(Request, jsx:encode(#{<<"job">> => Job, <<"lease">> => Lease}), [exclusive]),
        ok = file:change_mode(Request, 8#600),
        ok = file:write_file(Config, Encoded, [exclusive]), ok = file:change_mode(Config, 8#600),
        Helper = filename:join(code:priv_dir(ae_core), "ae_evaluate.py"),
        Port = open_port({spawn_executable, "/usr/bin/python3"}, [binary, exit_status, use_stdio,
            {env, ae_os:clean_env()}, {args, [Helper, "--data-root", Root, "--request", Request, "--config", Config, "--watch-parent"]}]),
        Timer = erlang:send_after(maps:get(<<"wall_ms">>, Lease), self(), evaluation_timeout),
        {ok, Next#{port := Port, timer := Timer}}
    catch _:_ -> {error, <<"evaluator_launch_failed">>, Next} end.

file_hash(Name) -> {ok, Bytes} = file:read_file(filename:join(code:priv_dir(ae_core), Name)), ae_policy:sha256(Bytes).
failed(Reason, #{lease := undefined} = State) -> notify({error, Reason}, State);
failed(Reason, #{id := Id, lease := Lease, job := Job} = State) ->
    _ = ae_store:evolution({execution_failed, Id, maps:get(<<"attempts">>, Job), <<"evaluate">>,
        maps:get(<<"id">>, Lease), Reason, <<>>}), notify({error, Reason}, State).
notify(Result, #{notify := Notify, id := Id} = State) -> Notify ! {ae_evaluation_result, Id, Result}, {stop, normal, State}.
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason.

validate_config(Config) ->
    try
        true = exact(maps:remove(<<"resource_limits_mode">>, Config), [<<"cgroup_root">>, <<"source_bytes">>, <<"source_files">>, <<"artifact_bytes">>,
            <<"sandbox_limits">>, <<"startup_ms">>, <<"turn_ms">>, <<"policy">>]),
        true = lists:member(maps:get(<<"resource_limits_mode">>, Config, <<"cgroup">>), [<<"cgroup">>, <<"process">>]),
        true = text(maps:get(<<"cgroup_root">>, Config), 4096),
        absolute = filename:pathtype(maps:get(<<"cgroup_root">>, Config)),
        true = lists:all(fun(K) -> bounded(maps:get(K, Config), 1, (1 bsl 63) - 1) end,
            [<<"source_bytes">>, <<"source_files">>, <<"artifact_bytes">>]),
        true = bounded(maps:get(<<"startup_ms">>, Config), 1, 30000) andalso bounded(maps:get(<<"turn_ms">>, Config), 1, 300000),
        Limits = maps:get(<<"sandbox_limits">>, Config),
        true = exact(Limits, [<<"memory_bytes">>, <<"pids">>, <<"cpu_percent">>, <<"cpu_seconds">>,
            <<"address_space_bytes">>, <<"file_bytes">>, <<"open_files">>, <<"output_bytes">>, <<"wall_ms">>]),
        true = lists:all(fun(V) -> bounded(V, 1, (1 bsl 63) - 1) end, maps:values(Limits)),
        true = valid_policy(maps:get(<<"policy">>, Config)), {ok, Config}
    catch _:_ -> {error, evaluation_configuration_required} end.

valid_policy(Policy) ->
    true = exact(Policy, [<<"version">>, <<"repetitions">>, <<"min_success_delta_ppm">>, <<"max_success_regression_ppm">>,
        <<"max_latency_ratio_milli">>, <<"max_model_cost_ratio_milli">>, <<"max_model_tokens_ratio_milli">>,
        <<"max_failure_rate_ppm">>, <<"max_tool_requests">>, <<"mock_input_tokens">>, <<"mock_output_tokens">>,
        <<"mock_cost_microunits">>, <<"repair_approval">>, <<"min_agent_test_modules">>, <<"cases">>]),
    1 = maps:get(<<"version">>, Policy),
    true = bounded(maps:get(<<"repetitions">>, Policy), 1, 32) andalso bounded(maps:get(<<"max_tool_requests">>, Policy), 2, 32),
    true = bounded(maps:get(<<"min_agent_test_modules">>, Policy), 0, 128),
    true = lists:all(fun(K) -> bounded(maps:get(K, Policy), 1, 1000000) end,
        [<<"max_latency_ratio_milli">>, <<"max_model_cost_ratio_milli">>, <<"max_model_tokens_ratio_milli">>]),
    true = lists:all(fun(K) -> bounded(maps:get(K, Policy), 0, 1000000) end,
        [<<"min_success_delta_ppm">>, <<"max_success_regression_ppm">>, <<"max_failure_rate_ppm">>]),
    true = lists:all(fun(K) -> bounded(maps:get(K, Policy), 0, (1 bsl 63) - 1) end,
        [<<"mock_input_tokens">>, <<"mock_output_tokens">>, <<"mock_cost_microunits">>]),
    Approval = maps:get(<<"repair_approval">>, Policy),
    true = Approval =:= null orelse text(Approval, 256),
    true = Approval =/= null orelse maps:get(<<"min_success_delta_ppm">>, Policy) > 0,
    Cases = maps:get(<<"cases">>, Policy),
    true = is_list(Cases) andalso length(Cases) > 0 andalso length(Cases) =< 32,
    true = lists:all(fun valid_case/1, Cases),
    true = length(lists:usort([maps:get(<<"id">>, C) || C <- Cases])) =:= length(Cases),
    true = lists:usort([maps:get(<<"kind">>, C) || C <- Cases]) =:= [<<"memory">>, <<"task">>, <<"tool">>],
    true = lists:any(fun(C) -> maps:get(<<"objective">>, C) end, Cases),
    true = lists:any(fun(C) -> maps:get(<<"required">>, C) end, Cases),
    byte_size(jsx:encode(Policy)) =< 262144.
valid_case(C) ->
    exact(C, [<<"id">>, <<"message">>, <<"history">>, <<"model_result">>, <<"expected_messages">>,
        <<"expected_type">>, <<"expected_text">>, <<"kind">>, <<"required">>, <<"objective">>]) andalso
    text(maps:get(<<"id">>, C), 64) andalso text(maps:get(<<"message">>, C), 65536) andalso
    valid_messages(maps:get(<<"history">>, C), 16) andalso valid_messages(maps:get(<<"expected_messages">>, C), 32) andalso
    text(maps:get(<<"expected_text">>, C), 65536) andalso
    lists:member(maps:get(<<"expected_type">>, C), [<<"reply">>, <<"failure">>]) andalso
    lists:member(maps:get(<<"kind">>, C), [<<"task">>, <<"memory">>, <<"tool">>]) andalso
    is_boolean(maps:get(<<"required">>, C)) andalso is_boolean(maps:get(<<"objective">>, C)) andalso
    case maps:get(<<"model_result">>, C) of
        #{<<"text">> := Value} = R when map_size(R) =:= 1 -> text(Value, 65536);
        #{<<"error">> := Value} = R when map_size(R) =:= 1 -> text(Value, 256);
        _ -> false end.
valid_messages(Messages, Max) ->
    is_list(Messages) andalso length(Messages) =< Max andalso lists:all(fun(M) ->
        exact(M, [<<"role">>, <<"content">>]) andalso
        lists:member(maps:get(<<"role">>, M), [<<"system">>, <<"user">>, <<"assistant">>]) andalso
        text(maps:get(<<"content">>, M), 65536) end, Messages).

binding_keys() -> [<<"configuration_hash">>, <<"harness_hash">>, <<"test_recipe_hash">>, <<"sandbox_hash">>, <<"source_helper_hash">>].
valid_binding(Binding) -> exact(Binding, binding_keys()) andalso lists:all(fun hex/1, maps:values(Binding)).
valid_configuration(Bytes, Binding) ->
    try
        true = is_binary(Bytes) andalso byte_size(Bytes) =< 1048576,
        true = ae_policy:sha256(Bytes) =:= maps:get(<<"configuration_hash">>, Binding),
        {ok, _} = validate_config(jsx:decode(Bytes, [return_maps, strict])), true
    catch _:_ -> false end.
valid_result(Result, Job, Lease) ->
    try
        true = is_map(Result) andalso byte_size(jsx:encode(Result)) =< 65536,
        true = exact(Result, [<<"version">>, <<"job_id">>, <<"attempt">>, <<"execution_id">>,
            <<"baseline_digest">>, <<"candidate_digest">>, <<"policy_hash">>, <<"trial_seed">>, <<"gates">>, <<"baseline">>, <<"candidate">>,
            <<"passed">>, <<"measured_at_ms">>, <<"measurement_scope">>, <<"uncertainty">>] ++ binding_keys()),
        1 = maps:get(<<"version">>, Result),
        true = maps:get(<<"job_id">>, Result) =:= maps:get(<<"id">>, Job),
        true = maps:get(<<"attempt">>, Result) =:= maps:get(<<"attempts">>, Job),
        true = maps:get(<<"execution_id">>, Result) =:= maps:get(<<"id">>, Lease),
        true = maps:get(<<"baseline_digest">>, Result) =:= maps:get(<<"digest">>, maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job))),
        true = maps:get(<<"candidate_digest">>, Result) =:= maps:get(<<"digest">>, maps:get(<<"built_artifact">>, Job)),
        Binding = maps:get(<<"evaluation_binding">>, Lease), true = valid_binding(Binding),
        Binding = maps:with(binding_keys(), Result), true = hex(maps:get(<<"policy_hash">>, Result)),
        true = hex(maps:get(<<"trial_seed">>, Result)),
        true = valid_configuration(maps:get(<<"evaluation_configuration">>, Lease), Binding),
        true = bounded(maps:get(<<"measured_at_ms">>, Result), maps:get(<<"reserved_at_ms">>, Lease),
            min(maps:get(<<"expires_at_ms">>, Lease), erlang:system_time(millisecond))),
        <<"synthetic_mock_tools">> = maps:get(<<"measurement_scope">>, Result),
        true = text(maps:get(<<"uncertainty">>, Result), 256),
        true = valid_measurement(maps:get(<<"baseline">>, Result)) andalso valid_measurement(maps:get(<<"candidate">>, Result)),
        Gates = maps:get(<<"gates">>, Result),
        true = exact(Gates, [<<"isolation">>, <<"candidate_tests">>, <<"baseline_contract">>, <<"candidate_contract">>, <<"rollback_restore">>]),
        true = lists:all(fun is_boolean/1, maps:values(Gates)),
        Passed = maps:get(<<"passed">>, Result),
        is_boolean(Passed) andalso (not Passed orelse (lists:all(fun(V) -> V end, maps:values(Gates)) andalso
            maps:get(<<"required_failed">>, maps:get(<<"candidate">>, Result)) =:= 0))
    catch _:_ -> false end.
valid_measurement(M) ->
    true = exact(M, [<<"success">>, <<"objective">>, <<"task_success">>, <<"memory_retrieval">>, <<"tool_correctness">>,
        <<"required_failed">>, <<"crash_timeout">>, <<"latency_us">>, <<"mock_model">>]),
    true = lists:all(fun(K) -> valid_proportion(maps:get(K, M)) end,
        [<<"success">>, <<"objective">>, <<"task_success">>, <<"memory_retrieval">>, <<"tool_correctness">>, <<"crash_timeout">>]),
    Total = maps:get(<<"total">>, maps:get(<<"success">>, M)),
    true = bounded(maps:get(<<"required_failed">>, M), 0, Total),
    Latency = maps:get(<<"latency_us">>, M), Model = maps:get(<<"mock_model">>, M),
    true = exact(Latency, [<<"samples">>, <<"mean">>, <<"min">>, <<"max">>]),
    Total = maps:get(<<"samples">>, Latency),
    true = lists:all(fun(V) -> bounded(V, 0, (1 bsl 63) - 1) end, maps:values(Latency)),
    true = maps:get(<<"min">>, Latency) =< maps:get(<<"mean">>, Latency) andalso maps:get(<<"mean">>, Latency) =< maps:get(<<"max">>, Latency),
    exact(Model, [<<"calls">>, <<"input_tokens">>, <<"output_tokens">>, <<"cost_microunits">>]) andalso
        lists:all(fun(V) -> bounded(V, 0, (1 bsl 63) - 1) end, maps:values(Model)).
valid_proportion(P) ->
    true = exact(P, [<<"passed">>, <<"total">>, <<"rate_ppm">>, <<"wilson95_ppm">>]),
    Total = maps:get(<<"total">>, P), Passed = maps:get(<<"passed">>, P), Rate = maps:get(<<"rate_ppm">>, P),
    true = bounded(Total, 1, 1024) andalso bounded(Passed, 0, Total),
    true = Rate =:= Passed * 1000000 div Total,
    [Low, High] = maps:get(<<"wilson95_ppm">>, P), bounded(Low, 0, Rate) andalso bounded(High, Rate, 1000000).
exact(Map, Keys) -> is_map(Map) andalso lists:sort(maps:keys(Map)) =:= lists:sort(Keys).
bounded(V, Low, High) -> is_integer(V) andalso V >= Low andalso V =< High.
text(V, Max) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< Max.
hex(V) -> is_binary(V) andalso re:run(V, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match.
