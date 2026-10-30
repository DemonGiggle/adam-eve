-module(ae_telegram_store).
-export([schema/0, dispatch/2]).

schema() -> [
    "CREATE TABLE IF NOT EXISTS telegram_inbox(bot INTEGER NOT NULL,id INTEGER NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(bot,id))",
    "CREATE TABLE IF NOT EXISTS telegram_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT,bot INTEGER NOT NULL,update_id INTEGER NOT NULL,status TEXT NOT NULL,data TEXT NOT NULL)"
].
dispatch(Db, {offset, Bot}) ->
    case ae_sql:rows(Db, "SELECT data FROM control WHERE name=?", [cursor(Bot)]) of [] -> 0; [{D}] -> jsx:decode(D) end;
dispatch(Db, {ingest, Bot, Offset, Entries}) ->
    Old = dispatch(Db, {offset, Bot}), true = is_integer(Offset) andalso Offset >= Old,
    lists:foreach(fun(#{<<"update_id">> := Id, <<"kind">> := Kind} = E) ->
        true = Id >= Old andalso Id < Offset,
        ae_sql:exec(Db, "INSERT OR IGNORE INTO telegram_inbox VALUES(?,?,?,'queued',?)", [Bot, Id, Kind, jsx:encode(E)])
    end, Entries),
    ae_sql:exec(Db, "INSERT OR REPLACE INTO control VALUES(?,?)", [cursor(Bot), jsx:encode(Offset)]), ok;
dispatch(Db, {recover, Bot}) ->
    ae_sql:exec(Db, "UPDATE telegram_inbox SET status='queued' WHERE bot=? AND status='running'", [Bot]),
    ae_sql:exec(Db, "UPDATE telegram_outbox SET status='pending' WHERE bot=? AND status='sending'", [Bot]), ok;
dispatch(Db, {count, Bot}) ->
    [{N}] = ae_sql:rows(Db, "SELECT count(*) FROM telegram_inbox WHERE bot=? AND status IN ('queued','running','blocked')", [Bot]), N;
dispatch(Db, {next, Bot, Kind}) ->
    case ae_sql:rows(Db, "SELECT id,data FROM telegram_inbox WHERE bot=? AND kind=? AND status='queued' ORDER BY id LIMIT 1", [Bot, Kind]) of
        [] -> undefined; [{Id, D}] -> {Id, jsx:decode(D, [return_maps])}
    end;
dispatch(Db, {next_interrupt, Bot}) ->
    Rows = ae_sql:rows(Db, "SELECT id,data FROM telegram_inbox WHERE bot=? AND kind='command' AND status='queued' ORDER BY id", [Bot]),
    case [{Id, E} || {Id, D} <- Rows, E <- [jsx:decode(D, [return_maps])],
            lists:member(maps:get(<<"command">>, E), [<<"/cancel">>, <<"/new">>])] of
        [] -> undefined; [First | _] -> First end;
dispatch(Db, {earlier, Bot, Kind, Id, Session}) ->
    Scope = ae_sessions:scope(Session),
    Rows = ae_sql:rows(Db, "SELECT data FROM telegram_inbox WHERE bot=? AND kind=? AND id<? AND status IN ('queued','running') ORDER BY id", [Bot, Kind, Id]),
    lists:any(fun({D}) -> E = jsx:decode(D, [return_maps]),
        ae_sessions:scope(maps:get(<<"session_id">>, E)) =:= Scope end, Rows);
dispatch(Db, {claim, Bot, Id}) ->
    ae_sql:exec(Db, "UPDATE telegram_inbox SET status='running' WHERE bot=? AND id=? AND status='queued'", [Bot, Id]), ok;
dispatch(Db, {defer, Bot, Id}) ->
    ae_sql:exec(Db, "UPDATE telegram_inbox SET status='queued' WHERE bot=? AND id=? AND status='running'", [Bot, Id]), ok;
dispatch(Db, {finish, Bot, Id, Status, Text}) ->
    case ae_sql:rows(Db, "SELECT status,data FROM telegram_inbox WHERE bot=? AND id=?", [Bot, Id]) of
        [{Old, D}] when Old =:= <<"running">>; Old =:= <<"queued">> ->
            E = jsx:decode(D, [return_maps]),
            ae_sql:exec(Db, "UPDATE telegram_inbox SET status=? WHERE bot=? AND id=?", [Status, Bot, Id]),
            lists:foreach(fun(Part) ->
                ae_sql:exec(Db, "INSERT INTO telegram_outbox(bot,update_id,status,data) VALUES(?,?,'pending',?)",
                    [Bot, Id, jsx:encode(#{<<"route">> => maps:remove(<<"images">>, E), <<"text">> => Part})])
            end, ae_telegram_format:split(Text)), ok;
        _ -> ok
    end;
dispatch(Db, {next_outbox, Bot}) ->
    case ae_sql:rows(Db, "SELECT id,data FROM telegram_outbox WHERE bot=? AND status='pending' ORDER BY id LIMIT 1", [Bot]) of
        [] -> undefined; [{Id, D}] -> {Id, jsx:decode(D, [return_maps])}
    end;
dispatch(Db, {outbox, Id, Status}) ->
    ae_sql:exec(Db, "UPDATE telegram_outbox SET status=? WHERE id=?", [Status, Id]), ok;
dispatch(Db, {blocked, Bot, Session}) ->
    case ae_sql:rows(Db, "SELECT id,data FROM telegram_inbox WHERE bot=? AND kind='turn' AND status='blocked' ORDER BY id", [Bot]) of
        Rows -> case [{Id, E} || {Id, D} <- Rows, E <- [jsx:decode(D, [return_maps])], maps:get(<<"session_id">>, E) =:= Session] of
            [] -> undefined; [First | _] -> First end
    end;
dispatch(Db, {requeue, Bot, Id}) -> ae_sql:exec(Db, "UPDATE telegram_inbox SET status='queued' WHERE bot=? AND id=? AND status='blocked'", [Bot, Id]), ok;
dispatch(Db, {pending, Bot, Session}) ->
    Rows = ae_sql:rows(Db, "SELECT id,data FROM telegram_inbox WHERE bot=? AND kind='turn' AND status IN ('queued','running','blocked') ORDER BY id", [Bot]),
    [{Id, E} || {Id, D} <- Rows, E <- [jsx:decode(D, [return_maps])], maps:get(<<"session_id">>, E) =:= Session];
dispatch(Db, {cancel, Bot, Id}) ->
    ae_sql:exec(Db, "UPDATE telegram_inbox SET status='cancelled' WHERE bot=? AND id=? AND status IN ('queued','running','blocked')", [Bot, Id]), ok;
dispatch(Db, {images, Bot, Id, Images}) ->
    case ae_sql:rows(Db, "SELECT data FROM telegram_inbox WHERE bot=? AND id=? AND status='running'", [Bot, Id]) of
        [{Data}] ->
            Entry = jsx:decode(Data, [return_maps]),
            case maps:find(<<"images">>, Entry) of
                {ok, Images} -> ok;
                {ok, _} -> {error, image_conflict};
                error -> ae_sql:exec(Db, "UPDATE telegram_inbox SET data=? WHERE bot=? AND id=?",
                    [jsx:encode(Entry#{<<"images">> => Images}), Bot, Id]), ok
            end;
        _ -> {error, cancelled}
    end;
dispatch(Db, {media, Request}) ->
    case binary:split(Request, <<":">>, [global]) of
        [<<"tg">>, Bot0, Id0] ->
            try
                Bot = binary_to_integer(Bot0), Id = binary_to_integer(Id0),
                case ae_sql:rows(Db, "SELECT data FROM telegram_inbox WHERE bot=? AND id=?", [Bot, Id]) of
                    [{Data}] -> maps:get(<<"images">>, jsx:decode(Data, [return_maps]), []);
                    _ -> [] end
            catch _:_ -> [] end;
        _ -> []
    end.
cursor(Bot) -> <<"telegram_offset:", (integer_to_binary(Bot))/binary>>.
