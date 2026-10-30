-module(ae_host_source).
-export([scan/3, export/4]).

%% Read exact retained Git blobs rather than checkout/archive output, so Git
%% attributes cannot change the contents sent to the fixed compiler recipe.
scan(Root, Revision, Config) ->
    try
        true = hex(Revision, 40),
        MaxFiles = maps:get(<<"source_files">>, Config),
        MaxBytes = maps:get(<<"source_bytes">>, Config),
        true = is_integer(MaxFiles) andalso MaxFiles > 0,
        true = is_integer(MaxBytes) andalso MaxBytes > 0,
        ListingLimit = MaxFiles * 512 + 1024,
        {ok, Listing} = git(Root, ["ls-tree", "-r", "-l", "-z", binary_to_list(Revision)], ListingLimit),
        Records = binary:split(Listing, <<0>>, [global]),
        <<>> = lists:last(Records),
        Entries = [entry(Record) || Record <- lists:droplast(Records)],
        true = Entries =/= [] andalso length(Entries) =< MaxFiles,
        true = lists:sum([Size || {_, _, Size} <- Entries]) =< MaxBytes,
        Names = [Name || {Name, _, _} <- Entries],
        true = length(Names) =:= length(lists:usort(Names)),
        {ok, Entries}
    catch _:_ -> {error, invalid_source_tree} end.

export(Root, Revision, Destination, Config) ->
    case scan(Root, Revision, Config) of
        {error, _} = Error -> Error;
        {ok, Entries} ->
            try
                ok = file:make_dir(Destination),
                ok = file:change_mode(Destination, 8#700),
                lists:foreach(fun({Path, Blob, Size}) ->
                    case prefix(Path, <<"apps/ae_protocol/test/">>) of
                        true -> ok;
                        false ->
                            {ok, Data} = git(Root, ["cat-file", "blob", binary_to_list(Blob)], max(1, Size)),
                            true = byte_size(Data) =:= Size,
                            Target = filename:join(Destination, binary_to_list(Path)),
                            ok = filelib:ensure_dir(Target),
                            ok = file:write_file(Target, Data, [exclusive])
                    end
                end, Entries),
                ok
            catch _:_ -> {error, source_export_failed} end
    end.

git(Root, Args, Limit) ->
    ae_git_stream:fold(Root, Args, fun(Chunk, Acc) ->
        true = byte_size(Acc) + byte_size(Chunk) =< Limit,
        {continue, <<Acc/binary, Chunk/binary>>}
    end, <<>>).

entry(Record) ->
    [Info, Path] = binary:split(Record, <<"\t">>),
    [Mode, <<"blob">>, Blob, EncodedSize] = string:lexemes(Info, " "),
    true = Mode =:= <<"100644">> orelse Mode =:= <<"100755">>,
    true = hex(Blob, 40),
    true = ae_patch:canonical(Path),
    true = ae_patch:readable(Path) orelse Path =:= <<".gitignore">> orelse protocol_test(Path),
    Size = binary_to_integer(EncodedSize),
    true = Size >= 0,
    {Path, Blob, Size}.

protocol_test(Path) ->
    prefix(Path, <<"apps/ae_protocol/test/">>) andalso
        lists:member(filename:extension(Path), [<<".erl">>, <<".hrl">>]).
prefix(Path, Prefix) -> binary:longest_common_prefix([Path, Prefix]) =:= byte_size(Prefix).
hex(V, Length) -> is_binary(V) andalso byte_size(V) =:= Length andalso
    re:run(V, <<"^[0-9a-f]+$">>, [{capture, none}]) =:= match.
