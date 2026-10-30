-module(ae_host_metrics_tests).
-include_lib("eunit/include/eunit.hrl").

wilson_interval_and_nonce_substitution_test() ->
    ?assertEqual(#{<<"passed">> => 0, <<"total">> => 0, <<"rate_ppm">> => 0,
        <<"wilson95_ppm">> => [0, 1000000]}, ae_host_metrics:proportion(0, 0)),
    ?assertEqual(#{<<"passed">> => 1, <<"total">> => 2, <<"rate_ppm">> => 500000,
        <<"wilson95_ppm">> => [94531, 905469]}, ae_host_metrics:proportion(1, 2)),
    ?assertEqual(#{<<"text">> => [<<"token-123">>]},
        ae_host_metrics:instantiate(#{<<"text">> => [<<"token-${nonce}">>]}, <<"123">>)).

quality_gate_rejects_regression_and_excess_cost_test() ->
    {ok, Bytes} = file:read_file("test/evaluation/policy.json"), Policy = jsx:decode(Bytes, [return_maps]),
    Cases = maps:get(<<"cases">>, Policy),
    Good = #{success => true, memory_correct => true, tool_correct => true, calls => 1, latency_us => 100},
    Baseline = ae_host_metrics:summarize(Cases, [Good#{success := false}, Good#{success := false}, Good], Policy),
    Candidate = ae_host_metrics:summarize(Cases, [Good, Good, Good], Policy),
    Gates = #{<<"contract">> => true},
    ?assert(ae_host_metrics:quality_gate(Baseline, Candidate, Policy, Gates)),
    ?assertNot(ae_host_metrics:quality_gate(Baseline, Candidate#{<<"required_failed">> := 1}, Policy, Gates)),
    ?assertNot(ae_host_metrics:quality_gate(Baseline, Candidate, Policy, Gates#{<<"contract">> := false})),
    Expensive = Candidate#{<<"mock_model">> := (maps:get(<<"mock_model">>, Candidate))#{<<"cost_microunits">> := 100}},
    ?assertNot(ae_host_metrics:quality_gate(Baseline, Expensive, Policy, Gates)).
