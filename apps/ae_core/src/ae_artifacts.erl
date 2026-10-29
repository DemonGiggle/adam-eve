-module(ae_artifacts).
-export([bootstrap/1, load/2, verify/2, verify_parent/3, executable/2]).

bootstrap(Root) ->
    {ok, Data} = file:read_file(filename:join(Root, "bootstrap.json")),
    jsx:decode(Data, [return_maps]).

load(Root, Digest) ->
    true = hex(Digest, 64),
    {ok, Data} = file:read_file(filename:join([Root, "artifacts", binary_to_list(Digest), "manifest.json"])),
    #{<<"digest">> := Digest} = Manifest = jsx:decode(Data, [return_maps]),
    ok = verify(Root, Manifest), Manifest.

verify(Root, #{<<"digest">> := Digest, <<"source_revision">> := Revision,
               <<"source_tree">> := Tree, <<"otp_release">> := Otp, <<"erts_version">> := Erts,
               <<"capabilities">> := Capabilities,
               <<"state_schema_versions">> := [1]} = Manifest) ->
    true = lists:member(Capabilities, [[<<"memory_read">>, <<"llm">>],
        [<<"memory_read">>, <<"llm">>, <<"source_list">>, <<"source_read">>,
         <<"evolution_status">>, <<"evolution_llm">>, <<"evolution_propose">>]]),
    true = hex(Digest, 64),
    true = hex(Revision, 40),
    true = hex(Tree, 40),
    true = Otp =:= list_to_binary(erlang:system_info(otp_release)),
    true = Erts =:= list_to_binary(erlang:system_info(version)),
    {ok, Encoded} = file:read_file(filename:join(filename:dirname(executable(Root, Manifest)), "manifest.json")),
    Manifest = jsx:decode(Encoded, [return_maps]),
    {ok, Bytes} = file:read_file(executable(Root, Manifest)),
    Digest = list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) ||
                                         <<B>> <= crypto:hash(sha256, Bytes)])),
    Git = os:find_executable("git"),
    Repo = filename:join(Root, "source.git"),
    {ok, Revision} = ae_os:run(Git, ["--git-dir", Repo, "rev-parse", "--verify",
        "refs/generations/" ++ binary_to_list(Digest)], 5000),
    {ok, Tree} = ae_os:run(Git, ["--git-dir", Repo, "rev-parse", "--verify",
        binary_to_list(Revision) ++ "^{tree}"], 5000),
    {ok, _} = ae_os:run(Git, ["--git-dir", Repo, "fsck", "--strict", "--no-reflogs",
        binary_to_list(Revision)], 10000),
    ok.

verify_parent(Root, #{<<"parent">> := Parent, <<"source_revision">> := Revision},
              #{<<"digest">> := Parent, <<"source_revision">> := ParentRevision}) ->
    {ok, ParentRevision} = ae_os:run(os:find_executable("git"),
        ["--git-dir", filename:join(Root, "source.git"), "rev-parse", "--verify",
         binary_to_list(Revision) ++ "^"], 5000), ok.

executable(Root, #{<<"digest">> := Digest}) ->
    true = hex(Digest, 64),
    filename:join([Root, "artifacts", binary_to_list(Digest), "seed"]).

hex(Value, Length) ->
    is_binary(Value) andalso byte_size(Value) =:= Length andalso
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end,
              binary_to_list(Value)).
