-module(ae_build_inputs_tests).
-include_lib("eunit/include/eunit.hrl").

pinned_package_extracts_verified_source_test() ->
    Root = filename:join("/tmp", "ae-erlang-build-inputs-" ++ integer_to_list(erlang:unique_integer([positive]))),
    ok = file:make_dir(Root),
    Package = case os:getenv("AE_JSX_PACKAGE") of
        false -> filename:join([os:getenv("HOME"), ".cache", "rebar3", "hex", "hexpm", "packages", "jsx-3.1.0.tar"]);
        Path -> Path end,
    try
        Destination = filename:join(Root, "source"),
        {ok, #{<<"package_sha256">> := Hash}} = ae_build_inputs:extract(Package, Destination),
        ?assertEqual(ae_build_inputs:package_hash(), Hash),
        ?assert(filelib:is_regular(filename:join([Destination, "src", "jsx.erl"]))),
        ?assert(filelib:is_regular(filename:join(Destination, "LICENSE"))),
        {ok, Original} = file:read_file(Package),
        <<First, Rest/binary>> = Original,
        Bad = filename:join(Root, "modified.tar"),
        ok = file:write_file(Bad, <<(First bxor 1), Rest/binary>>),
        Rejected = filename:join(Root, "rejected"),
        ?assertEqual({error, invalid_build_dependency}, ae_build_inputs:extract(Bad, Rejected)),
        ?assertNot(filelib:is_dir(Rejected))
    after file:del_dir_r(Root) end.
