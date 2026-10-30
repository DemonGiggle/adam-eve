-module(ae_credentials).
-include_lib("kernel/include/file.hrl").
-export([resolve/2, read/1]).

%% Credential references are controller configuration. Their contents never
%% enter session settings, audit records, runtime environments or IPC messages.
resolve(Env, Path) when Path =/= <<>>, Env =/= <<>> -> {error, conflicting_credentials};
resolve(_, Path) when Path =/= <<>> ->
    case read(Path) of {ok, Value} -> validate(Value); Error -> Error end;
resolve(<<>>, <<>>) -> {ok, <<>>};
resolve(Env, <<>>) ->
    case os:getenv(binary_to_list(Env)) of
        false -> {error, credential_missing};
        Value -> validate(unicode:characters_to_binary(Value))
    end.

read(Path) ->
    try
        absolute = filename:pathtype(Path),
        ok = no_links(Path),
        {ok, Before} = file:read_link_info(Path),
        {ok, File} = file:open(Path, [raw, binary, read]),
        try
            {ok, Info} = file:read_file_info(File),
            true = Info#file_info.type =:= regular,
            true = Info#file_info.inode =:= Before#file_info.inode,
            true = Info#file_info.major_device =:= Before#file_info.major_device,
            true = lists:member(Info#file_info.mode band 8#777, [8#600, 8#400]),
            {ok, Own} = file:read_file_info(<<"/proc/self">>),
            true = Info#file_info.uid =:= Own#file_info.uid,
            true = Info#file_info.links =:= 1 andalso Info#file_info.size =< 65536,
            {ok, Data} = file:read(File, 65537),
            true = byte_size(Data) =< 65536,
            {ok, After} = file:read_link_info(Path),
            true = After#file_info.type =:= regular andalso After#file_info.inode =:= Info#file_info.inode,
            {ok, string:trim(Data)}
        after file:close(File) end
    catch _:_ -> {error, credential_file_invalid} end.

no_links(Path) ->
    {ok, Info} = file:read_link_info(Path),
    true = Info#file_info.type =/= symlink,
    case filename:dirname(Path) of Path -> ok; Parent -> no_links(Parent) end.
validate(Value) when is_binary(Value), byte_size(Value) > 0, byte_size(Value) =< 8192 ->
    case binary:match(Value, [<<"\r">>, <<"\n">>, <<0>>]) of nomatch -> {ok, Value}; _ -> {error, credential_invalid} end;
validate(_) -> {error, credential_invalid}.
