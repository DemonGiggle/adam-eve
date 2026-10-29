-module(ae_sql).
-export([exec/3, rows/3, event/3]).

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
