-module(ae_store).
-behaviour(gen_server).
-export([start_link/1, boot/1, routing/0, activate/2, authorized/1,
         begin_turn/4, finish_turn/3, context/2, last_seq/0,
         reserve_tool/3, reserve_tool/4, finish_tool/4, retry_turn/1, cancel_turn/1, events/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-export([register_artifact/1, checkpoint/1, get_checkpoint/1, quiesce/2,
         new_deployment/3, staged/3, approve/2, reject/2, deployment/1,
         active_deployment/0, promote/4, rollback/5, complete/2, recover_handoff/0,
         activate_checkpoint/3, runtime_failed/2]).

start_link(Root) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Root, []).
boot(Manifest) -> call({boot, Manifest}).
routing() -> call(routing).
activate(Expected, Instance) -> call({activate, Expected, Instance}).
authorized(Auth) -> call({authorized, Auth}).
begin_turn(Auth, Request, Session, Message) -> call({begin_turn, Auth, Request, Session, Message}).
finish_turn(Auth, Request, Text) -> call({finish_turn, Auth, Request, Text}).
context(Request, Limit) -> call({context, Request, Limit}).
last_seq() -> call(last_seq).
reserve_tool(Auth, Request, Key) -> reserve_tool(Auth, Request, Key, 3).
reserve_tool(Auth, Request, Key, MaxAttempts) -> call({reserve_tool, Auth, Request, Key, MaxAttempts}).
finish_tool(Auth, Request, Key, Result) -> call({finish_tool, Auth, Request, Key, Result}).
retry_turn(Request) -> call({retry_turn, Request}).
cancel_turn(Request) -> call({cancel_turn, Request}).
events() -> call(events).
register_artifact(Manifest) -> call({register_artifact, Manifest}).
checkpoint(Expected) -> call({checkpoint, Expected}).
get_checkpoint(Id) -> call({get_checkpoint, Id}).
quiesce(Expected, Job) -> call({quiesce, Expected, Job}).
new_deployment(Expected, Candidate, Limits) -> call({new_deployment, Expected, Candidate, Limits}).
staged(Id, Descriptor, Evaluation) -> call({staged, Id, Descriptor, Evaluation}).
approve(Id, Binding) -> call({approve, Id, Binding}).
reject(Id, Reason) -> call({reject, Id, Reason}).
deployment(Id) -> call({deployment, Id}).
active_deployment() -> call(active_deployment).
promote(Id, Expected, Descriptor, Checkpoint) -> call({promote, Id, Expected, Descriptor, Checkpoint}).
rollback(Id, Expected, Descriptor, Checkpoint, Reason) -> call({rollback, Id, Expected, Descriptor, Checkpoint, Reason}).
complete(Id, Expected) -> call({complete, Id, Expected}).
recover_handoff() -> call(recover_handoff).
activate_checkpoint(Expected, Descriptor, Checkpoint) -> call({activate_checkpoint, Expected, Descriptor, Checkpoint}).
runtime_failed(Expected, Reason) -> call({runtime_failed, Expected, Reason}).
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
    transaction(Db, fun() ->
        case route(Db) of
            undefined -> ok;
            Existing -> initialize_registry(Db, Existing)
        end
    end),
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
                    <<"artifact">> => Manifest, <<"admission">> => <<"open">>})]),
            event(Db, <<"bootstrap">>, Manifest),
            initialize_registry(Db, route(Db)),
            route(Db);
        Existing -> Existing
    end;
dispatch(routing, Db) -> route(Db);
dispatch({activate, Expected, Instance}, Db) ->
    case route(Db) of
        Expected when is_map(Expected) ->
            New = Expected#{<<"epoch">> := maps:get(<<"epoch">>, Expected) + 1,
                            <<"runtime_instance_id">> := Instance, <<"admission">> => <<"open">>},
            _ = sql(Db, "UPDATE routing SET data=? WHERE id=1", [jsx:encode(New)]),
            event(Db, <<"runtime_activated">>, New),
            {ok, New};
        _ -> {error, stale_routing}
    end;
dispatch({authorized, Auth}, Db) -> admission_auth(Db, Auth);
dispatch({begin_turn, Auth, Request, Session, Message}, Db) ->
    require_auth(Db, Auth),
    require_open(Db),
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
                "FROM turns WHERE session_id=? AND user_seq<=? AND status!='cancelled' "
                "ORDER BY user_seq DESC LIMIT ?) "
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
dispatch({reserve_tool, Auth, Request, Key, MaxAttempts}, Db) ->
    require_auth(Db, Auth),
    require_open(Db),
    case turn(Db, Request) of
        {_, _, <<"pending">>, null, _} ->
            case rows(Db, "SELECT status,result FROM tools WHERE request_id=? AND key=?",
                      [Request, Key]) of
                [] ->
                    _ = sql(Db, "INSERT INTO tools VALUES(?,?,'reserved',NULL)", [Request, Key]),
                    _ = sql(Db, "INSERT INTO tool_attempts VALUES(?,?,1)", [Request, Key]),
                    event(Db, <<"tool_reserved">>, #{<<"request_id">> => Request, <<"key">> => Key}),
                    {ok, reserved};
                [{<<"retryable">>, _}] ->
                    [{Attempts}] = rows(Db, "SELECT attempts FROM tool_attempts WHERE request_id=? AND key=?",
                                        [Request, Key]),
                    case Attempts < MaxAttempts of
                        true ->
                            _ = sql(Db, "UPDATE tool_attempts SET attempts=attempts+1 WHERE request_id=? AND key=?",
                                    [Request, Key]),
                            _ = sql(Db, "UPDATE tools SET status='reserved',result=NULL WHERE request_id=? AND key=?",
                                    [Request, Key]),
                            event(Db, <<"tool_reserved">>, #{<<"request_id">> => Request, <<"key">> => Key}),
                            {ok, reserved};
                        false -> {error, attempt_limit}
                    end;
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
dispatch({retry_turn, Request}, Db) ->
    %% Operator-only reconciliation. Inference can be repeated, but may incur another charge.
    case {turn(Db, Request), rows(Db, "SELECT status,result FROM tools WHERE request_id=? AND key='llm'", [Request])} of
        {{_, _, <<"pending">>, null, _}, [{Status, Data}]} ->
            case Status =:= <<"reserved">> orelse
                 (Status =:= <<"completed">> andalso maps:is_key(<<"error">>, jsx:decode(Data, [return_maps]))) of
                true ->
                    _ = sql(Db, "UPDATE tools SET status='retryable' WHERE request_id=? AND key='llm'", [Request]),
                    event(Db, <<"operator_retry">>, #{<<"request_id">> => Request}), ok;
                false -> {error, retry_not_needed}
            end;
        _ -> {error, retry_not_needed}
    end;
dispatch({cancel_turn, Request}, Db) ->
    case turn(Db, Request) of
        {_, _, <<"pending">>, null, _} ->
            _ = sql(Db, "UPDATE turns SET status='cancelled' WHERE request_id=?", [Request]),
            event(Db, <<"turn_cancelled">>, #{<<"request_id">> => Request}), ok;
        _ -> {error, invalid_turn}
    end;
dispatch({register_artifact, Manifest}, Db) -> register_manifest(Db, Manifest);
dispatch({runtime_failed, Expected, Reason}, Db) ->
    require_baseline(Db, Expected),
    save_route(Db, (route(Db))#{<<"admission">> => <<"closed">>}),
    event(Db, <<"runtime_failed">>, #{<<"runtime">> => ae_policy:baseline(Expected), <<"reason">> => Reason}), ok;
dispatch({activate_checkpoint, Expected, Descriptor, Checkpoint}, Db) ->
    require_baseline(Db, Expected), require_checkpoint(Db, Checkpoint),
    require(maps:get(<<"slot">>, Descriptor) =:= maps:get(<<"slot">>, Expected) andalso
            maps:get(<<"artifact">>, Descriptor) =:= maps:get(<<"artifact">>, Expected), wrong_runtime),
    New = new_route(Expected, Descriptor, Checkpoint), save_route(Db, New),
    event(Db, <<"runtime_activated">>, New), {ok, New};
dispatch({checkpoint, Expected}, Db) ->
    require_baseline(Db, Expected),
    Seq = last(Db),
    Pending = [Id || {Id} <- rows(Db, "SELECT request_id FROM turns WHERE status='pending' ORDER BY user_seq", [])],
    Envelope = #{<<"schema_version">> => 1, <<"identity_id">> => <<"adam-eve/default">>,
        <<"generation">> => maps:get(<<"digest">>, maps:get(<<"artifact">>, Expected)),
        <<"last_event_seq">> => Seq, <<"pending_task_ids">> => Pending},
    Id = ae_policy:digest(Envelope),
    _ = sql(Db, "INSERT OR IGNORE INTO checkpoints VALUES(?,?)", [Id, jsx:encode(Envelope)]),
    event(Db, <<"checkpoint_saved">>, #{<<"checkpoint_id">> => Id, <<"last_event_seq">> => Seq}),
    {ok, Envelope#{<<"checkpoint_id">> => Id}};
dispatch({get_checkpoint, Id}, Db) -> checkpoint_data(Db, Id);
dispatch({new_deployment, Expected, Candidate, Limits}, Db) ->
    require_baseline(Db, Expected), require_open(Db),
    require(active_job(Db) =:= undefined, deployment_in_progress),
    require(maps:get(<<"parent">>, Candidate, null) =:=
        maps:get(<<"digest">>, maps:get(<<"artifact">>, Expected)), stale_candidate),
    ok = register_manifest(Db, Candidate),
    Id = ae_policy:digest(#{<<"nonce">> => list_to_binary(integer_to_list(erlang:unique_integer([positive]))),
                           <<"baseline">> => Expected, <<"time">> => now_ms()}),
    Job = #{<<"id">> => Id, <<"status">> => <<"staging">>, <<"baseline">> => Expected,
        <<"candidate">> => Candidate, <<"target_slot">> => ae_policy:other_slot(maps:get(<<"slot">>, Expected)),
        <<"limits">> => Limits, <<"created_at">> => now_ms(),
        <<"expires_at">> => now_ms() + maps:get(<<"approval_ttl_ms">>, Limits)},
    save_job(Db, Job), event(Db, <<"deployment_started">>, Job), {ok, Job};
dispatch({staged, Id, Descriptor, Evaluation}, Db) ->
    Job = require_job(Db, Id, [<<"staging">>]),
    require_baseline(Db, maps:get(<<"baseline">>, Job)), require_unexpired(Job),
    require_descriptor(Job, Descriptor, candidate),
    New = Job#{<<"status">> := <<"awaiting_approval">>, <<"runtime">> => Descriptor,
               <<"evaluation">> => Evaluation},
    save_job(Db, New), event(Db, <<"candidate_staged">>, New), {ok, New};
dispatch({approve, Id, Binding}, Db) ->
    Job = require_job(Db, Id, [<<"awaiting_approval">>]),
    require_baseline(Db, maps:get(<<"baseline">>, Job)), require_unexpired(Job),
    require(Binding =:= ae_policy:binding(Job), approval_mismatch),
    New = Job#{<<"status">> := <<"approved">>, <<"approval_binding">> => Binding},
    save_job(Db, New), event(Db, <<"deployment_approved">>, #{<<"id">> => Id, <<"binding">> => Binding}),
    {ok, New};
dispatch({quiesce, Expected, Id}, Db) ->
    require_baseline(Db, Expected),
    case Id of
        null -> ok;
        _ ->
            Job = require_job(Db, Id, [<<"approved">>]), require_unexpired(Job),
            require(ae_policy:same_baseline(Expected, maps:get(<<"baseline">>, Job)), stale_routing),
            save_job(Db, Job#{<<"status">> := <<"quiescing">>})
    end,
    Closed = (route(Db))#{<<"admission">> => <<"closed">>},
    save_route(Db, Closed), event(Db, <<"admission_closed">>, #{<<"deployment_id">> => Id}), {ok, Closed};
dispatch({promote, Id, Expected, Descriptor, Checkpoint}, Db) ->
    Job = require_job(Db, Id, [<<"quiescing">>]), require_unexpired(Job),
    require_baseline(Db, Expected),
    require(ae_policy:same_baseline(Expected, maps:get(<<"baseline">>, Job)), stale_routing),
    require(maps:get(<<"admission">>, route(Db), <<"open">>) =:= <<"closed">>, not_quiesced),
    require(maps:get(<<"approval_binding">>, Job) =:= ae_policy:binding(Job), approval_mismatch),
    require(Descriptor =:= maps:get(<<"runtime">>, Job), runtime_changed),
    require_descriptor(Job, Descriptor, candidate), require_checkpoint(Db, Checkpoint),
    New = new_route(Expected, Descriptor, Checkpoint),
    Observing = Job#{<<"status">> := <<"observing">>, <<"promoted_route">> => New,
        <<"observe_until">> => now_ms() + maps:get(<<"observe_ms">>, maps:get(<<"limits">>, Job))},
    save_route(Db, New), save_job(Db, Observing),
    event(Db, <<"routing_promoted">>, #{<<"deployment_id">> => Id, <<"routing">> => New}), {ok, New};
dispatch({rollback, Id, Expected, Descriptor, Checkpoint, Reason}, Db) ->
    Job = require_job(Db, Id, [<<"observing">>]), require_baseline(Db, Expected),
    require(ae_policy:same_baseline(Expected, maps:get(<<"promoted_route">>, Job)), stale_routing),
    require_descriptor(Job, Descriptor, predecessor), require_checkpoint(Db, Checkpoint),
    New = new_route(Expected, Descriptor, Checkpoint),
    save_route(Db, New), save_job(Db, Job#{<<"status">> := <<"rolled_back">>, <<"reason">> => Reason}),
    event(Db, <<"routing_rolled_back">>, #{<<"deployment_id">> => Id, <<"routing">> => New,
                                          <<"reason">> => Reason}), {ok, New};
dispatch({complete, Id, Expected}, Db) ->
    Job = require_job(Db, Id, [<<"observing">>]), require_baseline(Db, Expected),
    require(ae_policy:same_baseline(Expected, maps:get(<<"promoted_route">>, Job)), stale_routing),
    require(now_ms() >= maps:get(<<"observe_until">>, Job), observation_incomplete),
    save_job(Db, Job#{<<"status">> := <<"completed">>}),
    _ = sql(Db, "UPDATE control SET data=? WHERE name='last_known_good'", [jsx:encode(Expected)]),
    event(Db, <<"deployment_completed">>, #{<<"deployment_id">> => Id}), ok;
dispatch({reject, Id, Reason}, Db) -> reject_job(Db, Id, Reason);
dispatch({deployment, Id}, Db) -> job(Db, Id);
dispatch(active_deployment, Db) -> active_job(Db);
dispatch(recover_handoff, Db) ->
    case active_job(Db) of
        #{<<"status">> := <<"observing">>} = Job -> {rollback, Job};
        #{<<"id">> := Id} -> reject_job(Db, Id, <<"controller_restarted_before_promotion">>), normal;
        undefined -> normal
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
admission_auth(Db, Auth) ->
    case auth(Db, Auth) of
        ok -> case maps:get(<<"admission">>, route(Db), <<"open">>) of
            <<"open">> -> ok; _ -> {error, quiescing} end;
        Error -> Error
    end.
require_open(Db) -> require(maps:get(<<"admission">>, route(Db), <<"open">>) =:= <<"open">>, quiescing).
require(true, _) -> ok;
require(false, Reason) -> throw({error, Reason}).
require_baseline(Db, Expected) -> require(ae_policy:same_baseline(route(Db), Expected), stale_routing).
now_ms() -> erlang:system_time(millisecond).
require_unexpired(Job) -> require(now_ms() < maps:get(<<"expires_at">>, Job), approval_expired).

register_manifest(Db, #{<<"digest">> := Digest} = Manifest) ->
    case rows(Db, "SELECT data FROM artifacts WHERE digest=?", [Digest]) of
        [] -> _ = sql(Db, "INSERT INTO artifacts VALUES(?,?)", [Digest, jsx:encode(Manifest)]), ok;
        [{Data}] -> require(jsx:decode(Data, [return_maps]) =:= Manifest, artifact_conflict), ok
    end.
initialize_registry(Db, Route) ->
    ok = register_manifest(Db, maps:get(<<"artifact">>, Route)),
    _ = sql(Db, "INSERT OR IGNORE INTO control VALUES('last_known_good',?)", [jsx:encode(Route)]), ok.
save_route(Db, Route) -> sql(Db, "UPDATE routing SET data=? WHERE id=1", [jsx:encode(Route)]).
save_job(Db, #{<<"id">> := Id, <<"status">> := Status} = Job) ->
    sql(Db, "INSERT OR REPLACE INTO deployments VALUES(?,?,?)", [Id, Status, jsx:encode(Job)]).
job(Db, Id) ->
    case rows(Db, "SELECT data FROM deployments WHERE id=?", [Id]) of
        [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
active_job(Db) ->
    case rows(Db, "SELECT data FROM deployments WHERE status NOT IN ('completed','rejected','rolled_back')", []) of
        [] -> undefined; [{Data}] -> jsx:decode(Data, [return_maps]) end.
require_job(Db, Id, Statuses) ->
    Job = job(Db, Id), require(is_map(Job), unknown_deployment),
    require(lists:member(maps:get(<<"status">>, Job), Statuses), invalid_deployment_state), Job.
checkpoint_data(Db, Id) ->
    case rows(Db, "SELECT data FROM checkpoints WHERE id=?", [Id]) of
        [{Data}] -> (jsx:decode(Data, [return_maps]))#{<<"checkpoint_id">> => Id};
        [] -> undefined end.
require_checkpoint(Db, Id) ->
    CP = checkpoint_data(Db, Id), require(is_map(CP), missing_checkpoint),
    require(maps:get(<<"schema_version">>, CP) =:= 1, incompatible_checkpoint),
    require(maps:get(<<"last_event_seq">>, CP) + 1 =:= last(Db), stale_checkpoint).
require_descriptor(Job, Descriptor, Which) ->
    {Slot, Manifest} = case Which of
        candidate -> {maps:get(<<"target_slot">>, Job), maps:get(<<"candidate">>, Job)};
        predecessor -> Base = maps:get(<<"baseline">>, Job),
            {maps:get(<<"slot">>, Base), maps:get(<<"artifact">>, Base)} end,
    require(maps:get(<<"slot">>, Descriptor) =:= Slot andalso
            maps:get(<<"artifact">>, Descriptor) =:= Manifest, wrong_runtime).
new_route(Expected, Descriptor, Checkpoint) ->
    Descriptor#{<<"epoch">> => maps:get(<<"epoch">>, Expected) + 1,
                <<"checkpoint_id">> => Checkpoint, <<"admission">> => <<"open">>}.
reject_job(Db, Id, Reason) ->
    Job = require_job(Db, Id, [<<"staging">>, <<"awaiting_approval">>, <<"approved">>, <<"quiescing">>]),
    case ae_policy:same_baseline(route(Db), maps:get(<<"baseline">>, Job)) of
        true -> save_route(Db, (route(Db))#{<<"admission">> => <<"open">>});
        false -> ok end,
    save_job(Db, Job#{<<"status">> := <<"rejected">>, <<"reason">> => Reason}),
    event(Db, <<"deployment_rejected">>, #{<<"deployment_id">> => Id, <<"reason">> => Reason}), ok.
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
        "status TEXT NOT NULL,result TEXT,PRIMARY KEY(request_id,key))",
    "CREATE TABLE IF NOT EXISTS tool_attempts(request_id TEXT NOT NULL,key TEXT NOT NULL,attempts INTEGER NOT NULL,"
        "PRIMARY KEY(request_id,key),FOREIGN KEY(request_id,key) REFERENCES tools(request_id,key))",
    "CREATE TABLE IF NOT EXISTS artifacts(digest TEXT PRIMARY KEY,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS checkpoints(id TEXT PRIMARY KEY,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS deployments(id TEXT PRIMARY KEY,status TEXT NOT NULL,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS control(name TEXT PRIMARY KEY,data TEXT NOT NULL)"
].
