-module(ae_store).
-behaviour(gen_server).
-export([start_link/1, boot/1, routing/0, activate/2, authorized/1,
         begin_turn/4, finish_turn/3, context/2, last_seq/0,
         reserve_tool/3, finish_tool/4, events/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Root) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Root, []).
boot(Manifest) -> call({boot, Manifest}).
routing() -> call(routing).
activate(Expected, Instance) -> call({activate, Expected, Instance}).
authorized(Auth) -> call({authorized, Auth}).
begin_turn(Auth, Request, Session, Message) -> call({begin_turn, Auth, Request, Session, Message}).
finish_turn(Auth, Request, Text) -> call({finish_turn, Auth, Request, Text}).
context(Request, Limit) -> call({context, Request, Limit}).
last_seq() -> call(last_seq).
reserve_tool(Auth, Request, Key) -> call({reserve_tool, Auth, Request, Key}).
finish_tool(Auth, Request, Key, Result) -> call({finish_tool, Auth, Request, Key, Result}).
events() -> call(events).
call(Request) -> gen_server:call(?MODULE, Request, 15000).

init(Root) ->
    Path = filename:join([Root, "state", "agent.sqlite3"]),
    ok = filelib:ensure_dir(Path),
    {ok, Db} = sqlite3:open(anonymous, [{file, Path}]),
    [{<<"wal">>}] = rows(Db, "PRAGMA journal_mode=WAL", []),
    _ = sql(Db, "PRAGMA synchronous=FULL", []),
    _ = sql(Db, "PRAGMA foreign_keys=ON", []),
    _ = sql(Db, "PRAGMA busy_timeout=5000", []),
    lists:foreach(fun(Statement) -> sql(Db, Statement, []) end, schema()),
    {ok, Db}.

handle_call(Request, _From, Db) ->
    %% Every mutation, authorization check, and associated event share a transaction.
    Reply = transaction(Db, fun() -> dispatch(Request, Db) end),
    {reply, Reply, Db}.
handle_cast(_, Db) -> {noreply, Db}.
handle_info(_, Db) -> {noreply, Db}.
terminate(_, Db) -> sqlite3:close(Db).

dispatch({boot, Manifest}, Db) ->
    case route(Db) of
        undefined ->
            _ = sql(Db, "INSERT INTO routing(id, data) VALUES(1, ?)",
                [jsx:encode(#{<<"slot">> => <<"adam">>, <<"epoch">> => 0,
                    <<"runtime_instance_id">> => <<"unstarted">>,
                    <<"artifact">> => Manifest})]),
            event(Db, <<"bootstrap">>, Manifest),
            route(Db);
        Existing -> Existing
    end;
dispatch(routing, Db) -> route(Db);
dispatch({activate, Expected, Instance}, Db) ->
    case route(Db) of
        Expected when is_map(Expected) ->
            New = Expected#{<<"epoch">> := maps:get(<<"epoch">>, Expected) + 1,
                            <<"runtime_instance_id">> := Instance},
            _ = sql(Db, "UPDATE routing SET data=? WHERE id=1", [jsx:encode(New)]),
            event(Db, <<"runtime_activated">>, New),
            {ok, New};
        _ -> {error, stale_routing}
    end;
dispatch({authorized, Auth}, Db) -> auth(Db, Auth);
dispatch({begin_turn, Auth, Request, Session, Message}, Db) ->
    require_auth(Db, Auth),
    case turn(Db, Request) of
        undefined ->
            case rows(Db, "SELECT request_id FROM turns WHERE status='pending'", []) of
                [] ->
                    Seq = event(Db, <<"user_message">>, #{<<"request_id">> => Request,
                        <<"session_id">> => Session, <<"text">> => Message}),
                    _ = sql(Db, "INSERT INTO turns VALUES(?,?,?,'pending',NULL,?)",
                        [Request, Session, Message, Seq]),
                    {ok, pending};
                _ -> {error, pending_turn}
            end;
        {Session, Message, <<"pending">>, null, _} -> {ok, pending};
        {Session, Message, <<"completed">>, Reply, _} -> {ok, {completed, Reply}};
        _ -> {error, request_conflict}
    end;
dispatch({finish_turn, Auth, Request, Text}, Db) ->
    require_auth(Db, Auth),
    case turn(Db, Request) of
        {_, _, <<"pending">>, null, _} ->
            event(Db, <<"assistant_reply">>, #{<<"request_id">> => Request, <<"text">> => Text}),
            _ = sql(Db, "UPDATE turns SET status='completed',reply=? WHERE request_id=?",
                    [Text, Request]),
            {ok, Text};
        {_, _, <<"completed">>, Text, _} -> {ok, Text};
        _ -> {error, invalid_turn}
    end;
dispatch({context, Request, Limit}, Db) ->
    case turn(Db, Request) of
        {Session, _, _, _, Seq} ->
            Turns = rows(Db, "SELECT message,reply FROM (SELECT message,reply,user_seq "
                "FROM turns WHERE session_id=? AND user_seq<=? ORDER BY user_seq DESC LIMIT ?) "
                "ORDER BY user_seq", [Session, Seq, Limit]),
            lists:flatmap(fun({Message, Reply}) ->
                User = #{<<"role">> => <<"user">>, <<"content">> => Message},
                case Reply of
                    null -> [User];
                    _ -> [User, #{<<"role">> => <<"assistant">>, <<"content">> => Reply}]
                end
            end, Turns);
        _ -> {error, unknown_request}
    end;
dispatch(last_seq, Db) -> last(Db);
dispatch({reserve_tool, Auth, Request, Key}, Db) ->
    require_auth(Db, Auth),
    case turn(Db, Request) of
        {_, _, <<"pending">>, null, _} ->
            case rows(Db, "SELECT status,result FROM tools WHERE request_id=? AND key=?",
                      [Request, Key]) of
                [] ->
                    _ = sql(Db, "INSERT INTO tools VALUES(?,?,'reserved',NULL)", [Request, Key]),
                    event(Db, <<"tool_reserved">>, #{<<"request_id">> => Request, <<"key">> => Key}),
                    {ok, reserved};
                [{<<"completed">>, Data}] -> {ok, {completed, jsx:decode(Data, [return_maps])}};
                _ -> {error, tool_outcome_unknown}
            end;
        _ -> {error, invalid_turn}
    end;
dispatch({finish_tool, Auth, Request, Key, Result}, Db) ->
    require_auth(Db, Auth),
    case rows(Db, "SELECT status FROM tools WHERE request_id=? AND key=?", [Request, Key]) of
        [{<<"reserved">>}] ->
            _ = sql(Db, "UPDATE tools SET status='completed',result=? WHERE request_id=? AND key=?",
                    [jsx:encode(Result), Request, Key]),
            event(Db, <<"tool_result">>, #{<<"request_id">> => Request,
                <<"key">> => Key, <<"result">> => Result}),
            {ok, Result};
        _ -> {error, invalid_tool}
    end;
dispatch(events, Db) ->
    [{Seq, Kind, jsx:decode(Data, [return_maps])} || {Seq, Kind, Data} <-
        rows(Db, "SELECT seq,kind,data FROM events ORDER BY seq", [])].

auth(Db, Auth) ->
    case route(Db) of
        #{<<"slot">> := Slot, <<"runtime_instance_id">> := Instance, <<"epoch">> := Epoch}
            when Auth =:= {Slot, Instance, Epoch} -> ok;
        _ -> {error, stale_runtime}
    end.
require_auth(Db, Auth) ->
    case auth(Db, Auth) of ok -> ok; Error -> throw(Error) end.
route(Db) ->
    case rows(Db, "SELECT data FROM routing WHERE id=1", []) of
        [] -> undefined;
        [{Data}] -> jsx:decode(Data, [return_maps])
    end.
turn(Db, Request) ->
    case rows(Db, "SELECT session_id,message,status,reply,user_seq FROM turns WHERE request_id=?",
              [Request]) of [] -> undefined; [Turn] -> Turn end.
event(Db, Kind, Data) ->
    _ = sql(Db, "INSERT INTO events(kind,data) VALUES(?,?)", [Kind, jsx:encode(Data)]),
    last(Db).
last(Db) ->
    [{Seq}] = rows(Db, "SELECT COALESCE(MAX(seq),0) FROM events", []), Seq.

transaction(Db, Fun) ->
    _ = sql(Db, "BEGIN IMMEDIATE", []),
    try Fun() of
        Reply -> _ = sql(Db, "COMMIT", []), Reply
    catch
        throw:Error -> _ = sql(Db, "ROLLBACK", []), Error;
        Class:Reason:Stack ->
            _ = sql(Db, "ROLLBACK", []), erlang:raise(Class, Reason, Stack)
    end.
sql(Db, Statement, Params) ->
    case sqlite3:sql_exec(Db, Statement, Params) of
        {error, Code, Message} -> error({storage_failure, Code, Message});
        Result -> Result
    end.
rows(Db, Statement, Params) ->
    Result = sql(Db, Statement, Params),
    {rows, Rows} = lists:keyfind(rows, 1, Result), Rows.
schema() -> [
    "CREATE TABLE IF NOT EXISTS routing(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,kind TEXT NOT NULL,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS turns(request_id TEXT PRIMARY KEY,session_id TEXT NOT NULL,message TEXT NOT NULL,"
        "status TEXT NOT NULL,reply TEXT,user_seq INTEGER NOT NULL REFERENCES events(seq))",
    "CREATE TABLE IF NOT EXISTS tools(request_id TEXT NOT NULL REFERENCES turns(request_id),key TEXT NOT NULL,"
        "status TEXT NOT NULL,result TEXT,PRIMARY KEY(request_id,key))"
].
