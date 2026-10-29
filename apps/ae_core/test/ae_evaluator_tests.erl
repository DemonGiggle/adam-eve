-module(ae_evaluator_tests).
-include_lib("eunit/include/eunit.hrl").

explicit_policy_and_limits_test() ->
    {ok, Encoded} = file:read_file("test/evaluation/policy.json"), Policy = jsx:decode(Encoded, [return_maps]),
    Config = #{<<"cgroup_root">> => <<"/sys/fs/cgroup/test">>, <<"source_bytes">> => 2097152,
        <<"source_files">> => 128, <<"artifact_bytes">> => 8388608, <<"startup_ms">> => 30000,
        <<"turn_ms">> => 15000, <<"policy">> => Policy,
        <<"sandbox_limits">> => #{<<"memory_bytes">> => 536870912, <<"pids">> => 64,
            <<"cpu_percent">> => 100, <<"cpu_seconds">> => 15, <<"address_space_bytes">> => 1073741824,
            <<"file_bytes">> => 33554432, <<"open_files">> => 128, <<"output_bytes">> => 1048576, <<"wall_ms">> => 180000}},
    ?assertEqual({ok, Config}, ae_evaluator:validate_config(Config)),
    [ ?assertEqual({error, evaluation_configuration_required}, ae_evaluator:validate_config(Bad)) || Bad <-
        [#{}, maps:remove(<<"turn_ms">>, Config), Config#{<<"cgroup_root">> := <<"relative">>},
         Config#{<<"policy">> := Policy#{<<"min_success_delta_ppm">> := 0}},
         Config#{<<"policy">> := Policy#{<<"cases">> := [hd(maps:get(<<"cases">>, Policy))]}},
         Config#{<<"policy">> := Policy#{<<"mock_input_tokens">> := true}}]],
    Repair = Config#{<<"policy">> := Policy#{<<"min_success_delta_ppm">> := 0, <<"repair_approval">> := <<"operator-repair-1">>}},
    ?assertEqual({ok, Repair}, ae_evaluator:validate_config(Repair)).
