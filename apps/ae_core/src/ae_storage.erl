-module(ae_storage).
-export([validate_retention/1, preflight/2]).

%% v0.1 retains the complete published history and audit. No historical delete
%% policy is silently interpreted as permission to remove rollback resources.
validate_retention(Policy) when is_map(Policy) ->
    case lists:sort(maps:keys(Policy)) =:= [<<"audit">>, <<"promoted_generations">>, <<"rejected_attempts">>] andalso
        lists:all(fun(V) -> V =:= <<"all">> end, maps:values(Policy)) of
        true -> {ok, Policy}; false -> {error, retention_policy_required}
    end;
validate_retention(_) -> {error, retention_policy_required}.

preflight(#{root := Root, candidate_builder := Builder}, Limits) ->
    try
        Calls = min(maps:get(<<"max_llm_calls">>, Limits),
            maps:get(<<"max_tokens">>, Limits) div maps:get(<<"tokens_per_call">>, Limits)),
        Attempts = maps:get(<<"max_attempts">>, Limits),
        Source = maps:get(<<"source_bytes">>, Builder), Artifact = maps:get(<<"artifact_bytes">>, Builder),
        %% Reserve headroom for retained attempts, bounded JSON model results,
        %% temporary exports and database/WAL copies. This is a conservative
        %% admission estimate, not a filesystem quota against other writers.
        Durable = Attempts * (Source + Artifact + maps:get(<<"max_patch_bytes">>, Limits) * 6)
            + Calls * ae_protocol:max_bytes(),
        Required = maps:get(<<"disk_reserve_bytes">>, Limits) + 2 * (Durable + Source + Artifact + ae_protocol:max_bytes()),
        {ok, Encoded} = ae_os:run("/usr/bin/python3", ["-I", "-c",
            "import os,sys; s=os.statvfs(sys.argv[1]); print(s.f_bavail*s.f_frsize)", Root], 2000),
        Free = binary_to_integer(Encoded),
        case Free >= Required of true -> ok; false -> {error, storage_pressure} end
    catch _:_ -> {error, storage_unavailable} end;
preflight(_, _) -> {error, storage_unavailable}.
