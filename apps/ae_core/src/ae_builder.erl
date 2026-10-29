-module(ae_builder).
-behaviour(gen_server).
-export([start_link/3, validate_config/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Id, Config, Notify) -> gen_server:start_link(?MODULE, {Id, Config, Notify}, []).
init({Id, Config, Notify}) ->
    self() ! start,
    {ok, #{id => Id, config => Config, notify => Notify, parent => monitor(process, Notify),
           lease => undefined, job => undefined, directory => undefined, port => undefined, timer => undefined, output => <<>>}}.
handle_call(_, _, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.
handle_info(start, State) ->
    try prepare(State) of
        {ok, Next} -> {noreply, Next};
        {error, Reason, Next} -> failed(Reason, <<>>, Next)
    catch _:_ -> failed(<<"builder_start_failed">>, <<>>, State) end;
handle_info({Port, {data, Data}}, #{port := Port, output := Acc} = State) ->
    case byte_size(Acc) + byte_size(Data) =< 1048576 of
        true -> {noreply, State#{output := <<Acc/binary, Data/binary>>}};
        false -> failed(<<"builder_output_limit">>, <<>>, State)
    end;
handle_info({Port, {exit_status, Code}}, #{port := Port, output := Output} = State) ->
    try jsx:decode(Output, [return_maps, strict]) of
        #{<<"ok">> := true, <<"manifest">> := Manifest} when Code =:= 0 ->
            #{config := #{root := Root}, id := Id, job := Job, lease := Lease} = State,
            ok = ae_artifacts:verify(Root, Manifest),
            Result = ae_store:evolution({finish_build, Id, maps:get(<<"attempts">>, Job), maps:get(<<"id">>, Lease), Manifest}),
            case Result of {ok, _} -> notify(Result, State); {error, Why} -> failed(reason(Why), <<>>, State) end;
        #{<<"ok">> := false, <<"error">> := Reason, <<"diagnostics">> := Diagnostics}
                when is_binary(Reason), byte_size(Reason) > 0, byte_size(Reason) =< 256, is_binary(Diagnostics) ->
            failed(Reason, Diagnostics, State);
        _ -> failed(<<"invalid_builder_result">>, <<>>, State)
    catch _:_ -> failed(<<"invalid_builder_result">>, <<>>, State) end;
handle_info(build_timeout, State) -> failed(<<"build_timeout">>, <<>>, State);
handle_info({'DOWN', Ref, process, _, _}, #{parent := Ref} = State) ->
    failed(<<"build_owner_lost">>, <<>>, State);
handle_info(_, State) -> {noreply, State}.

terminate(_, State) ->
    case maps:get(timer, State) of undefined -> ok; Timer -> erlang:cancel_timer(Timer) end,
    case maps:get(port, State) of undefined -> ok; Port -> catch port_close(Port) end,
    case maps:get(directory, State) of undefined -> ok; Directory -> file:del_dir_r(Directory) end, ok.

prepare(#{config := Config, id := Id} = State) ->
    Builder = maps:get(candidate_builder, Config, undefined),
    case validate_config(Builder) of
        {error, _} -> {error, <<"build_not_configured">>, State};
        {ok, Builder} ->
            Job = ae_store:evolution({get, Id}),
            case Job of
                #{<<"status">> := <<"building">>, <<"attempts">> := Attempt, <<"limits">> := Limits} ->
                    ok = ae_artifacts:verify(maps:get(root, Config), maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job))),
                    Sandbox = maps:get(<<"sandbox_limits">>, Builder),
                    Cpu = max(1, min(maps:get(<<"cpu_seconds">>, Sandbox) * 1000,
                        maps:get(<<"cpu_ms">>, Limits) - maps:get(<<"reserved_cpu_ms">>, Job, 0))),
                    Remaining = maps:get(<<"deadline">>, Job) - erlang:system_time(millisecond),
                    Wall = min(min(maps:get(<<"wall_ms">>, Sandbox), maps:get(<<"build_ms">>, Limits)), max(1, Remaining div 2)),
                    case ae_store:evolution({reserve_execution, Id, Attempt, <<"build">>, Cpu, Wall}) of
                        {ok, Lease} when is_map(Lease) ->
                            Reserved = State#{job := Job, lease := Lease},
                            try launch(Builder, Reserved)
                            catch _:_ -> {error, <<"builder_launch_failed">>, Reserved} end;
                        {error, Reason} -> {error, reason(Reason), State}
                    end;
                _ -> {error, <<"invalid_job_state">>, State}
            end
    end.

launch(Builder, #{config := #{root := Root}, id := Id, job := Job, lease := Lease} = State) ->
    Directory = filename:join([Root, "workspaces", "builder-" ++ binary_to_list(maps:get(<<"id">>, Lease))]),
    ok = file:make_dir(Directory), ok = file:change_mode(Directory, 8#700),
    Next = State#{directory := Directory},
    try
        Attempt = maps:get(<<"attempts">>, Job),
        Proposal = ae_store:evolution({attempt, Id, Attempt}),
        Request = filename:join(Directory, "request.json"), Config = filename:join(Directory, "config.json"),
        ok = file:write_file(Request, jsx:encode(#{<<"job">> => Job, <<"proposal">> => Proposal, <<"lease">> => Lease}), [exclusive]),
        ok = file:change_mode(Request, 8#600),
        ok = file:write_file(Config, jsx:encode(Builder), [exclusive]), ok = file:change_mode(Config, 8#600),
        Helper = filename:join(code:priv_dir(ae_core), "ae_candidate.py"),
        Port = open_port({spawn_executable, "/usr/bin/python3"}, [binary, exit_status, use_stdio,
            {env, ae_os:clean_env()}, {args, [Helper, "--data-root", Root, "--request", Request, "--config", Config, "--watch-parent"]}]),
        Timer = erlang:send_after(maps:get(<<"wall_ms">>, Lease), self(), build_timeout),
        {ok, Next#{port := Port, timer := Timer}}
    catch _:_ -> {error, <<"builder_launch_failed">>, Next} end.

failed(Reason, _Diagnostics, #{lease := undefined} = State) -> notify({error, Reason}, State);
failed(Reason, Diagnostics, #{id := Id, lease := Lease, job := Job} = State) ->
    Max = maps:get(<<"max_diagnostic_bytes">>, maps:get(<<"limits">>, Job)),
    Public = case is_binary(Diagnostics) andalso byte_size(Diagnostics) =< Max of true -> Diagnostics; false -> <<>> end,
    _ = ae_store:evolution({execution_failed, Id, maps:get(<<"attempts">>, Job), <<"build">>, maps:get(<<"id">>, Lease), Reason, Public}),
    notify({error, Reason}, State).
notify(Result, #{notify := Notify, id := Id} = State) ->
    Notify ! {ae_build_result, Id, Result}, {stop, normal, State}.
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason.

validate_config(Config) when is_map(Config) ->
    try
        true = lists:sort(maps:keys(Config)) =:= lists:sort([<<"cgroup_root">>, <<"jsx_package">>,
            <<"source_bytes">>, <<"source_files">>, <<"artifact_bytes">>, <<"sandbox_limits">>]),
        true = lists:all(fun(K) -> V = maps:get(K, Config), is_integer(V) andalso V > 0 andalso V < (1 bsl 63) end,
            [<<"source_bytes">>, <<"source_files">>, <<"artifact_bytes">>]),
        true = lists:all(fun(K) -> V = maps:get(K, Config), is_binary(V) andalso filename:pathtype(V) =:= absolute end,
            [<<"cgroup_root">>, <<"jsx_package">>]),
        Limits = maps:get(<<"sandbox_limits">>, Config),
        true = lists:sort(maps:keys(Limits)) =:= lists:sort([<<"memory_bytes">>, <<"pids">>, <<"cpu_percent">>,
            <<"cpu_seconds">>, <<"address_space_bytes">>, <<"file_bytes">>, <<"open_files">>, <<"output_bytes">>, <<"wall_ms">>]),
        true = lists:all(fun(V) -> is_integer(V) andalso V > 0 andalso V < (1 bsl 63) end, maps:values(Limits)),
        {ok, Config}
    catch _:_ -> {error, build_configuration_required} end;
validate_config(_) -> {error, build_configuration_required}.
