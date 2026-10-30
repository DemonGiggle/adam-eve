-module(ae_host_source_tests).
-include_lib("eunit/include/eunit.hrl").

exports_pinned_blobs_and_rejects_unapproved_tree_entries_test() ->
    Root = filename:join("/tmp", "ae-host-source-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Work = filename:join(Root, "work"),
    try
        ok = filelib:ensure_dir(filename:join(Work, "placeholder")),
        git(["init", Work]), git(["init", "--bare", filename:join(Root, "source.git")]),
        write(Work, "apps/ae_seed/src/seed.erl", <<"original\n">>),
        write(Work, "apps/ae_protocol/test/contract.erl", <<"private test\n">>),
        write(Work, "docs/PROTOCOL.md", <<"contract\n">>),
        git(["-C", Work, "add", "."]),
        git(["-C", Work, "-c", "user.name=test", "-c", "user.email=test@localhost", "commit", "-m", "fixture"]),
        Revision = git(["-C", Work, "rev-parse", "HEAD"]),
        git(["--git-dir", filename:join(Root, "source.git"), "fetch", Work, "HEAD:refs/test/base"]),
        Config = #{<<"source_files">> => 16, <<"source_bytes">> => 4096},
        write(Work, "apps/ae_seed/src/seed.erl", <<"uncommitted modification\n">>),
        Destination = filename:join(Root, "export"),
        ?assertEqual(ok, ae_host_source:export(Root, Revision, Destination, Config)),
        ?assertEqual({ok, <<"original\n">>}, file:read_file(filename:join(Destination, "apps/ae_seed/src/seed.erl"))),
        ?assertNot(filelib:is_file(filename:join(Destination, "apps/ae_protocol/test/contract.erl"))),
        ?assertEqual({error, invalid_source_tree}, ae_host_source:scan(Root, Revision, Config#{<<"source_bytes">> := 1})),
        ok = file:make_symlink("/etc/passwd", filename:join(Work, "apps/ae_seed/src/link.erl")),
        git(["-C", Work, "add", "."]),
        git(["-C", Work, "-c", "user.name=test", "-c", "user.email=test@localhost", "commit", "-m", "bad entry"]),
        Bad = git(["-C", Work, "rev-parse", "HEAD"]),
        git(["--git-dir", filename:join(Root, "source.git"), "fetch", Work, "HEAD:refs/test/bad"]),
        ?assertEqual({error, invalid_source_tree}, ae_host_source:scan(Root, Bad, Config))
    after file:del_dir_r(Root) end.

git(Args) -> {ok, Value} = ae_os:run(os:find_executable("git"), Args, 10000), Value.
write(Work, Relative, Bytes) ->
    Target = filename:join(Work, Relative), ok = filelib:ensure_dir(Target), ok = file:write_file(Target, Bytes).
