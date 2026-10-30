-module(ae_authoring_broker).
-export([request/4]).

%% Separate from conversation tools. An IPC runner selects this interface only
%% while exchanging an already-authorized job; the agent cannot invent a trigger.
request(Auth, Id, Message, Config) ->
    try
        ok = ae_protocol:validate(Message),
        #{<<"type">> := <<"tool_request">>, <<"request_id">> := Id,
          <<"epoch">> := Epoch, <<"tool">> := Tool, <<"args">> := Args,
          <<"idempotency_key">> := Key} = Message,
        {_, _, Epoch} = Auth,
        case ae_store:evolution({authorize, Auth, Id}) of
            {ok, Job} ->
                Artifact = maps:get(<<"artifact">>, maps:get(<<"baseline">>, Job)),
                true = lists:member(Tool, maps:get(<<"capabilities">>, Artifact, [])),
                Base = #{<<"job_id">> => Id, <<"base_artifact">> => maps:get(<<"digest">>, Artifact),
                         <<"base_source_revision">> => maps:get(<<"source_revision">>, Artifact)},
                Base = maps:with(maps:keys(Base), Args),
                Extra = maps:without(maps:keys(Base), Args),
                execute(Tool, Extra, Key, Auth, Job, Config);
            Error -> Error
        end
    catch _:_ -> {error, denied} end.

execute(<<"source_list">>, #{<<"offset">> := Offset, <<"count">> := Count} = Args, _, Auth,
        #{<<"id">> := Id}, #{root := Root}) when map_size(Args) =:= 2 ->
    ae_source:list(Root, Auth, Id, Offset, Count);
execute(<<"source_read">>, #{<<"path">> := Path, <<"offset">> := Offset, <<"bytes">> := Bytes} = Args,
        _, Auth, #{<<"id">> := Id}, #{root := Root}) when map_size(Args) =:= 3 ->
    ae_source:read(Root, Auth, Id, Path, Offset, Bytes);
execute(<<"evolution_status">>, Args, _, _, Job, _) when map_size(Args) =:= 0 ->
    %% No raw evaluator records, private tests, controller config or credentials.
    {ok, maps:with([<<"id">>, <<"origin_ref">>, <<"objective">>, <<"baseline">>, <<"status">>,
        <<"target_slot">>, <<"deadline">>, <<"limits">>, <<"attempts">>, <<"llm_calls">>,
        <<"reserved_tokens">>, <<"reserved_cost_microunits">>, <<"source_calls">>,
        <<"source_bytes">>, <<"public_diagnostics">>], Job)};
execute(<<"evolution_llm">>, #{<<"call_id">> := Call, <<"messages">> := Messages} = Args,
        Call, Auth, Job, Config) when map_size(Args) =:= 2 ->
    true = valid_messages(Messages),
    Id = maps:get(<<"id">>, Job), Hash = ae_policy:digest(Messages),
    case ae_store:evolution({reserve_llm, Auth, Id, Call, Hash}) of
        {ok, reserved} ->
            Remaining = maps:get(<<"deadline">>, Job) - erlang:system_time(millisecond),
            Timeout = max(1, min(Remaining, maps:get(llm_timeout, Config))),
            Result = case ae_llm_ollama:complete_budgeted(Messages, Config#{llm_timeout := Timeout,
                    authoring_limits => maps:get(<<"limits">>, Job)},
                    maps:get(<<"tokens_per_call">>, maps:get(<<"limits">>, Job))) of
                {ok, Value} -> Value;
                {error, Reason} -> #{<<"error">> => atom_to_binary(Reason, utf8)}
            end,
            case ae_store:evolution({finish_llm, Auth, Id, Call, Result}) of
                {ok, _} ->
                    case maps:get(<<"error">>, Result, undefined) of
                        <<"provider_budget_violation">> -> ae_store:evolution({cancel, Id, <<"provider_budget_violation">>});
                        _ -> ok
                    end,
                    {ok, Result};
                Error -> Error
            end;
        {ok, {completed, Result}} -> {ok, Result};
        Error -> Error
    end;
execute(_, _, _, _, _, _) -> {error, denied}.

valid_messages(Messages) when is_list(Messages), length(Messages) > 0, length(Messages) =< 32 ->
    byte_size(jsx:encode(Messages)) =< 262144 andalso lists:all(fun
        (#{<<"role">> := Role, <<"content">> := Text} = M) ->
            map_size(M) =:= 2 andalso lists:member(Role, [<<"system">>, <<"user">>, <<"assistant">>])
                andalso is_binary(Text) andalso byte_size(Text) > 0 andalso byte_size(Text) =< 131072;
        (_) -> false
    end, Messages);
valid_messages(_) -> false.
