-module(ae_cli).
-export([main/0]).

main() ->
    ok = logger:remove_handler(default),
    ok = logger:add_handler(default, logger_std_h, #{config => #{type => standard_error}}),
    try
        Config = ae_config:load(),
        application:load(ae_core),
        application:set_env(ae_core, config, Config),
        case application:ensure_all_started(ae_core) of
            {ok, _} -> loop(), application:stop(ae_core), halt(0);
            {error, _} -> output(#{<<"error">> => <<"controller_start_failed">>}), halt(1)
        end
    catch Class:Reason ->
        io:format(standard_error, "Startup failed: ~p:~p~n", [Class, Reason]), halt(1)
    end.

loop() ->
    case io:get_line("") of
        eof -> ok;
        {error, _} -> ok;
        Line ->
            Reply = try
                Data = unicode:characters_to_binary(Line),
                true = byte_size(Data) =< ae_protocol:max_bytes(),
                command(jsx:decode(Data, [return_maps]))
            catch _:_ -> #{<<"error">> => <<"invalid_command">>} end,
            output(Reply), loop()
    end.

command(#{<<"op">> := <<"turn">>, <<"request_id">> := Request,
          <<"session_id">> := Session, <<"message">> := Message} = Command) when map_size(Command) =:= 4 ->
    case ae_router:turn(Request, Session, Message) of
        {ok, Text} -> #{<<"request_id">> => Request, <<"text">> => Text, <<"committed">> => true};
        {error, Reason} -> #{<<"request_id">> => Request, <<"error">> => reason(Reason)}
    end;
command(#{<<"op">> := <<"status">>}) -> ae_router:status();
command(#{<<"op">> := <<"restart">>}) -> result(ae_router:restart());
command(#{<<"op">> := <<"restore_ready">>, <<"backup_id">> := Id, <<"origin_ref">> := Origin}) ->
    result(ae_router:restore_ready(Id, Origin));
command(#{<<"op">> := <<"stage">>, <<"artifact_digest">> := Digest}) ->
    case ae_deployment:stage(Digest) of {ok, Summary} -> Summary; Error -> result(Error) end;
command(#{<<"op">> := <<"approve">>, <<"deployment_id">> := Id, <<"approval_binding">> := Binding}) ->
    case ae_deployment:approve(Id, Binding) of
        {ok, Route} -> #{<<"ok">> => true, <<"routing">> => Route}; Error -> result(Error) end;
command(#{<<"op">> := <<"reject">>, <<"deployment_id">> := Id}) -> result(ae_deployment:reject(Id));
command(#{<<"op">> := <<"deployment">>, <<"deployment_id">> := Id}) ->
    case ae_store:deployment(Id) of undefined -> #{<<"error">> => <<"unknown_deployment">>}; Job -> Job end;
command(#{<<"op">> := <<"retry">>, <<"request_id">> := Request}) -> result(ae_store:retry_turn(Request));
command(#{<<"op">> := <<"cancel">>, <<"request_id">> := Request}) -> result(ae_store:cancel_turn(Request));
command(#{<<"op">> := <<"history">>}) ->
    #{<<"events">> => [#{<<"seq">> => Seq, <<"kind">> => Kind, <<"data">> => Data} ||
                       {Seq, Kind, Data} <- ae_store:events()]};
command(_) -> #{<<"error">> => <<"unknown_command">>}.

result(ok) -> #{<<"ok">> => true};
result({error, Reason}) -> #{<<"error">> => reason(Reason)}.
reason(Reason) when is_atom(Reason) -> atom_to_binary(Reason, utf8);
reason(Reason) when is_binary(Reason) -> Reason.
output(Reply) -> io:put_chars([jsx:encode(Reply), "\n"]).
