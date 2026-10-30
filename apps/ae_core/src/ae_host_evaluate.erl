-module(ae_host_evaluate).
-include_lib("kernel/include/file.hrl").
-export([evaluate/5]).

%% Independent synthetic evaluation on the host. Candidate code and tests run
%% as the controller user; the host_execution gate reports this explicitly.
evaluate(Root, Job, Lease, Config, Workspace) ->
    try
        {ok, Config} = ae_evaluator:validate_config(Config),
        Deadline = deadline(Job, Lease),
        Base = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
        Candidate = maps:get(<<"built_artifact">>, Job),
        Id = maps:get(<<"id">>, Job), Id = maps:get(<<"producing_job">>, Candidate),
        Attempt = maps:get(<<"attempts">>, Job), Attempt = maps:get(<<"producing_attempt">>, Candidate),
        Parent = maps:get(<<"digest">>, Base), Parent = maps:get(<<"parent">>, Candidate),
        Capabilities = maps:get(<<"capabilities">>, Base), Capabilities = maps:get(<<"capabilities">>, Candidate),
        [1] = maps:get(<<"state_schema_versions">>, Base), [1] = maps:get(<<"state_schema_versions">>, Candidate),
        Cap = maps:get(<<"artifact_bytes">>, Config),
        lists:foreach(fun(Manifest) ->
            {ok, Info} = file:read_file_info(ae_artifacts:executable(Root, Manifest)),
            true = Info#file_info.type =:= regular andalso Info#file_info.size > 0 andalso Info#file_info.size =< Cap
        end, [Base, Candidate]),
        ok = ae_artifacts:verify(Root, Base), ok = ae_artifacts:verify(Root, Candidate),
        ok = ae_artifacts:verify_parent(Root, Candidate, Base),
        {ok, Free} = ae_storage:available(Root),
        true = Free >= maps:get(<<"source_bytes">>, Config) + maps:get(<<"artifact_bytes">>, Config) +
            maps:get(<<"disk_reserve_bytes">>, maps:get(<<"limits">>, Job)),
        Policy = maps:get(<<"policy">>, Config), Seed = crypto:strong_rand_bytes(32),
        Templates = lists:append(lists:duplicate(maps:get(<<"repetitions">>, Policy), maps:get(<<"cases">>, Policy))),
        Cases = [ae_host_metrics:instantiate(Case, binary:part(ae_policy:sha256(<<Seed/binary, Index:32/big>>), 0, 32)) ||
            {Case, Index} <- lists:zip(Templates, lists:seq(0, length(Templates) - 1))],
        Tests = candidate_tests(Root, Candidate, Config, Policy, Workspace, Deadline),
        {BaseResults, BaseContract} = trials(Root, Base, Config, Policy, Cases, Deadline),
        {CandidateResults, CandidateContract} = trials(Root, Candidate, Config, Policy, Cases, Deadline),
        Rollback = rollback(Root, Base, Config, Policy, Cases, BaseResults, CandidateResults, BaseContract, Deadline),
        Gates = #{<<"host_execution">> => true, <<"candidate_tests">> => Tests,
            <<"baseline_contract">> => BaseContract, <<"candidate_contract">> => CandidateContract,
            <<"rollback_restore">> => Rollback},
        Baseline = ae_host_metrics:summarize(Cases, BaseResults, Policy),
        Proposed = ae_host_metrics:summarize(Cases, CandidateResults, Policy),
        Binding = maps:get(<<"evaluation_binding">>, Lease),
        Result = #{<<"version">> => 1, <<"job_id">> => Id, <<"attempt">> => Attempt,
            <<"execution_id">> => maps:get(<<"id">>, Lease), <<"baseline_digest">> => Parent,
            <<"candidate_digest">> => maps:get(<<"digest">>, Candidate), <<"policy_hash">> => ae_policy:digest(Policy),
            <<"trial_seed">> => hex(Seed), <<"gates">> => Gates, <<"baseline">> => Baseline, <<"candidate">> => Proposed,
            <<"passed">> => ae_host_metrics:quality_gate(Baseline, Proposed, Policy, Gates),
            <<"measured_at_ms">> => erlang:system_time(millisecond), <<"measurement_scope">> => <<"synthetic_mock_tools">>,
            <<"uncertainty">> => <<"wilson95_binomial; latency_min_mean_max; fixtures_only">>},
        true = maps:get(<<"measured_at_ms">>, Result) =< maps:get(<<"expires_at_ms">>, Lease),
        {ok, maps:merge(Result, Binding)}
    catch _:_ -> {error, evaluation_failed} end.

deadline(Job, Lease) ->
    <<"testing">> = maps:get(<<"status">>, Job), <<"evaluate">> = maps:get(<<"kind">>, Lease),
    <<"reserved">> = maps:get(<<"status">>, Lease),
    Id = maps:get(<<"id">>, Job), Id = maps:get(<<"job_id">>, Lease),
    Attempt = maps:get(<<"attempts">>, Job), Attempt = maps:get(<<"attempt">>, Lease),
    Wall = maps:get(<<"wall_ms">>, Lease), Cpu = maps:get(<<"cpu_ms">>, Lease),
    Limits = maps:get(<<"limits">>, Job),
    true = is_integer(Wall) andalso Wall > 0 andalso Wall =< maps:get(<<"evaluation_ms">>, Limits),
    true = is_integer(Cpu) andalso Cpu >= 4 andalso Cpu =< maps:get(<<"cpu_ms">>, Limits),
    Expiry = maps:get(<<"expires_at_ms">>, Lease), Expiry = maps:get(<<"reserved_at_ms">>, Lease) + Wall,
    true = Expiry =< maps:get(<<"deadline">>, Job),
    Remaining = Expiry - erlang:system_time(millisecond), true = Remaining > 0,
    erlang:monotonic_time(millisecond) + Remaining.

candidate_tests(Root, Manifest, Config, Policy, Workspace, Deadline) ->
    try
        Source = filename:join(Workspace, "source"),
        ok = ae_host_source:export(Root, maps:get(<<"source_revision">>, Manifest), Source, Config),
        Work = filename:join(Workspace, "tests"), ok = file:make_dir(Work),
        Recipe = filename:join(code:priv_dir(ae_core), "test_seed.escript"),
        Args = [Recipe, integer_to_list(maps:get(<<"min_agent_test_modules">>, Policy)), Work,
            ae_artifacts:executable(Root, Manifest), Source],
        Timeout = Deadline - erlang:monotonic_time(millisecond), true = Timeout > 0,
        Limit = output_budget(Config),
        case ae_host_command:run("/usr/bin/escript", Args, [], Timeout, Limit) of
            {ok, Output} -> binary:match(Output, <<"AE_TESTS_V1 ">>) =/= nomatch;
            _ -> false end
    catch _:_ -> false end.

trials(Root, Manifest, Config, Policy, Cases, Deadline) ->
    try ae_host_eval_runtime:start(Root, Manifest, Config, Deadline) of
        {ok, Runtime} ->
            try
                {Results, Contract} = trial_cases(Runtime, Cases, Policy, []),
                {Results, Contract}
            after ae_host_eval_runtime:close(Runtime) end
    catch _:_ -> {failed_cases(Cases, Config, 0), false} end.
trial_cases(Runtime, [], _, Acc) ->
    try
        State = ae_host_eval_runtime:restore(Runtime, maps:get(sequence, Runtime) + length(Acc) * 3),
        ok = ae_host_eval_runtime:health(State), {lists:reverse(Acc), true}
    catch _:_ -> {lists:reverse(Acc), false} end;
trial_cases(Runtime, [Case | Rest] = Remaining, Policy, Acc) ->
    try ae_host_eval_runtime:turn(Runtime, Case, Policy) of
        Result -> trial_cases(Runtime, Rest, Policy, [Result | Acc])
    catch _:_ ->
        Accounted = lists:sum([maps:get(calls, R) || R <- Acc]),
        Unreported = max(0, ae_host_eval_runtime:calls(Runtime) - Accounted),
        {lists:reverse(Acc) ++ failed_cases(Remaining, maps:get(config, Runtime), Unreported), false}
    end.
failed_cases([], _, _) -> [];
failed_cases([_ | Rest], Config, Calls) ->
    [#{success => false, memory_correct => false, tool_correct => false, calls => Calls,
        latency_us => maps:get(<<"turn_ms">>, Config) * 1000, runtime_failed => true} | failed_cases(Rest, Config, 0)].

rollback(_, _, _, _, _, _, _, false, _) -> false;
rollback(Root, Base, Config, Policy, [First | _] = Cases, [Baseline | _], CandidateResults, true, Deadline) ->
    case [R || R <- lists:reverse(CandidateResults), maps:get(outcome, R, none) =:= <<"reply">>] of
        [] -> false;
        [Latest | _] ->
            History = [#{<<"role">> => <<"user">>, <<"content">> => <<"synthetic committed work ", (hex(crypto:strong_rand_bytes(16)))/binary>>},
                #{<<"role">> => <<"assistant">>, <<"content">> => maps:get(reply, Latest)}],
            Case = First#{<<"history">> := History, <<"expected_messages">> := History ++
                [#{<<"role">> => <<"user">>, <<"content">> => maps:get(<<"message">>, First)}],
                <<"expected_text">> := maps:get(reply, Baseline, <<>>), <<"expected_type">> := maps:get(outcome, Baseline, <<"reply">>)},
            try
                {ok, Runtime} = ae_host_eval_runtime:start(Root, Base, Config, Deadline),
                try
                    State = ae_host_eval_runtime:restore(Runtime, maps:get(sequence, Runtime) + length(Cases) * 3 + 1),
                    #{success := Success} = ae_host_eval_runtime:turn(State, Case, Policy),
                    ok = ae_host_eval_runtime:health(State), Success
                after ae_host_eval_runtime:close(Runtime) end
            catch _:_ -> false end
    end.
hex(Bytes) -> list_to_binary(string:lowercase(binary_to_list(binary:encode_hex(Bytes)))).
output_budget(Config) -> case maps:find(<<"output_bytes">>, Config) of
    {ok, Value} -> Value; error -> maps:get(<<"output_bytes">>, maps:get(<<"sandbox_limits">>, Config)) end.
