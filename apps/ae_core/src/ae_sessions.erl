-module(ae_sessions).
-export([schema/0, initialize/1, dispatch/2, pin/4, turn/2, context_start/2, scope/1]).

schema() -> [
    "CREATE TABLE IF NOT EXISTS sessions(session_id TEXT PRIMARY KEY,data TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS turn_settings(request_id TEXT PRIMARY KEY REFERENCES turns(request_id),data TEXT NOT NULL)"
].

initialize(Db) ->
    case ae_sql:rows(Db, "SELECT data FROM control WHERE name='session_pin_from_seq'", []) of
        [] ->
            [{Last}] = ae_sql:rows(Db, "SELECT COALESCE(MAX(seq),0) FROM events", []),
            ae_sql:exec(Db, "INSERT INTO control VALUES('session_pin_from_seq',?)", [jsx:encode(Last + 1)]), ok;
        _ -> ok
    end.

dispatch(Db, {get, Session}) ->
    valid_session(Session),
    Preferences = stored(Db, settings_id(Session)), Context = stored(Db, Session),
    Preferences#{<<"context_start">> => maps:get(<<"context_start">>, Context, 0)};
dispatch(Db, {set, Session, Selection}) ->
    valid_session(Session), valid_selection(Selection),
    Current = stored(Db, settings_id(Session)),
    Next = Selection#{<<"context_start">> => maps:get(<<"context_start">>, Current, 0)},
    save(Db, settings_id(Session), Next), ae_sql:event(Db, <<"session_settings_changed">>, #{<<"session_id">> => Session, <<"settings">> => Next}),
    {ok, dispatch(Db, {get, Session})};
dispatch(Db, {reset, Session}) ->
    valid_session(Session), Current = stored(Db, Session),
    Seq = ae_sql:event(Db, <<"session_context_reset">>, #{<<"session_id">> => Session}),
    Next = Current#{<<"context_start">> => Seq}, save(Db, Session, Next), {ok, dispatch(Db, {get, Session})};
dispatch(Db, {turn, Request}) -> turn(Db, Request).

pin(Db, Request, Session, Catalog) ->
    Preferences = dispatch(Db, {get, Session}),
    Selection = case maps:find(<<"providers">>, Catalog) of
        error -> #{};
        {ok, Profiles} ->
            Name = maps:get(<<"provider">>, Preferences, maps:get(<<"default_provider">>, Catalog)),
            Base = case maps:find(Name, Profiles) of
                {ok, Profile} -> Profile;
                error -> throw({error, provider_not_configured}) end,
            maps:merge(Base, maps:with([<<"provider">>, <<"model">>, <<"thinking">>], Preferences))
    end,
    Data = Selection#{<<"context_start">> => maps:get(<<"context_start">>, Preferences)},
    ae_sql:exec(Db, "INSERT INTO turn_settings VALUES(?,?)", [Request, jsx:encode(Data)]), ok.

turn(Db, Request) ->
    case ae_sql:rows(Db, "SELECT data FROM turn_settings WHERE request_id=?", [Request]) of
        [] -> #{};
        [{Data}] -> jsx:decode(Data, [return_maps])
    end.
context_start(Db, Request) -> maps:get(<<"context_start">>, turn(Db, Request), 0).

scope(<<"tg:", _/binary>> = Session) ->
    case binary:split(Session, <<":">>, [global]) of
        [<<"tg">>, Bot, Chat, _Topic] -> <<"tg:", Bot/binary, ":", Chat/binary, ":">>;
        _ -> <<"tg:invalid:">>
    end;
scope(_) -> undefined.

settings_id(Session) -> case scope(Session) of undefined -> Session; Prefix -> <<Prefix/binary, "settings">> end.
stored(Db, Session) ->
    case ae_sql:rows(Db, "SELECT data FROM sessions WHERE session_id=?", [Session]) of
        [] -> #{}; [{Data}] -> jsx:decode(Data, [return_maps])
    end.

save(Db, Session, Data) -> ae_sql:exec(Db, "INSERT OR REPLACE INTO sessions VALUES(?,?)", [Session, jsx:encode(Data)]).
valid_session(S) when is_binary(S), byte_size(S) > 0, byte_size(S) =< 256 -> ok;
valid_session(_) -> throw({error, invalid_session}).
valid_selection(S) when is_map(S), map_size(S) =< 3 ->
    true_or_error(lists:all(fun({K, V}) -> lists:member(K, [<<"provider">>, <<"model">>, <<"thinking">>])
        andalso is_binary(V) andalso byte_size(V) =< 256 end, maps:to_list(S)));
valid_selection(_) -> throw({error, invalid_session_settings}).
true_or_error(true) -> ok;
true_or_error(false) -> throw({error, invalid_session_settings}).
