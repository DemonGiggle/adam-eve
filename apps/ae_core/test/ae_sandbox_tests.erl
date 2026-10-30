-module(ae_sandbox_tests).
-include_lib("eunit/include/eunit.hrl").

generated_artifact_requires_isolation_test() ->
    Manifest = #{<<"digest">> => ae_policy:sha256(<<"fixture">>), <<"authoring">> => <<"llm">>},
    ?assertError(sandbox_required, ae_sandbox:runtime("/tmp/retained", Manifest, "/tmp/ipc",
        #{token => <<"runtime-token">>, config => #{runtime_isolation => development}})).

host_profile_is_explicit_in_launcher_test() ->
    Manifest = #{<<"digest">> => ae_policy:sha256(<<"fixture">>), <<"authoring">> => <<"llm">>},
    {"/usr/bin/python3", Args} = ae_sandbox:runtime("/tmp/retained", Manifest, "/tmp/ipc",
        #{token => <<"token">>, config => #{runtime_isolation => bubblewrap, sandbox_cgroup_root => "/sys/fs/cgroup",
            sandbox_limits => #{}, resource_limits_mode => <<"process">>}}),
    ?assertMatch([_, "--cgroup-root", _, "--resource-limits-mode", "process" | _], Args).

staging_budget_is_passed_to_kernel_launcher_test() ->
    Manifest = #{<<"digest">> => ae_policy:sha256(<<"fixture">>), <<"authoring">> => <<"llm">>},
    {"/usr/bin/python3", Args} = ae_sandbox:runtime("/tmp/retained", Manifest, "/tmp/ipc",
        #{token => <<"token">>, config => #{runtime_isolation => bubblewrap, sandbox_cgroup_root => "/sys/fs/cgroup/test",
            sandbox_limits => #{}, runtime_cpu_budget_ms => 501, runtime_deadline => 1000000}}),
    ?assert(lists:suffix(["--cpu-budget-ms", "501", "--deadline-ms", "1000000"], Args)).
