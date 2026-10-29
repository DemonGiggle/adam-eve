-module(ae_protocol).
-export([send/2, recv/2, decode/1, validate/1, socket_options/0, max_bytes/0]).

max_bytes() -> 1048576.

socket_options() ->
    [binary, {packet, 4}, {packet_size, max_bytes()}, {active, false}].

send(Socket, Message) ->
    case validate(Message) of
        ok ->
            Data = jsx:encode(Message),
            case byte_size(Data) =< max_bytes() of
                true -> gen_tcp:send(Socket, Data);
                false -> {error, oversized_message}
            end;
        Error -> Error
    end.

recv(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 0, Timeout) of
        {ok, Data} -> decode(Data);
        Error -> Error
    end.

decode(Data) when is_binary(Data), byte_size(Data) =< 1048576 ->
    try jsx:decode(Data, [return_maps, strict]) of
        Message ->
            case validate(Message) of
                ok -> {ok, Message};
                Error -> Error
            end
    catch _:_ -> {error, invalid_json}
    end;
decode(_) -> {error, oversized_message}.

validate(#{<<"protocol_version">> := 1, <<"type">> := Type} = Message) ->
    case schema(Type) of
        undefined -> {error, unknown_message};
        Fields ->
            Expected = [<<"protocol_version">>, <<"type">> | [K || {K, _} <- Fields]],
            case lists:sort(maps:keys(Message)) =:= lists:sort(Expected) andalso
                 lists:all(fun({K, Kind}) -> valid(Kind, maps:get(K, Message, null)) end,
                           Fields) of
                true -> ok;
                false -> {error, invalid_message}
            end
    end;
validate(_) -> {error, unsupported_protocol}.

schema(<<"authenticate">>) -> [{<<"token">>, string}];
schema(<<"hello">>) -> [{<<"slot">>, slot}, {<<"runtime_instance_id">>, string},
    {<<"generation">>, string}, {<<"capabilities">>, strings}];
schema(<<"restore">>) -> [{<<"checkpoint_id">>, string},
    {<<"state_schema_version">>, version}, {<<"last_event_seq">>, sequence}];
schema(<<"ready">>) -> [{<<"generation">>, string}, {<<"restored_seq">>, sequence},
    {<<"supported_schema_versions">>, versions}];
schema(<<"user_turn">>) -> [{<<"request_id">>, string}, {<<"session_id">>, string},
    {<<"epoch">>, epoch}, {<<"message">>, text}, {<<"memory_cursor">>, sequence}];
schema(<<"tool_request">>) -> [{<<"request_id">>, string}, {<<"epoch">>, epoch},
    {<<"tool">>, string}, {<<"args">>, object}, {<<"idempotency_key">>, string}];
schema(<<"tool_result">>) -> [{<<"request_id">>, string}, {<<"idempotency_key">>, string},
    {<<"result">>, object}];
schema(<<"assistant_reply">>) -> [{<<"request_id">>, string}, {<<"text">>, text},
    {<<"event_refs">>, sequences}];
schema(<<"turn_failed">>) -> [{<<"request_id">>, string}, {<<"reason">>, string}];
schema(<<"health_check">>) -> [{<<"request_id">>, string}];
schema(<<"health_status">>) -> [{<<"request_id">>, string}, {<<"status">>, string}];
schema(<<"shutdown">>) -> [{<<"reason">>, string}];
schema(<<"evolution_context">>) -> [{<<"job_id">>, string}, {<<"origin_ref">>, string},
    {<<"base_generation">>, string}, {<<"base_artifact">>, string},
    {<<"base_source_revision">>, string}, {<<"base_epoch">>, epoch}, {<<"target_slot">>, slot},
    {<<"objective">>, text}, {<<"source_manifest_ref">>, string}, {<<"limits">>, object}];
schema(<<"evolution_feedback">>) -> [{<<"job_id">>, string}, {<<"attempt_id">>, sequence},
    {<<"outcome">>, string}, {<<"diagnostics_ref">>, string}, {<<"evaluation_summary_ref">>, string},
    {<<"remaining_budget">>, object}];
schema(<<"evolution_proposal">>) -> [{<<"job_id">>, string}, {<<"proposal_id">>, string},
    {<<"epoch">>, epoch}, {<<"base_artifact">>, string}, {<<"base_source_revision">>, string},
    {<<"patch">>, patch}, {<<"hypothesis">>, rationale}, {<<"expected_benefit">>, rationale},
    {<<"risks">>, strings}, {<<"requested_tests">>, strings}];
schema(<<"evolution_failed">>) -> [{<<"job_id">>, string}, {<<"epoch">>, epoch}, {<<"reason">>, string}];
schema(_) -> undefined.

valid(string, V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 256;
valid(text, V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 65536;
valid(patch, V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 262144;
valid(rationale, V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 4096;
valid(slot, V) -> V =:= <<"adam">> orelse V =:= <<"eve">>;
valid(sequence, V) -> is_integer(V) andalso V >= 0;
valid(epoch, V) -> is_integer(V) andalso V > 0;
valid(version, V) -> V =:= 1;
valid(object, V) -> is_map(V);
valid(strings, V) -> is_list(V) andalso length(V) =< 32 andalso lists:all(fun(X) -> valid(string, X) end, V);
valid(versions, V) -> V =:= [1];
valid(sequences, V) -> is_list(V) andalso lists:all(fun(X) -> valid(sequence, X) end, V).
