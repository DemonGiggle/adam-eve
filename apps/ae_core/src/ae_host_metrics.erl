-module(ae_host_metrics).
-export([instantiate/2, proportion/2, summarize/3, quality_gate/4]).

instantiate(Value, Nonce) when is_binary(Value) -> binary:replace(Value, <<"${nonce}">>, Nonce, [global]);
instantiate(Value, Nonce) when is_list(Value) -> [instantiate(V, Nonce) || V <- Value];
instantiate(Value, Nonce) when is_map(Value) -> maps:map(fun(_, V) -> instantiate(V, Nonce) end, Value);
instantiate(Value, _) -> Value.

proportion(0, 0) -> #{<<"passed">> => 0, <<"total">> => 0, <<"rate_ppm">> => 0, <<"wilson95_ppm">> => [0, 1000000]};
proportion(Passed, Total) when is_integer(Passed), is_integer(Total), Passed >= 0, Passed =< Total, Total > 0 ->
    P = Passed / Total, Z = 1.959963984540054,
    Center = (P + Z*Z/(2*Total)) / (1 + Z*Z/Total),
    Radius = Z * math:sqrt(P*(1-P)/Total + Z*Z/(4*Total*Total)) / (1 + Z*Z/Total),
    #{<<"passed">> => Passed, <<"total">> => Total, <<"rate_ppm">> => Passed * 1000000 div Total,
      <<"wilson95_ppm">> => [max(0, floor((Center-Radius)*1000000)), min(1000000, ceil((Center+Radius)*1000000))]}.

summarize(Cases, Results, Policy) when length(Cases) =:= length(Results), Results =/= [] ->
    Pairs = lists:zip(Cases, Results),
    Score = fun(Predicate, Field) ->
        Selected = [R || {C, R} <- Pairs, Predicate(C)],
        proportion(length([ok || R <- Selected, maps:get(Field, R)]), length(Selected))
    end,
    All = fun(_) -> true end,
    Latencies = [maps:get(latency_us, R) || R <- Results],
    Calls = lists:sum([maps:get(calls, R) || R <- Results]),
    #{<<"success">> => Score(All, success),
      <<"objective">> => Score(fun(C) -> maps:get(<<"objective">>, C) end, success),
      <<"task_success">> => Score(fun(C) -> maps:get(<<"kind">>, C) =:= <<"task">> end, success),
      <<"memory_retrieval">> => Score(All, memory_correct), <<"tool_correctness">> => Score(All, tool_correct),
      <<"required_failed">> => length([ok || {C, R} <- Pairs, maps:get(<<"required">>, C) andalso not maps:get(success, R)]),
      <<"crash_timeout">> => proportion(length([ok || R <- Results, maps:get(runtime_failed, R, false)]), length(Results)),
      <<"latency_us">> => #{<<"samples">> => length(Latencies), <<"mean">> => lists:sum(Latencies) div length(Latencies),
          <<"min">> => lists:min(Latencies), <<"max">> => lists:max(Latencies)},
      <<"mock_model">> => #{<<"calls">> => Calls, <<"input_tokens">> => Calls * maps:get(<<"mock_input_tokens">>, Policy),
          <<"output_tokens">> => Calls * maps:get(<<"mock_output_tokens">>, Policy),
          <<"cost_microunits">> => Calls * maps:get(<<"mock_cost_microunits">>, Policy)}}.

quality_gate(Baseline, Candidate, Policy, Gates) ->
    B = maps:get(<<"mock_model">>, Baseline), C = maps:get(<<"mock_model">>, Candidate),
    Ratio = fun(Key, Limit) -> maps:get(Key, C) * 1000 =< maps:get(Key, B) * maps:get(Limit, Policy) end,
    Rate = fun(Measurement, Key) -> maps:get(<<"rate_ppm">>, maps:get(Key, Measurement)) end,
    Delta = Rate(Candidate, <<"objective">>) - Rate(Baseline, <<"objective">>),
    lists:all(fun(V) -> V =:= true end, maps:values(Gates)) andalso
        maps:get(<<"required_failed">>, Candidate) =:= 0 andalso
        Rate(Candidate, <<"success">>) + maps:get(<<"max_success_regression_ppm">>, Policy) >= Rate(Baseline, <<"success">>) andalso
        Rate(Candidate, <<"crash_timeout">>) =< maps:get(<<"max_failure_rate_ppm">>, Policy) andalso
        maps:get(<<"mean">>, maps:get(<<"latency_us">>, Candidate)) * 1000 =<
            max(1, maps:get(<<"mean">>, maps:get(<<"latency_us">>, Baseline))) * maps:get(<<"max_latency_ratio_milli">>, Policy) andalso
        Ratio(<<"cost_microunits">>, <<"max_model_cost_ratio_milli">>) andalso
        Ratio(<<"input_tokens">>, <<"max_model_tokens_ratio_milli">>) andalso
        Ratio(<<"output_tokens">>, <<"max_model_tokens_ratio_milli">>) andalso
        (Delta >= maps:get(<<"min_success_delta_ppm">>, Policy) orelse maps:get(<<"repair_approval">>, Policy) =/= null).
