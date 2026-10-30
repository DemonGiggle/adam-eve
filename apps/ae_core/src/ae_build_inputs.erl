-module(ae_build_inputs).
-include_lib("kernel/include/file.hrl").
-export([extract/2, package_hash/0]).

%% The protected seed lock fixes this exact Hex package. Extract its source
%% without invoking package-provided hooks or following archive links.
package_hash() -> <<"0c5cc8fdc11b53cc25cf65ac6705ad39e54ecc56d1c22e4adb8f5a53fb9427f3">>.

extract(Package, Destination) ->
    try
        {ok, Info} = file:read_file_info(Package),
        true = Info#file_info.type =:= regular andalso Info#file_info.size =< 4 * 1024 * 1024,
        {ok, Archive} = file:read_file(Package),
        true = byte_size(Archive) =< 4 * 1024 * 1024,
        true = ae_policy:sha256(Archive) =:= package_hash(),
        {ok, OuterEntries} = erl_tar:table({binary, Archive}, [verbose]),
        ["CHECKSUM", "VERSION", "contents.tar.gz", "metadata.config"] =
            lists:sort([Name || {Name, regular, _, _, _, _, _} <- OuterEntries]),
        4 = length(OuterEntries),
        {ok, Outer} = erl_tar:extract({binary, Archive}, [memory]),
        {"contents.tar.gz", Compressed} = lists:keyfind("contents.tar.gz", 1, Outer),
        {ok, Entries} = erl_tar:table({binary, Compressed}, [compressed, verbose]),
        true = Entries =/= [],
        true = lists:all(fun({Name, Type, Size, _, _, _, _}) ->
            Type =:= regular andalso safe_name(Name) andalso is_integer(Size) andalso Size >= 0
        end, Entries),
        Names = [Name || {Name, _, _, _, _, _, _} <- Entries],
        true = length(Names) =:= length(lists:usort(Names)),
        true = lists:sum([Size || {_, _, Size, _, _, _, _} <- Entries]) =< 16 * 1024 * 1024,
        {ok, Contents} = erl_tar:extract({binary, Compressed}, [compressed, memory]),
        true = lists:sort([Name || {Name, _} <- Contents]) =:= lists:sort(Names),
        ok = file:make_dir(Destination),
        ok = file:change_mode(Destination, 8#700),
        lists:foreach(fun({Name, Data}) ->
            Target = filename:join(Destination, Name),
            ok = filelib:ensure_dir(Target),
            ok = file:write_file(Target, Data, [exclusive])
        end, Contents),
        {ok, #{<<"name">> => <<"jsx">>, <<"version">> => <<"3.1.0">>, <<"package_sha256">> => package_hash()}}
    catch _:_ -> {error, invalid_build_dependency} end.

safe_name(Name) when is_list(Name), Name =/= [] ->
    filename:pathtype(Name) =:= relative andalso
        lists:all(fun(Part) -> Part =/= "" andalso Part =/= "." andalso Part =/= ".." end,
            string:split(Name, "/", all));
safe_name(_) -> false.
