#!/usr/bin/env escript
%%! +S 2:2 +A 1 +SDcpu 1:1 +SDio 1 +MIscs 32
-mode(compile).

%% This supplementary suite never receives the private judge cases. The
%% three-path form runs tests on the host with the controller user's privileges.
main([Minimum]) -> run(Minimum, "/work", "/agent/seed", "/source");
main([Minimum, Work, Seed, Source]) -> run(Minimum, Work, Seed, Source);
main(_) -> halt(64).

run(Minimum, Work, Seed, Source) ->
    try
        ok = file:set_cwd(Work),
        {ok, Sections} = escript:extract(Seed, []),
        {archive, Archive} = lists:keyfind(archive, 1, Sections),
        {ok, Files} = zip:extract(Archive, [memory]),
        lists:foreach(fun({Name, Bytes}) ->
            Parts = filename:split(Name),
            case Parts of
                [App, "ebin", File] ->
                    true = lists:member(App, ["ae_seed", "ae_protocol", "jsx"]),
                    true = lists:member(filename:extension(File), [".beam", ".app"]),
                    Target = filename:join([Work, App, "ebin", File]),
                    ok = filelib:ensure_dir(Target), ok = file:write_file(Target, Bytes);
                _ -> ok
            end
        end, Files),
        true = code:add_paths([filename:join([Work, App, "ebin"]) || App <- ["ae_seed", "ae_protocol", "jsx"]]) =:= ok,
        Tests = filename:join(Work, "tests"), ok = file:make_dir(Tests),
        Paths = filelib:wildcard(filename:join(Source, "apps/ae_seed/test/**/*.erl")) ++
            filelib:wildcard(filename:join(Source, "apps/ae_seed/test/*.erl")),
        Modules = lists:usort([begin
            {ok, Module} = compile:file(Path, [{outdir, Tests}, warnings_as_errors,
                {i, filename:join(Source, "apps/ae_seed/src")}, {i, filename:join(Source, "apps/ae_seed/include")},
                {i, filename:join(Source, "apps/ae_seed/test")}, return_errors]), Module
        end || Path <- lists:usort(Paths)]),
        true = length(Modules) >= list_to_integer(Minimum),
        true = code:add_patha(Tests),
        {Suites, Units} = lists:partition(fun(M) -> lists:suffix("_SUITE", atom_to_list(M)) end, Modules),
        ok = eunit:test(Units, [verbose]),
        case Suites of
            [] -> ok;
            _ ->
                CT = filename:join(Work, "ct"), ok = file:make_dir(CT),
                {_, 0, {0, 0}} = ct:run_test([{dir, Tests}, {suite, Suites},
                    {auto_compile, false}, {basic_html, true}, {logdir, CT}])
        end,
        io:format("AE_TESTS_V1 ~B~n", [length(Modules)])
    catch Class:Reason -> io:format("AE_TESTS_FAILED ~P ~P~n", [Class, 3, Reason, 12]), halt(1) end.
