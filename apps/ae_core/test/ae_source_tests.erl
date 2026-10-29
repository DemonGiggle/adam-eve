-module(ae_source_tests).
-include_lib("eunit/include/eunit.hrl").

pinned_pagination_ranges_and_disclosure_test() ->
    Root = filename:join("/tmp", "ae-source-" ++ integer_to_list(erlang:unique_integer([positive]))),
    Work = filename:join(Root, "work"),
    try
        ok = filelib:ensure_dir(filename:join(Work, "placeholder")),
        git(["init", Work]), git(["init", "--bare", filename:join(Root, "source.git")]),
        lists:foreach(fun(N) -> write(Work, "apps/ae_seed/src/f" ++ integer_to_list(N) ++ ".erl", <<"public source\n">>) end,
                      lists:seq(1, 12)),
        Big = binary:copy(<<"abcdef">>, 200000),
        write(Work, "apps/ae_seed/src/large.erl", Big),
        write(Work, "apps/ae_seed/src/.env", <<"PRIVATE_SEED_ENV">>),
        write(Work, "apps/ae_core/src/secret.erl", <<"PRIVATE_CONTROLLER">>),
        write(Work, "test/private/held_out.erl", <<"PRIVATE_EVALUATOR">>),
        write(Work, "apps/ae_seed/rebar.config", <<"{deps, []}.\n">>),
        write(Work, "docs/PROTOCOL.md", <<"Public contract documentation\n">>),
        ok = file:make_symlink("/etc/passwd", filename:join(Work, "apps/ae_seed/src/link.erl")),
        git(["-C", Work, "add", "."]),
        git(["-C", Work, "-c", "user.name=test", "-c", "user.email=test@localhost", "commit", "-m", "source fixture"]),
        Revision = git(["-C", Work, "rev-parse", "HEAD"]), Digest = ae_policy:sha256(<<"fixture artifact">>),
        git(["--git-dir", filename:join(Root, "source.git"), "fetch", Work, "HEAD:refs/generations/" ++ binary_to_list(Digest)]),
        {ok, _} = ae_store:start_link(Root),
        Seed = ae_store:boot(#{<<"digest">> => Digest, <<"source_revision">> => Revision,
            <<"capabilities">> => [<<"source_list">>, <<"source_read">>, <<"evolution_status">>]}),
        {ok, Base} = ae_store:activate(Seed, <<"runtime">>), Auth = {<<"adam">>, <<"runtime">>, 1},
        {ok, Job} = ae_store:evolution({create, Base, <<"operator">>, <<"source inspection">>, limits()}),
        Id = maps:get(<<"id">>, Job),
        Entries = pages(Root, Auth, Id, 0, []),
        Paths = [maps:get(<<"path">>, E) || E <- Entries],
        ?assertEqual(15, length(Paths)),
        ?assertEqual(length(Paths), length(lists:usort(Paths))),
        ?assertNot(lists:member(<<"apps/ae_seed/src/link.erl">>, Paths)),
        ?assertNot(lists:member(<<"apps/ae_seed/src/.env">>, Paths)),
        ?assertEqual({error, source_unavailable}, ae_source:read(Root, Auth, Id, <<"apps/ae_seed/src/link.erl">>, 0, 32)),
        {ok, Range} = ae_source:read(Root, Auth, Id, <<"apps/ae_seed/src/large.erl">>, 1100000, 128),
        ?assertEqual(binary:part(Big, 1100000, 128), base64:decode(maps:get(<<"data_base64">>, Range))),
        ?assertEqual(false, maps:get(<<"eof">>, Range)),
        ?assert(byte_size(jsx:encode(Range)) =< 1024),
        %% Changing a checkout never changes this immutable source view.
        write(Work, "apps/ae_seed/src/f1.erl", <<"UNCOMMITTED CHECKOUT CONTENT">>),
        {ok, Original} = ae_source:read(Root, Auth, Id, <<"apps/ae_seed/src/f1.erl">>, 0, 128),
        ?assertEqual(<<"public source\n">>, base64:decode(maps:get(<<"data_base64">>, Original))),
        {ok, Last} = ae_source:read(Root, Auth, Id, <<"apps/ae_seed/src/large.erl">>, byte_size(Big) - 2, 128),
        ?assertEqual(<<"ef">>, base64:decode(maps:get(<<"data_base64">>, Last))),
        ?assertEqual(true, maps:get(<<"eof">>, Last)),
        %% The actual authoring broker binds every source/status request to the
        %% authenticated runtime, authorized job and immutable source identity.
        Bound = #{<<"job_id">> => Id, <<"base_artifact">> => Digest, <<"base_source_revision">> => Revision},
        Tool = fun(Name, Args) -> #{<<"protocol_version">> => 1, <<"type">> => <<"tool_request">>,
            <<"request_id">> => Id, <<"epoch">> => 1, <<"tool">> => Name,
            <<"idempotency_key">> => <<"source-1">>, <<"args">> => maps:merge(Bound, Args)} end,
        Config = #{root => Root},
        ?assertMatch({ok, #{<<"id">> := Id}}, ae_authoring_broker:request(Auth, Id, Tool(<<"evolution_status">>, #{}), Config)),
        Before = ae_store:last_seq(),
        ?assertEqual({error, denied}, ae_authoring_broker:request(Auth, Id, Tool(<<"source_list">>,
            #{<<"offset">> => 0, <<"count">> => 2, <<"base_artifact">> => <<"wrong">>}), Config)),
        ?assertEqual({error, denied}, ae_authoring_broker:request(Auth, <<"invented">>, Tool(<<"evolution_status">>, #{}), Config)),
        ?assertEqual({error, denied}, ae_authoring_broker:request(Auth, Id, Tool(<<"shell">>, #{}), Config)),
        ?assertEqual(Before, ae_store:last_seq()),
        ?assertMatch({ok, #{<<"entries">> := [_, _]}}, ae_authoring_broker:request(Auth, Id,
            Tool(<<"source_list">>, #{<<"offset">> => 0, <<"count">> => 2}), Config)),
        ?assertEqual({error, protected_source}, ae_authoring_broker:request(Auth, Id,
            Tool(<<"source_read">>, #{<<"path">> => <<"apps/ae_core/src/secret.erl">>, <<"offset">> => 0, <<"bytes">> => 32}), Config)),
        ?assertEqual(<<"rejected">>, maps:get(<<"status">>, ae_store:evolution({get, Id}))),
        {ok, Job2} = ae_store:evolution({create, Base, <<"operator-2">>, <<"source inspection">>, limits()}),
        Id2 = maps:get(<<"id">>, Job2),
        ?assertEqual({error, protected_source}, ae_source:read(Root, Auth, Id2,
            <<"apps/ae_seed/src/../../ae_core/src/secret.erl">>, 0, 32)),
        {ok, _} = ae_store:activate(Base, <<"replacement">>),
        ?assertEqual({error, stale_runtime}, ae_source:list(Root, Auth, Id, 0, 2))
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.

pages(Root, Auth, Id, Offset, Acc) ->
    {ok, Page} = ae_source:list(Root, Auth, Id, Offset, 2),
    ?assert(byte_size(jsx:encode(Page)) =< 1024),
    Next = Acc ++ maps:get(<<"entries">>, Page),
    case maps:get(<<"eof">>, Page) of true -> Next; false -> pages(Root, Auth, Id, maps:get(<<"next_offset">>, Page), Next) end.
git(Args) -> {ok, Reply} = ae_os:run(os:find_executable("git"), Args, 10000), Reply.
write(Work, Relative, Bytes) ->
    Path = filename:join(Work, Relative), ok = filelib:ensure_dir(Path), ok = file:write_file(Path, Bytes).
limits() -> #{<<"max_attempts">> => 2, <<"total_ms">> => 60000, <<"max_llm_calls">> => 2,
    <<"tokens_per_call">> => 100, <<"max_tokens">> => 200, <<"max_cost_microunits">> => 0,
    <<"cost_per_call_microunits">> => 0, <<"max_patch_bytes">> => 4096,
    <<"max_diagnostic_bytes">> => 1024, <<"max_source_calls">> => 100, <<"max_source_bytes">> => 102400,
    <<"source_page_bytes">> => 1024, <<"build_ms">> => 5000, <<"evaluation_ms">> => 5000,
    <<"cpu_ms">> => 5000, <<"memory_bytes">> => 536870912, <<"processes">> => 32,
    <<"disk_reserve_bytes">> => 1048576}.
