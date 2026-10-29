#!/usr/bin/env escript
%%! +S 2:2 +A 1 +SDcpu 1:1 +SDio 1 +MIscs 32
-mode(compile).

%% Candidate archives, compiler hooks and tests are decoded/executed ONLY in
%% the sandbox. This supplementary suite never receives the private judge cases.
main([Minimum]) ->
    try
        ok = file:set_cwd("/work"),
        {ok, Sections} = escript:extract("/agent/seed", []),
        {archive, Archive} = lists:keyfind(archive, 1, Sections),
        {ok, Files} = zip:extract(Archive, [memory]),
        lists:foreach(fun({Name, Bytes}) ->
            Parts = filename:split(Name),
            case Parts of
                [App, "ebin", File] ->
                    true = lists:member(App, ["ae_seed", "ae_protocol", "jsx"]),
                    true = lists:member(filename:extension(File), [".beam", ".app"]),
                    Target = filename:join(["/work", App, "ebin", File]),
                    ok = filelib:ensure_dir(Target), ok = file:write_file(Target, Bytes);
                _ -> ok
            end
        end, Files),
        true = code:add_paths(["/work/ae_seed/ebin", "/work/ae_protocol/ebin", "/work/jsx/ebin"]) =:= ok,
        ok = file:make_dir("/work/tests"),
        Paths = filelib:wildcard("/source/apps/ae_seed/test/**/*.erl") ++
            filelib:wildcard("/source/apps/ae_seed/test/*.erl"),
        Modules = lists:usort([begin
            {ok, Module} = compile:file(Path, [{outdir, "/work/tests"}, warnings_as_errors,
                {i, "/source/apps/ae_seed/src"}, {i, "/source/apps/ae_seed/include"},
                {i, "/source/apps/ae_seed/test"}, return_errors]), Module
        end || Path <- lists:usort(Paths)]),
        true = length(Modules) >= list_to_integer(Minimum),
        true = code:add_patha("/work/tests"),
        {Suites, Units} = lists:partition(fun(M) -> lists:suffix("_SUITE", atom_to_list(M)) end, Modules),
        ok = eunit:test(Units, [verbose]),
        case Suites of
            [] -> ok;
            _ ->
                ok = file:make_dir("/work/ct"),
                {_, 0, {0, 0}} = ct:run_test([{dir, "/work/tests"}, {suite, Suites},
                    {auto_compile, false}, {basic_html, true}, {logdir, "/work/ct"}])
        end,
        io:format("AE_TESTS_V1 ~B~n", [length(Modules)])
    catch Class:Reason -> io:format("AE_TESTS_FAILED ~P ~P~n", [Class, 3, Reason, 12]), halt(1) end;
main(_) -> halt(64).
