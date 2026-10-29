-module(ae_sandbox_tests).
-include_lib("eunit/include/eunit.hrl").

generated_artifact_requires_isolation_test() ->
    Manifest = #{<<"digest">> => ae_policy:sha256(<<"fixture">>), <<"authoring">> => <<"llm">>},
    ?assertError(sandbox_required, ae_sandbox:runtime("/tmp/retained", Manifest, "/tmp/ipc",
        #{token => <<"runtime-token">>, config => #{runtime_isolation => development}})).
