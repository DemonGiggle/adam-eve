-module(ae_evolution_limits).
-export([validate/1]).

validate(Limits) when is_map(Limits) ->
    Keys = [<<"max_attempts">>, <<"total_ms">>, <<"max_llm_calls">>, <<"tokens_per_call">>,
        <<"max_tokens">>, <<"max_cost_microunits">>, <<"cost_per_call_microunits">>,
        <<"max_patch_bytes">>, <<"max_diagnostic_bytes">>, <<"max_source_calls">>,
        <<"max_source_bytes">>, <<"source_page_bytes">>, <<"build_ms">>, <<"evaluation_ms">>,
        <<"cpu_ms">>, <<"memory_bytes">>, <<"processes">>, <<"disk_reserve_bytes">>],
    try
        true = lists:sort(maps:keys(Limits)) =:= lists:sort(Keys),
        true = lists:all(fun({K, V}) -> is_integer(V) andalso V >= 0 andalso V < (1 bsl 63) andalso
            (V > 0 orelse K =:= <<"cost_per_call_microunits">> orelse K =:= <<"max_cost_microunits">>) end,
            maps:to_list(Limits)),
        true = maps:get(<<"max_patch_bytes">>, Limits) =< 262144,
        true = maps:get(<<"max_diagnostic_bytes">>, Limits) =< 65536,
        true = maps:get(<<"source_page_bytes">>, Limits) =< 65536,
        true = maps:get(<<"source_page_bytes">>, Limits) >= 1024,
        true = maps:get(<<"tokens_per_call">>, Limits) =< maps:get(<<"max_tokens">>, Limits),
        true = maps:get(<<"cost_per_call_microunits">>, Limits) =< maps:get(<<"max_cost_microunits">>, Limits),
        {ok, Limits}
    catch _:_ -> {error, evolution_limits_required} end;
validate(_) -> {error, evolution_limits_required}.
