-module(ae_host_build).
-export([build/6]).

%% Candidate compilation runs as the controller user on the host. The fixed
%% recipe is still used, but it is not an OS sandbox for generated code.
build(Root, Job, Proposal, Lease, Config, Workspace) ->
    try
        ok = validate_lease(Job, Proposal, Lease),
        ok = reserve(Root, maps:get(<<"source_bytes">>, Config) + maps:get(<<"artifact_bytes">>, Config) + 16 * 1024 * 1024, Job),
        Lock = filename:join(Root, "publication.lock"),
        {ok, Source, Revision, Tree} = ae_host_lock:with(Lock, remaining(Lease), fun() ->
            ae_host_prepare:prepare(Root, Job, Proposal, Workspace, Config)
        end),
        Dependency = filename:join(Workspace, "dependency"),
        {ok, DependencyRecord} = ae_build_inputs:extract(maps:get(<<"jsx_package">>, Config), Dependency),
        Recipe = filename:join(code:priv_dir(ae_core), "build_seed.escript"),
        {ok, RecipeBytes} = file:read_file(Recipe), true = byte_size(RecipeBytes) =< 1048576,
        RecipeHash = ae_policy:sha256(RecipeBytes),
        Base = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
        Args = [Recipe, Source, Dependency, binary_to_list(Revision), binary_to_list(Tree),
            binary_to_list(maps:get(<<"digest">>, Base)), binary_to_list(ae_build_inputs:package_hash()),
            binary_to_list(RecipeHash), "-"],
        MaxArtifact = maps:get(<<"artifact_bytes">>, Config),
        MaxOutput = min(output_budget(Config),
            ((MaxArtifact + 2) div 3) * 4 + 1024),
        case ae_host_command:run_capture("/usr/bin/escript", Args, [{"LANG", "C.UTF-8"}, {"TZ", "UTC"}], remaining(Lease), MaxOutput) of
            {ok, Output} ->
                [<<"AE_SEED_V1">>, Encoded, <<>>] = binary:split(Output, <<"\n">>, [global]),
                Executable = base64:decode(Encoded),
                true = byte_size(Executable) > 0 andalso byte_size(Executable) =< MaxArtifact,
                Digest = ae_policy:sha256(Executable),
                Manifest = #{<<"digest">> => Digest, <<"source_revision">> => Revision, <<"source_tree">> => Tree,
                    <<"parent">> => maps:get(<<"digest">>, Base), <<"otp_release">> => maps:get(<<"otp_release">>, Base),
                    <<"erts_version">> => maps:get(<<"erts_version">>, Base), <<"capabilities">> => maps:get(<<"capabilities">>, Base),
                    <<"state_schema_versions">> => maps:get(<<"state_schema_versions">>, Base), <<"authoring">> => <<"llm">>,
                    <<"objective">> => maps:get(<<"objective">>, Job), <<"producing_job">> => maps:get(<<"id">>, Job),
                    <<"producing_attempt">> => maps:get(<<"attempt">>, Proposal), <<"patch_hash">> => maps:get(<<"patch_hash">>, Proposal),
                    <<"build_recipe">> => <<"ae_seed_v1">>, <<"build_provenance">> => #{<<"recipe">> => <<"ae_seed_v1">>,
                        <<"resource_limits_mode">> => <<"host">>, <<"recipe_sha256">> => RecipeHash,
                        <<"dependency">> => DependencyRecord}, <<"evaluation">> => null},
                _ = remaining(Lease),
                ok = ae_host_publish:publish(Root, Executable, Manifest, Job),
                {ok, Manifest};
            {error, {exit_status, _, Diagnostics}} ->
                MaxDiagnostics = maps:get(<<"max_diagnostic_bytes">>, maps:get(<<"limits">>, Job)),
                {error, compilation_failed, diagnostic(Diagnostics, MaxDiagnostics)};
            {error, Reason} -> {error, Reason, <<>>}
        end
    catch
        error:{badmatch, {error, patch_did_not_apply}} -> {error, patch_did_not_apply, <<"Patch does not apply cleanly to its pinned source.">>};
        _:_ -> {error, build_failed, <<>>}
    end.

validate_lease(Job, Proposal, Lease) ->
    <<"building">> = maps:get(<<"status">>, Job), <<"build">> = maps:get(<<"kind">>, Lease),
    <<"reserved">> = maps:get(<<"status">>, Lease),
    Id = maps:get(<<"id">>, Job), Id = maps:get(<<"job_id">>, Lease),
    Attempt = maps:get(<<"attempts">>, Job), Attempt = maps:get(<<"attempt">>, Lease),
    Attempt = maps:get(<<"attempt">>, Proposal),
    Wall = maps:get(<<"wall_ms">>, Lease), Cpu = maps:get(<<"cpu_ms">>, Lease),
    Limits = maps:get(<<"limits">>, Job),
    true = is_integer(Wall) andalso Wall > 0 andalso Wall =< maps:get(<<"build_ms">>, Limits),
    true = is_integer(Cpu) andalso Cpu > 0 andalso Cpu =< maps:get(<<"cpu_ms">>, Limits),
    Expiry = maps:get(<<"expires_at_ms">>, Lease),
    Expiry = maps:get(<<"reserved_at_ms">>, Lease) + Wall,
    true = Expiry =< maps:get(<<"deadline">>, Job), _ = remaining(Lease), ok.
remaining(Lease) ->
    Remaining = maps:get(<<"expires_at_ms">>, Lease) - erlang:system_time(millisecond),
    true = Remaining > 0, Remaining.
reserve(Root, Bytes, Job) ->
    {ok, Free} = ae_storage:available(Root),
    true = Free >= Bytes + maps:get(<<"disk_reserve_bytes">>, maps:get(<<"limits">>, Job)), ok.

output_budget(Config) -> case maps:find(<<"output_bytes">>, Config) of
    {ok, Value} -> Value; error -> maps:get(<<"output_bytes">>, maps:get(<<"sandbox_limits">>, Config)) end.
diagnostic(Bytes, Limit) ->
    Truncated = binary:part(Bytes, 0, min(byte_size(Bytes), Limit)),
    Valid = unicode:characters_to_binary(Truncated, utf8, utf8),
    case Valid of B when is_binary(B) -> B; {incomplete, B, _} -> B; {error, B, _} -> B end.
