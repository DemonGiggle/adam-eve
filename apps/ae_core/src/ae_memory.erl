-module(ae_memory).
-export([schema/0, dispatch/2, context/2]).

%% Called inside ae_store's transaction. Values are data with immutable source
%% references; only the operator API writes them. Agent capabilities do not grow.
dispatch(Db, head) ->
    [{Revision}] = ae_sql:rows(Db, "SELECT COALESCE(MAX(revision),0) FROM memory_versions", []), Revision;
dispatch(Db, {pin, Request}) ->
    ae_sql:exec(Db, "INSERT INTO turn_memory VALUES(?,?)", [Request, dispatch(Db, head)]), ok;
dispatch(Db, {put, Origin, Kind, Key, Value, Sources, Expected}) ->
    write(Db, Origin, Kind, Key, Value, Sources, Expected, false);
dispatch(Db, {delete, Origin, Kind, Key, Sources, Expected}) ->
    write(Db, Origin, Kind, Key, null, Sources, Expected, true);
dispatch(Db, {get, Kind, Key, At}) ->
    need(kind(Kind) andalso text(Key, 128), invalid_memory_key), Revision = revision(Db, At),
    case ae_sql:rows(Db, "SELECT data FROM memory_versions WHERE kind=? AND key=? AND revision<=? "
        "ORDER BY revision DESC LIMIT 1", [Kind, Key, Revision]) of
        [] -> {error, unknown_memory};
        [{Encoded}] -> {ok, jsx:decode(Encoded, [return_maps])}
    end;
dispatch(Db, {snapshot, At, Offset, Count}) ->
    need(is_integer(Offset) andalso Offset >= 0 andalso Offset < (1 bsl 63) andalso
        is_integer(Count) andalso Count > 0 andalso Count =< 32, invalid_memory_range),
    Revision = revision(Db, At),
    Rows = ae_sql:rows(Db, "SELECT m.data FROM memory_versions m WHERE m.revision<=? AND m.deleted=0 "
        "AND NOT EXISTS(SELECT 1 FROM memory_versions n WHERE n.kind=m.kind AND n.key=m.key "
        "AND n.revision<=? AND n.revision>m.revision) ORDER BY m.revision DESC LIMIT ? OFFSET ?",
        [Revision, Revision, Count + 1, Offset]),
    Records = [jsx:decode(Data, [return_maps]) || {Data} <- Rows],
    Entries = page(lists:sublist(Records, Count), [], 0),
    {ok, #{<<"revision">> => Revision, <<"entries">> => Entries, <<"offset">> => Offset,
        <<"next_offset">> => Offset + length(Entries), <<"eof">> => length(Records) =:= length(Entries)}};
dispatch(Db, {scoped, Prefix, At, Offset, Count}) ->
    need(is_binary(Prefix) andalso byte_size(Prefix) > 0 andalso is_integer(Offset) andalso Offset >= 0 andalso
        is_integer(Count) andalso Count > 0 andalso Count =< 32, invalid_memory_range),
    Revision = revision(Db, At),
    Rows = ae_sql:rows(Db, "SELECT m.data FROM memory_versions m WHERE m.revision<=? AND m.deleted=0 "
        "AND substr(m.key,1,length(?))=? AND NOT EXISTS(SELECT 1 FROM memory_versions n "
        "WHERE n.kind=m.kind AND n.key=m.key AND n.revision<=? AND n.revision>m.revision) "
        "ORDER BY m.revision DESC LIMIT ? OFFSET ?", [Revision, Prefix, Prefix, Revision, Count + 1, Offset]),
    Records = [jsx:decode(Data, [return_maps]) || {Data} <- Rows],
    Entries = page(lists:sublist(Records, Count), [], 0),
    {ok, #{<<"revision">> => Revision, <<"entries">> => Entries, <<"offset">> => Offset,
        <<"next_offset">> => Offset + length(Entries), <<"eof">> => length(Records) =:= length(Entries)}};
dispatch(Db, checkpoint) ->
    Revision = dispatch(Db, head),
    Ref = case ae_sql:rows(Db, "SELECT m.revision FROM memory_versions m WHERE m.kind='summary' AND m.deleted=0 "
        "AND NOT EXISTS(SELECT 1 FROM memory_versions n WHERE n.kind=m.kind AND n.key=m.key AND n.revision>m.revision) "
        "ORDER BY m.revision DESC LIMIT 1", []) of
        [] -> null;
        [{First}] -> <<"memory-summary:", (integer_to_binary(First))/binary>> end,
    #{<<"memory_revision">> => Revision, <<"context_summary_ref">> => Ref};
dispatch(_, _) -> {error, invalid_memory_command}.

context(Db, Request) ->
    %% Legacy turns predate semantic memory and retain revision zero. A memory
    %% update between memory_read and llm cannot alter an admitted turn's input.
    Revision = case ae_sql:rows(Db, "SELECT revision FROM turn_memory WHERE request_id=?", [Request]) of
        [] -> 0; [{Saved}] -> Saved end,
    [{Session}] = ae_sql:rows(Db, "SELECT session_id FROM turns WHERE request_id=?", [Request]),
    Query = case ae_sessions:scope(Session) of
        undefined -> {snapshot, Revision, 0, 32}; Prefix -> {scoped, Prefix, Revision, 0, 32} end,
    {ok, Snapshot} = dispatch(Db, Query), Snapshot.

write(Db, Origin, Kind, Key, Value, Sources, Expected, Deleted) ->
    need(text(Origin, 256) andalso kind(Kind) andalso text(Key, 128), invalid_memory_key),
    need((Deleted andalso Value =:= null) orelse text(Value, 4096), invalid_memory_value),
    need(is_integer(Expected) andalso Expected >= 0 andalso Expected < (1 bsl 63), invalid_memory_revision),
    need(is_list(Sources) andalso length(Sources) > 0 andalso length(Sources) =< 16 andalso
        lists:all(fun(N) -> is_integer(N) andalso N > 0 andalso N < (1 bsl 63) end, Sources) andalso
        length(lists:usort(Sources)) =:= length(Sources), invalid_memory_sources),
    Input = #{<<"origin_ref">> => Origin, <<"kind">> => Kind, <<"key">> => Key, <<"value">> => Value,
        <<"source_event_seqs">> => lists:sort(Sources), <<"expected_revision">> => Expected, <<"deleted">> => Deleted},
    Fingerprint = ae_policy:digest(Input),
    case ae_sql:rows(Db, "SELECT fingerprint,revision FROM memory_requests WHERE origin_ref=?", [Origin]) of
        [{Fingerprint, Saved}] ->
            [{Data}] = ae_sql:rows(Db, "SELECT data FROM memory_versions WHERE revision=?", [Saved]),
            {ok, jsx:decode(Data, [return_maps])};
        [_] -> {error, memory_origin_conflict};
        [] -> commit(Db, Input, Fingerprint)
    end.

commit(Db, #{<<"expected_revision">> := Expected, <<"kind">> := Kind, <<"key">> := Key,
             <<"origin_ref">> := Origin, <<"deleted">> := Deleted, <<"source_event_seqs">> := Sources} = Input, Fingerprint) ->
    need(not ae_sql:recovery_pending(Db), restore_verification_required),
    case ae_sql:rows(Db, "SELECT data FROM routing WHERE id=1", []) of
        [{Route}] -> need(maps:get(<<"admission">>, jsx:decode(Route, [return_maps]), <<"open">>) =:= <<"open">>, quiescing);
        [] -> need(false, identity_not_initialized)
    end,
    need(dispatch(Db, head) =:= Expected, memory_revision_conflict),
    lists:foreach(fun(Seq) -> need(ae_sql:rows(Db, "SELECT seq FROM events WHERE seq=?", [Seq]) =/= [], unknown_source_event) end, Sources),
    case Deleted of
        true ->
            case dispatch(Db, {get, Kind, Key, Expected}) of
                {ok, Previous} -> need(not maps:get(<<"deleted">>, Previous), memory_already_deleted);
                {error, Why} -> need(false, Why)
            end;
        false -> ok
    end,
    Revision = Expected + 1, Record = (maps:remove(<<"expected_revision">>, Input))#{<<"revision">> => Revision},
    Seq = ae_sql:event(Db, <<"memory_updated">>, Record),
    Saved = Record#{<<"event_seq">> => Seq},
    ae_sql:exec(Db, "INSERT INTO memory_versions VALUES(?,?,?,?,?,?)", [Revision, Kind, Key,
        case Deleted of true -> 1; false -> 0 end, Seq, jsx:encode(Saved)]),
    ae_sql:exec(Db, "INSERT INTO memory_requests VALUES(?,?,?)", [Origin, Fingerprint, Revision]),
    {ok, Saved}.

revision(Db, null) -> dispatch(Db, head);
revision(Db, N) ->
    need(is_integer(N) andalso N >= 0 andalso N =< dispatch(Db, head), invalid_memory_revision), N.
page([], Acc, _) -> lists:reverse(Acc);
page([First | Rest], Acc, Bytes) ->
    Size = byte_size(jsx:encode(First)) + 1,
    case Bytes + Size =< 32768 of
        true -> page(Rest, [First | Acc], Bytes + Size);
        false -> lists:reverse(Acc)
    end.
kind(Value) -> lists:member(Value, [<<"fact">>, <<"preference">>, <<"summary">>]).
text(Value, Max) -> is_binary(Value) andalso byte_size(Value) > 0 andalso byte_size(Value) =< Max andalso
    unicode:characters_to_binary(Value) =:= Value.
need(true, _) -> ok;
need(false, Why) -> throw({error, Why}).

schema() -> [
    "CREATE TABLE IF NOT EXISTS memory_versions(revision INTEGER PRIMARY KEY,kind TEXT NOT NULL,key TEXT NOT NULL,"
        "deleted INTEGER NOT NULL CHECK(deleted IN(0,1)),event_seq INTEGER NOT NULL REFERENCES events(seq),data TEXT NOT NULL)",
    "CREATE INDEX IF NOT EXISTS memory_lookup ON memory_versions(kind,key,revision DESC)",
    "CREATE TABLE IF NOT EXISTS memory_requests(origin_ref TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,"
        "revision INTEGER NOT NULL REFERENCES memory_versions(revision))",
    "CREATE TABLE IF NOT EXISTS turn_memory(request_id TEXT PRIMARY KEY REFERENCES turns(request_id),revision INTEGER NOT NULL)"
].
