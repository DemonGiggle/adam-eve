-module(ae_sandbox).
-export([runtime/4]).

runtime(Root, Manifest, Directory, #{token := Token, config := Config}) ->
    case maps:get(runtime_isolation, Config, development) of
        development ->
            %% Retained for the explicitly trusted manual development seed only.
            case maps:get(<<"authoring">>, Manifest, <<"trusted_manual">>) of
                <<"trusted_manual">> ->
                    {os:find_executable("escript"), [ae_artifacts:executable(Root, Manifest), Directory ++ "/ipc", binary_to_list(Token)]};
                _ -> error(sandbox_required)
            end;
        bubblewrap ->
            #{sandbox_cgroup_root := CgroupRoot, sandbox_limits := Limits} = Config,
            Helper = filename:join(code:priv_dir(ae_core), "ae_sandbox.py"),
            Budget = case maps:find(runtime_cpu_budget_ms, Config) of
                {ok, Cpu} -> ["--cpu-budget-ms", integer_to_list(Cpu)]; error -> [] end,
            Deadline = case maps:find(runtime_deadline, Config) of
                {ok, At} -> ["--deadline-ms", integer_to_list(At)]; error -> [] end,
            {"/usr/bin/python3", [Helper, "--cgroup-root", CgroupRoot,
                "--limits-json", binary_to_list(jsx:encode(Limits)),
                "--runtime", ae_artifacts:executable(Root, Manifest),
                "--digest", binary_to_list(maps:get(<<"digest">>, Manifest)),
                "--ipc-dir", Directory, "--token", binary_to_list(Token)] ++ Budget ++ Deadline}
    end.
