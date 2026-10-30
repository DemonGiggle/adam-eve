-module(ae_memory_tests).
-include_lib("eunit/include/eunit.hrl").

versions_pin_turn_context_and_survive_restart_test() ->
    with_store(fun(Root, Auth) ->
        {ok, pending} = ae_store:begin_turn(Auth, <<"source">>, <<"s">>, <<"My favorite color is saffron.">>),
        {ok, _} = ae_store:finish_turn(Auth, <<"source">>, <<"Saved.">>),
        [Seq] = [N || {N, <<"user_message">>, #{<<"request_id">> := <<"source">>}} <- ae_store:events()],
        Put = {put, <<"preference-1">>, <<"preference">>, <<"favorite-color">>, <<"saffron">>, [Seq], 0},
        {ok, First} = ae_store:memory(Put),
        ?assertEqual(1, maps:get(<<"revision">>, First)),
        {ok, pending} = ae_store:begin_turn(Auth, <<"pinned">>, <<"s">>, <<"Recall my favorite color.">>),
        Context = ae_context:messages(<<"pinned">>, #{context_turns => 8}),
        ?assertNotEqual(nomatch, binary:match(jsx:encode(Context), <<"favorite-color">>)),
        {ok, Updated} = ae_store:memory({put, <<"preference-2">>, <<"preference">>, <<"favorite-color">>, <<"blue">>, [Seq], 1}),
        ?assertEqual(Context, ae_context:messages(<<"pinned">>, #{context_turns => 8})),
        ?assertEqual({ok, First}, ae_store:memory(Put)),
        ?assertEqual({error, memory_origin_conflict}, ae_store:memory(setelement(6, Put, [Seq + 1]))),
        Before = ae_store:last_seq(),
        ?assertEqual({error, memory_revision_conflict}, ae_store:memory({put, <<"stale">>, <<"fact">>, <<"topic">>, <<"changed">>, [Seq], 1})),
        ?assertEqual(Before, ae_store:last_seq()),
        gen_server:stop(ae_store), {ok, _} = ae_store:start_link(Root),
        ?assertEqual(Context, ae_context:messages(<<"pinned">>, #{context_turns => 8})),
        {ok, _} = ae_store:finish_turn(Auth, <<"pinned">>, <<"saffron">>),
        {ok, pending} = ae_store:begin_turn(Auth, <<"new-turn">>, <<"s">>, <<"Recall the updated preference.">>),
        #{<<"memory">> := #{<<"revision">> := 2, <<"entries">> := [Updated]}} = ae_store:context_snapshot(<<"new-turn">>, 8),
        {ok, _} = ae_store:memory({put, <<"summary-1">>, <<"summary">>, <<"context">>, <<"The user discussed favorite colors.">>, [Seq], 2}),
        {ok, CP} = ae_store:checkpoint(ae_store:routing()),
        ?assertEqual(3, maps:get(<<"memory_revision">>, CP)),
        ?assertEqual(<<"memory-summary:3">>, maps:get(<<"context_summary_ref">>, CP))
    end).

deletion_preserves_history_and_invalid_writes_do_not_change_events_test() ->
    with_store(fun(_, Auth) ->
        Sources = [1],
        Invalid = [
            {{put, <<"bad">>, <<"code">>, <<"k">>, <<"v">>, Sources, 0}, invalid_memory_key},
            {{put, <<"bad">>, <<"fact">>, <<"k">>, #{} , Sources, 0}, invalid_memory_value},
            {{put, <<"bad">>, <<"fact">>, <<"k">>, <<"v">>, [], 0}, invalid_memory_sources},
            {{put, <<"bad">>, <<"fact">>, <<"k">>, <<"v">>, [1,1], 0}, invalid_memory_sources},
            {{put, <<"bad">>, <<"fact">>, <<"k">>, <<"v">>, [999999], 0}, unknown_source_event},
            {{delete, <<"bad">>, <<"fact">>, <<"k">>, Sources, 0}, unknown_memory}],
        Before = ae_store:last_seq(),
        [begin ?assertEqual({error, Reason}, ae_store:memory(Operation)), ?assertEqual(Before, ae_store:last_seq()) end
            || {Operation, Reason} <- Invalid],
        {ok, First} = ae_store:memory({put, <<"put">>, <<"fact">>, <<"k">>, <<"v">>, Sources, 0}),
        {ok, pending} = ae_store:begin_turn(Auth, <<"pinned">>, <<"s">>, <<"Read it.">>),
        {ok, Deleted} = ae_store:memory({delete, <<"remove">>, <<"fact">>, <<"k">>, Sources, 1}),
        ?assert(maps:get(<<"deleted">>, Deleted)),
        ?assertMatch({ok, #{<<"entries">> := []}}, ae_store:memory({snapshot, null, 0, 32})),
        ?assertEqual({ok, First}, ae_store:memory({get, <<"fact">>, <<"k">>, 1})),
        ?assertEqual({ok, Deleted}, ae_store:memory({get, <<"fact">>, <<"k">>, null})),
        ?assertMatch(#{<<"memory">> := #{<<"entries">> := [First]}}, ae_store:context_snapshot(<<"pinned">>, 8)),
        ?assertEqual({error, invalid_memory_revision}, ae_store:memory({snapshot, 99, 0, 32})),
        ?assertEqual({error, invalid_memory_range}, ae_store:memory({snapshot, null, 0, 0}))
    end).

escaped_pages_are_bounded_and_do_not_skip_records_test() ->
    with_store(fun(_, _) ->
        [begin
            Key = integer_to_binary(N),
            {ok, _} = ae_store:memory({put, Key, <<"fact">>, Key, binary:copy(<<0>>, 1200), [1], N-1})
         end || N <- lists:seq(1, 40)],
        Records = pages(0, []),
        ?assertEqual(40, length(Records)),
        ?assertEqual(40, length(lists:usort([maps:get(<<"key">>, R) || R <- Records])))
    end).
pages(Offset, Acc) ->
    {ok, Page} = ae_store:memory({snapshot, 40, Offset, 32}),
    ?assert(byte_size(jsx:encode(Page)) < 34000),
    Entries = maps:get(<<"entries">>, Page),
    case maps:get(<<"eof">>, Page) of
        true -> Acc ++ Entries;
        false -> ?assert(length(Entries) > 0), pages(maps:get(<<"next_offset">>, Page), Acc ++ Entries)
    end.

with_store(Fun) ->
    Root = filename:join("/tmp", "ae-memory-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        {ok, _} = ae_store:start_link(Root),
        Seed = ae_store:boot(#{<<"digest">> => <<"g1">>}), {ok, _} = ae_store:activate(Seed, <<"instance">>),
        Fun(Root, {<<"adam">>, <<"instance">>, 1})
    after
        case whereis(ae_store) of undefined -> ok; Pid -> gen_server:stop(Pid) end,
        file:del_dir_r(Root)
    end.
