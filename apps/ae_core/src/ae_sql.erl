-module(ae_sql).
-export([exec/3, rows/3, event/3, recovery/1, recovery_pending/1]).

exec(Db, Statement, Params) ->
    case sqlite3:sql_exec(Db, Statement, Params) of
        {error, Code, Message} -> error({storage_failure, Code, Message});
        Result -> Result
    end.
rows(Db, Statement, Params) ->
    {rows, Rows} = lists:keyfind(rows, 1, exec(Db, Statement, Params)), Rows.
event(Db, Kind, Data) ->
    exec(Db, "INSERT INTO events(kind,data) VALUES(?,?)", [Kind, jsx:encode(Data)]),
    [{Seq}] = rows(Db, "SELECT last_insert_rowid()", []), Seq.

recovery(Db) ->
    case rows(Db, "SELECT data FROM control WHERE name='restore'", []) of
        [] -> undefined;
        [{Data}] ->
            #{<<"schema_version">> := 1, <<"backup_id">> := Id, <<"pending">> := Pending,
              <<"source_event_seq">> := Seq, <<"epoch_floor">> := Floor} = Record = jsx:decode(Data, [return_maps]),
            true = Pending =:= true orelse Pending =:= false,
            true = is_integer(Seq) andalso Seq >= 0 andalso is_integer(Floor) andalso Floor >= 0,
            true = is_binary(Id) andalso re:run(Id, <<"^[0-9a-f]{64}$">>, [{capture, none}]) =:= match,
            Record
    end.
recovery_pending(Db) ->
    case recovery(Db) of undefined -> false; #{<<"pending">> := Pending} -> Pending end.
