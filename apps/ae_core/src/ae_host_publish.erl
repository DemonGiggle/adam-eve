-module(ae_host_publish).
-export([publish/4, publish/5]).

%% Publish opaque release bytes under the same lock as backup/manual tools.
%% The observer sees publication steps and is never selected by agent
%% input. It also lets crash tests stop a publisher at a precise boundary.
publish(Root, Executable, Manifest, Job) ->
    publish(Root, Executable, Manifest, Job, fun(_) -> ok end).
publish(Root, Executable, Manifest, Job, Observer) when is_function(Observer, 1) ->
    ae_host_lock:with(filename:join(Root, "publication.lock"), 10000,
        fun() -> write_release(Root, Executable, Manifest, Job, Observer) end).

write_release(Root, Executable, Manifest, Job, Observe) ->
    Encoded = <<(jsx:encode(Manifest))/binary, "\n">>,
    {ok, Free} = ae_storage:available(Root),
    true = Free >= byte_size(Executable) + byte_size(Encoded) +
        maps:get(<<"disk_reserve_bytes">>, maps:get(<<"limits">>, Job)),
    Digest = maps:get(<<"digest">>, Manifest), Revision = maps:get(<<"source_revision">>, Manifest),
    Digest = ae_policy:sha256(Executable),
    true = hex(Digest, 64) andalso hex(Revision, 40),
    Ref = "refs/generations/" ++ binary_to_list(Digest),
    {ok, Prev0} = ae_host_git:run(Root, ["for-each-ref", "--format=%(objectname)", Ref], [], 4096),
    Prev = string:trim(Prev0), true = Prev =:= <<>> orelse Prev =:= Revision,
    Old = case Prev of <<>> -> lists:duplicate(40, $0); _ -> binary_to_list(Prev) end,
    {ok, _} = ae_host_git:run(Root, ["update-ref", Ref, binary_to_list(Revision), Old], [], 4096),
    sync_filesystem(filename:join(Root, "source.git")), Observe(source_synced),
    Artifacts = filename:join(Root, "artifacts"), Target = filename:join(Artifacts, binary_to_list(Digest)),
    case file:read_link_info(Target) of
        {ok, _} ->
            {ok, Existing} = file:read_file(filename:join(Target, "manifest.json")),
            case jsx:decode(Existing, [return_maps]) =:= Manifest of true -> ok; false -> error(artifact_conflict) end,
            {ok, Saved} = file:read_file(filename:join(Target, "seed")),
            case ae_policy:sha256(Saved) =:= Digest of true -> ok; false -> error(artifact_conflict) end,
            sync_filesystem(Target), Observe(parent_synced);
        {error, enoent} ->
            Nonce = string:lowercase(binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(4)))),
            Id = maps:get(<<"id">>, Job), true = hex(Id, 64),
            Stage = filename:join(Artifacts, ".publishing-" ++ binary_to_list(binary:part(Id, 0, 12)) ++ "-" ++ Nonce),
            ok = file:make_dir(Stage), ok = file:change_mode(Stage, 8#700),
            try
                ok = save(filename:join(Stage, "seed"), Executable, fun() -> Observe(seed_written) end),
                ok = save(filename:join(Stage, "manifest.json"), Encoded, fun() -> ok end),
                Observe(manifest_synced), sync_filesystem(Stage), Observe(before_rename),
                ok = file:rename(Stage, Target), Observe(after_rename),
                sync_filesystem(Artifacts), Observe(parent_synced)
            after file:del_dir_r(Stage) end;
        _ -> error(artifact_unavailable)
    end,
    ok.
save(Path, Bytes, BeforeSync) ->
    {ok, File} = file:open(Path, [raw, binary, write, exclusive]),
    try
        ok = file:write(File, Bytes), ok = file:change_mode(Path, 8#444),
        BeforeSync(), file:sync(File)
    after file:close(File) end.
sync_filesystem(Path) ->
    {ok, _} = ae_host_command:run("/usr/bin/sync", ["-f", Path], [], 10000, 4096), ok.
hex(V, Length) -> is_binary(V) andalso byte_size(V) =:= Length andalso
    re:run(V, <<"^[0-9a-f]+$">>, [{capture, none}]) =:= match.
