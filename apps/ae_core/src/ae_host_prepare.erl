-module(ae_host_prepare).
-export([prepare/5]).

%% Prepare a deterministic attempt from the protected baseline using a private
%% Git index. Candidate code is never loaded into the controller VM.
prepare(Root, Job, Proposal, Workspace, Config) ->
    try
        Id = maps:get(<<"id">>, Job), true = hex(Id, 64),
        Base = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
        Digest = maps:get(<<"digest">>, Base), Revision = maps:get(<<"source_revision">>, Base),
        Tree = maps:get(<<"source_tree">>, Base),
        true = hex(Digest, 64) andalso hex(Revision, 40) andalso hex(Tree, 40),
        <<"building">> = maps:get(<<"status">>, Job),
        Attempt = maps:get(<<"attempt">>, Proposal), true = is_integer(Attempt) andalso Attempt > 0,
        Attempt = maps:get(<<"attempts">>, Job),
        Digest = maps:get(<<"base_artifact">>, Proposal),
        Revision = maps:get(<<"base_source_revision">>, Proposal),
        Epoch = maps:get(<<"epoch">>, maps:get(<<"baseline">>, Job)),
        Epoch = maps:get(<<"epoch">>, Proposal),
        Patch = maps:get(<<"patch">>, Proposal), Limits = maps:get(<<"limits">>, Job),
        {ok, Paths} = ae_patch:validate(Patch, maps:get(<<"max_patch_bytes">>, Limits)),
        true = lists:sort(Paths) =:= lists:sort(maps:get(<<"paths">>, Proposal)),
        PatchHash = maps:get(<<"patch_hash">>, Proposal), PatchHash = ae_policy:sha256(Patch),
        Repo = filename:join(Root, "source.git"),
        lists:foreach(fun(Name) -> false = filelib:is_file(filename:join(Repo, Name)) end,
            ["objects/info/alternates", "objects/info/http-alternates", "info/grafts", "shallow"]),
        {ok, Protected0} = git(Root, ["rev-parse", "--verify", "refs/generations/" ++ binary_to_list(Digest)], []),
        Revision = string:trim(Protected0),
        {ok, Tree0} = git(Root, ["rev-parse", "--verify", binary_to_list(Revision) ++ "^{tree}"], []),
        Tree = string:trim(Tree0),
        {ok, _} = ae_host_source:scan(Root, Revision, Config),
        Index = filename:join(Workspace, "index"), PatchPath = filename:join(Workspace, "patch"),
        IndexEnv = [{"GIT_INDEX_FILE", Index}],
        ok = file:write_file(PatchPath, Patch, [exclusive]),
        {ok, _} = git(Root, ["read-tree", binary_to_list(Revision)], IndexEnv),
        case git(Root, ["apply", "--cached", "--unidiff-zero", "--whitespace=error-all", PatchPath], IndexEnv) of
            {ok, _} -> ok;
            _ -> throw(patch_did_not_apply)
        end,
        {ok, Changed0} = git(Root, ["diff", "--cached", "--name-only", "-z", binary_to_list(Revision)], IndexEnv),
        Changed = [P || P <- binary:split(Changed0, <<0>>, [global]), P =/= <<>>],
        true = lists:sort(Changed) =:= lists:sort(Paths),
        {ok, NewTree0} = git(Root, ["write-tree"], IndexEnv), NewTree = string:trim(NewTree0),
        true = hex(NewTree, 40), {ok, _} = ae_host_source:scan(Root, NewTree, Config),
        Created = (maps:get(<<"deadline">>, Job) - maps:get(<<"total_ms">>, Limits)) div 1000,
        Date = integer_to_list(Created) ++ " +0000",
        Identity = [{"GIT_AUTHOR_NAME", "adam-eve builder"}, {"GIT_AUTHOR_EMAIL", "builder@localhost"},
            {"GIT_COMMITTER_NAME", "adam-eve builder"}, {"GIT_COMMITTER_EMAIL", "builder@localhost"},
            {"GIT_AUTHOR_DATE", Date}, {"GIT_COMMITTER_DATE", Date}],
        Message = jsx:encode(#{<<"job_id">> => Id, <<"attempt">> => Attempt,
            <<"patch_hash">> => PatchHash, <<"objective">> => maps:get(<<"objective">>, Job)}),
        MessagePath = filename:join(Workspace, "commit-message"),
        ok = file:write_file(MessagePath, <<Message/binary, "\n">>, [exclusive]),
        {ok, NewRevision0} = git(Root, ["-c", "commit.gpgSign=false", "commit-tree", binary_to_list(NewTree),
            "-p", binary_to_list(Revision), "-F", MessagePath], Identity),
        NewRevision = string:trim(NewRevision0), true = hex(NewRevision, 40),
        Ref = "refs/attempts/" ++ binary_to_list(Id) ++ "/" ++ integer_to_list(Attempt),
        {ok, Existing0} = git(Root, ["for-each-ref", "--format=%(objectname)", Ref], []),
        Existing = string:trim(Existing0), true = Existing =:= <<>> orelse Existing =:= NewRevision,
        Previous = case Existing of <<>> -> lists:duplicate(40, $0); _ -> binary_to_list(Existing) end,
        {ok, _} = git(Root, ["update-ref", Ref, binary_to_list(NewRevision), Previous], []),
        {ok, _} = ae_host_command:run("/usr/bin/sync", ["-f", Repo], [], 10000, 4096),
        Source = filename:join(Workspace, "source"),
        ok = ae_host_source:export(Root, NewRevision, Source, Config),
        {ok, Source, NewRevision, NewTree}
    catch
        throw:patch_did_not_apply -> {error, patch_did_not_apply};
        _:_ -> {error, source_preparation_failed}
    end.

git(Root, Args, Env) -> ae_host_git:run(Root, Args, Env, 1048576).
hex(V, Length) -> is_binary(V) andalso byte_size(V) =:= Length andalso
    re:run(V, <<"^[0-9a-f]+$">>, [{capture, none}]) =:= match.
