-module(ae_host_prepare_tests).
-include_lib("eunit/include/eunit.hrl").

prepares_the_pinned_patch_as_a_reproducible_child_test() ->
    Root = filename:join("/tmp", "ae-host-prepare-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Work = filename:join(Root, "work"), Repo = filename:join(Root, "source.git"),
    try
        ok = filelib:ensure_dir(filename:join(Work, "placeholder")),
        git(["init", Work]), git(["init", "--bare", Repo]),
        Target = filename:join(Work, "apps/ae_seed/src/seed.erl"),
        ok = filelib:ensure_dir(Target), ok = file:write_file(Target, <<"old\n">>),
        git(["-C", Work, "add", "."]),
        git(["-C", Work, "-c", "user.name=test", "-c", "user.email=test@localhost", "commit", "-m", "base"]),
        Revision = git(["-C", Work, "rev-parse", "HEAD"]), Tree = git(["-C", Work, "rev-parse", "HEAD^{tree}"]),
        Digest = ae_policy:sha256(<<"baseline">>),
        git(["--git-dir", Repo, "fetch", Work, "HEAD:refs/generations/" ++ binary_to_list(Digest)]),
        Id = ae_policy:sha256(<<"job">>),
        Base = #{<<"digest">> => Digest, <<"source_revision">> => Revision, <<"source_tree">> => Tree},
        Limits = #{<<"max_patch_bytes">> => 4096, <<"total_ms">> => 60000},
        Job = #{<<"id">> => Id, <<"status">> => <<"building">>, <<"attempts">> => 1,
            <<"baseline">> => #{<<"artifact">> => Base, <<"epoch">> => 2},
            <<"limits">> => Limits, <<"deadline">> => 1700000060000, <<"objective">> => <<"change reply">>},
        Patch = <<"diff --git a/apps/ae_seed/src/seed.erl b/apps/ae_seed/src/seed.erl\n",
            "--- a/apps/ae_seed/src/seed.erl\n+++ b/apps/ae_seed/src/seed.erl\n@@ -1 +1 @@\n-old\n+new\n">>,
        Proposal = #{<<"attempt">> => 1, <<"base_artifact">> => Digest, <<"base_source_revision">> => Revision,
            <<"epoch">> => 2, <<"patch">> => Patch, <<"patch_hash">> => ae_policy:sha256(Patch),
            <<"paths">> => [<<"apps/ae_seed/src/seed.erl">>]},
        Config = #{<<"source_files">> => 16, <<"source_bytes">> => 4096},
        One = filename:join(Root, "one"), Two = filename:join(Root, "two"),
        ok = file:make_dir(One), ok = file:make_dir(Two),
        {ok, Source, Child, ChildTree} = ae_host_prepare:prepare(Root, Job, Proposal, One, Config),
        ?assertEqual({ok, <<"new\n">>}, file:read_file(filename:join(Source, "apps/ae_seed/src/seed.erl"))),
        {ok, _, Child, ChildTree} = ae_host_prepare:prepare(Root, Job, Proposal, Two, Config),
        ?assertEqual(Revision, git(["--git-dir", Repo, "rev-parse", binary_to_list(Child) ++ "^"])),
        ?assertEqual({error, source_preparation_failed},
            ae_host_prepare:prepare(Root, Job, Proposal#{<<"epoch">> := 3}, Two, Config))
    after file:del_dir_r(Root) end.

git(Args) -> {ok, Value} = ae_os:run(os:find_executable("git"), Args, 10000), Value.
