-module(ae_source).
-export([list/5, read/6]).

list(Root, Auth, JobId, Offset, Count)
        when is_integer(Offset), Offset >= 0, is_integer(Count), Count > 0, Count =< 32 ->
    access(Root, Auth, JobId, fun(Job, Revision, Budget) ->
        Initial = #{buffer => <<>>, skip => Offset, entries => [], bytes => 0, eof => true},
        Step = fun(Chunk, State) -> tree_records(<< (maps:get(buffer, State))/binary, Chunk/binary >>,
            State#{buffer := <<>>}, Count, Budget - 512) end,
        Args = ["ls-tree", "-r", "-l", "-z", binary_to_list(Revision), "--", "apps/ae_seed/src",
                "apps/ae_seed/test", "apps/ae_seed/rebar.config", "apps/ae_seed/rebar.lock",
                "apps/ae_protocol/src/ae_protocol.erl", "apps/ae_protocol/src/ae_protocol.app.src", "docs/PROTOCOL.md"],
        {ok, Result} = ae_git_stream:fold(Root, Args, Step, Initial),
        <<>> = maps:get(buffer, Result),
        Entries = lists:reverse(maps:get(entries, Result)),
        (envelope(Job))#{<<"entries">> => Entries, <<"offset">> => Offset,
            <<"next_offset">> => Offset + length(Entries), <<"eof">> => maps:get(eof, Result)}
    end);
list(_, _, _, _, _) -> {error, invalid_source_range}.

read(Root, Auth, JobId, Path, Offset, Bytes)
        when is_integer(Offset), Offset >= 0, is_integer(Bytes), Bytes > 0 ->
    case ae_patch:readable(Path) of
        false -> ae_store:evolution({source_violation, Auth, JobId});
        true -> access(Root, Auth, JobId, fun(Job, Revision, Budget) ->
            true = Bytes =< ((Budget - 512) * 3 div 4),
            Initial = #{buffer => <<>>, skip => 0, entries => [], bytes => 0, eof => true},
            Step = fun(Chunk, State) -> tree_records(<<(maps:get(buffer, State))/binary, Chunk/binary>>,
                State#{buffer := <<>>}, 1, 512) end,
            {ok, Meta} = ae_git_stream:fold(Root,
                ["ls-tree", "-l", "-z", binary_to_list(Revision), "--", binary_to_list(Path)], Step, Initial),
            [#{<<"path">> := Path, <<"blob_id">> := Blob, <<"size">> := Size}] = maps:get(entries, Meta),
            true = Offset =< Size,
            {ok, {_, Read, _}} = ae_git_stream:fold(Root, ["cat-file", "blob", binary_to_list(Blob)],
                fun range/2, {Offset, <<>>, min(Bytes, Size - Offset)}),
            (envelope(Job))#{<<"path">> => Path, <<"offset">> => Offset,
                <<"data_base64">> => base64:encode(Read), <<"next_offset">> => Offset + byte_size(Read),
                <<"eof">> => Offset + byte_size(Read) =:= Size}
        end)
    end;
read(_, _, _, _, _, _) -> {error, invalid_source_range}.

access(Root, Auth, Id, Fun) ->
    case ae_store:evolution({source_reserve, Auth, Id}) of
        {ok, Job} ->
            try
                Artifact = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
                Revision = maps:get(<<"source_revision">>, Artifact), Digest = maps:get(<<"digest">>, Artifact),
                true = hex(Revision, 40) andalso hex(Digest, 64),
                {ok, Ref} = ae_git_stream:fold(Root,
                    ["rev-parse", "--verify", "refs/generations/" ++ binary_to_list(Digest)],
                    fun(Chunk, Acc) -> true = byte_size(Acc) + byte_size(Chunk) =< 256,
                        {continue, <<Acc/binary, Chunk/binary>>} end, <<>>),
                Revision = string:trim(Ref),
                Budget = maps:get(<<"source_page_bytes">>, maps:get(<<"limits">>, Job)),
                Reply = Fun(Job, Revision, Budget),
                true = byte_size(jsx:encode(Reply)) =< Budget,
                case ae_store:evolution({authorize, Auth, Id}) of {ok, _} -> {ok, Reply}; Error -> Error end
            catch _:_ -> {error, source_unavailable} end;
        Error -> Error
    end.

tree_records(Data, State, Count, MaxBytes) ->
    case binary:split(Data, <<0>>) of
        [Fragment] ->
            true = byte_size(Fragment) =< 4096,
            {continue, State#{buffer := Fragment}};
        [Record, Rest] ->
            case entry(Record) of
                skip -> tree_records(Rest, State, Count, MaxBytes);
                Entry ->
                    Skip = maps:get(skip, State), Entries = maps:get(entries, State),
                    Bytes = byte_size(jsx:encode(Entry)) + 1,
                    case Skip > 0 of
                        true -> tree_records(Rest, State#{skip := Skip - 1}, Count, MaxBytes);
                        false -> case length(Entries) >= Count orelse maps:get(bytes, State) + Bytes > MaxBytes of
                            true -> true = Entries =/= [], {halt, State#{buffer := <<>>, eof := false}};
                            false -> tree_records(Rest, State#{entries := [Entry | Entries],
                                bytes := maps:get(bytes, State) + Bytes}, Count, MaxBytes)
                        end
                    end
            end
    end.
entry(Record) ->
    [Info, Path] = binary:split(Record, <<"\t">>),
    case {string:lexemes(Info, " "), ae_patch:readable(Path)} of
        {[Mode, <<"blob">>, Blob, Size], true} when Mode =:= <<"100644">>; Mode =:= <<"100755">> ->
            true = hex(Blob, 40),
            #{<<"path">> => Path, <<"blob_id">> => Blob, <<"size">> => binary_to_integer(Size),
              <<"writable">> => ae_patch:writable(Path)};
        _ -> skip
    end.
range(Chunk, {Skip, Acc, Remaining}) ->
    case byte_size(Chunk) =< Skip of
        true -> {continue, {Skip - byte_size(Chunk), Acc, Remaining}};
        false ->
            Take = min(byte_size(Chunk) - Skip, Remaining),
            Part = binary:part(Chunk, Skip, Take),
            Next = {0, <<Acc/binary, Part/binary>>, Remaining - Take},
            case Remaining =:= Take of true -> {halt, Next}; false -> {continue, Next} end
    end.
envelope(Job) ->
    Artifact = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
    #{<<"job_id">> => maps:get(<<"id">>, Job), <<"base_artifact">> => maps:get(<<"digest">>, Artifact),
      <<"base_source_revision">> => maps:get(<<"source_revision">>, Artifact)}.
hex(V, Length) -> is_binary(V) andalso byte_size(V) =:= Length andalso
    re:run(V, <<"^[0-9a-f]+$">>, [{capture, none}]) =:= match.
