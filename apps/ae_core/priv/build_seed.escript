#!/usr/bin/env escript
%%! +S 2:2 +A 1 +SDcpu 1:1 +SDio 1 +MIscs 32
-mode(compile).
-include_lib("kernel/include/file.hrl").

%% Trusted fixed recipe. Generated source/compiler hooks must execute this
%% program ONLY through ae_sandbox, with source/dependencies mounted read-only.
main([Source, Dependency, Revision, Tree, Parent, DependencyHash, RecipeHash, Output]) ->
    true = hex(Revision, 40) andalso hex(Tree, 40) andalso hex(DependencyHash, 64) andalso hex(RecipeHash, 64),
    true = Parent =:= "-" orelse hex(Parent, 64),
    {ok, Original} = file:get_cwd(),
    ok = file:set_cwd(Source),
    validate_config(),
    Seed = app_files(ae_seed, "apps/ae_seed"),
    Protocol = app_files(ae_protocol, "apps/ae_protocol"),
    ok = file:set_cwd(Dependency),
    Jsx = app_files(jsx, "."),
    {ok, License} = file:read_file("LICENSE"),
    ok = file:set_cwd(Original),
    Files = Seed ++ Protocol ++ Jsx ++ [entry("jsx/LICENSE", License)],
    Names = [Name || {Name, _, _} <- Files],
    true = length(Names) =:= length(lists:usort(Names)),
    Modules = [filename:basename(Name) || Name <- Names, filename:extension(Name) =:= ".beam"],
    true = length(Modules) =:= length(lists:usort(Modules)),
    application:load(compiler),
    {ok, Compiler} = application:get_key(compiler, vsn),
    Metadata = [{recipe, "ae_seed_v1"}, {source_revision, Revision}, {source_tree, Tree},
        {parent_artifact, Parent}, {dependency_sha256, DependencyHash}, {recipe_sha256, RecipeHash},
        {otp_release, erlang:system_info(otp_release)}, {erts_version, erlang:system_info(version)},
        {compiler_version, Compiler}, {architecture, erlang:system_info(system_architecture)}],
    All = lists:keysort(1, [entry("ae_seed/provenance/build.term", iolist_to_binary(io_lib:format("~tp.~n", [Metadata]))) | Files]),
    {ok, Executable} = escript:create(binary, [shebang, {comment, "adam-eve fixed seed recipe v1"},
        {emu_args, "+S 2:2 +A 1"}, {archive, All, [{compress, []}]}]),
    case Output of
        "-" -> io:put_chars(["AE_SEED_V1\n", base64:encode(Executable), "\n"]);
        _ -> ok = filelib:ensure_dir(Output), ok = file:write_file(Output, Executable)
    end;
main(_) -> halt(64).

validate_config() ->
    {ok, Config} = file:consult("apps/ae_seed/rebar.config"),
    Expected = [{erl_opts, [debug_info, warnings_as_errors]},
        {project_app_dirs, [".", "../ae_protocol"]}, {deps, [{jsx, "3.1.0"}]},
        {escript_name, seed}, {escript_main_app, ae_seed}, {escript_incl_apps, [ae_protocol, jsx]},
        {escript_emu_args, "%%! +S 2:2 +A 1\n"}],
    true = lists:sort(Config) =:= lists:sort(Expected),
    {ok, [{"1.2.0", [{<<"jsx">>, {pkg, <<"jsx">>, <<"3.1.0">>}, 0}]}, Hashes]} =
        file:consult("apps/ae_seed/rebar.lock"),
    {pkg_hash, [{<<"jsx">>, <<"D12516BAA0BB23A59BB35DCCAF02A1BD08243FCBB9EFE24F2D9D056CCFF71268">>}]} =
        lists:keyfind(pkg_hash, 1, Hashes),
    {pkg_hash_ext, [{<<"jsx">>, <<"0C5CC8FDC11B53CC25CF65AC6705AD39E54ECC56D1C22E4ADB8F5A53FB9427F3">>}]} =
        lists:keyfind(pkg_hash_ext, 1, Hashes),
    true = length(Hashes) =:= 2.

app_files(App, Directory) ->
    Source = filename:join(Directory, "src"),
    Paths = source_files(Source),
    true = Paths =/= [],
    Compiled = [compile_source(Path, Source, filename:join(Directory, "include")) || Path <- Paths],
    Modules = [Module || {Module, _} <- Compiled],
    AppString = atom_to_list(App),
    AppSrc = filename:join(Source, AppString ++ ".app.src"),
    {ok, [{application, App, Properties}]} = file:consult(AppSrc),
    New = {application, App, lists:keystore(modules, 1, Properties, {modules, lists:sort(Modules)})},
    [entry(AppString ++ "/ebin/" ++ atom_to_list(Module) ++ ".beam", Beam) || {Module, Beam} <- Compiled] ++
        [entry(AppString ++ "/ebin/" ++ AppString ++ ".app", iolist_to_binary(io_lib:format("~tp.~n", [New])))].

source_files(Directory) ->
    {ok, Names} = file:list_dir(Directory),
    lists:sort(lists:flatmap(fun(Name) ->
        Path = filename:join(Directory, Name),
        {ok, Info} = file:read_link_info(Path),
        case Info#file_info.type of
            directory -> source_files(Path);
            regular -> case filename:extension(Path) of ".erl" -> [Path]; _ -> [] end;
            _ -> error({unsupported_source_file, Path})
        end
    end, Names)).
compile_source(Path, Source, Include) ->
    Options = [binary, deterministic, debug_info, warnings_as_errors, return_errors, return_warnings,
               {i, Source}, {i, Include}],
    case compile:file(Path, Options) of
        {ok, Module, Beam, []} ->
            true = filename:basename(Path, ".erl") =:= atom_to_list(Module), {Module, Beam};
        Error -> error({compile_failed, Path, Error})
    end.
entry(Name, Bytes) ->
    Date = {{1980, 1, 1}, {0, 0, 0}},
    Info = #file_info{size = byte_size(Bytes), type = regular, access = read, atime = Date,
        mtime = Date, ctime = Date, mode = 8#100444, links = 1, major_device = 0,
        minor_device = 0, inode = 0, uid = 0, gid = 0},
    {Name, Bytes, Info}.
hex(Value, Length) -> length(Value) =:= Length andalso
    lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, Value).
