-module(ae_telegram_normalize).
-export([normalize/3, authorized/2, session/3, admin/2]).

normalize(Update, Bot, Config) ->
    try
        Id = maps:get(<<"update_id">>, Update), true = is_integer(Id) andalso Id >= 0 andalso Id < (1 bsl 63) - 1,
        case maps:find(<<"callback_query">>, Update) of
            {ok, Callback} -> callback(Id, Callback, Bot, Config);
            error -> message(Id, maps:get(<<"message">>, Update), Bot, Config)
        end
    catch _:_ -> ignore end.

message(Id, M, Bot, Config) ->
    From = maps:get(<<"from">>, M), false = maps:get(<<"is_bot">>, From, false),
    N = route(Id, M, From, Bot), true = authorized(N, Config),
    Raw = maps:get(<<"text">>, M, maps:get(<<"caption">>, M, <<>>)),
    true = is_binary(Raw) andalso byte_size(Raw) =< 32768,
    Raw = unicode:characters_to_binary(Raw),
    Mention = <<"@", (maps:get(<<"username">>, Bot))/binary>>,
    Entities = maps:get(<<"entities">>, M, maps:get(<<"caption_entities">>, M, [])),
    Values = [entity(Raw, E) || E <- Entities, maps:get(<<"type">>, E, <<>>) =:= <<"mention">>],
    Named = [V || V <- Values, string:casefold(V) =:= string:casefold(Mention)],
    Direct = [W || W <- string:lexemes(Raw, " \t\r\n"), string:casefold(W) =:= string:casefold(Mention)],
    UserMentions = [ok || #{<<"type">> := <<"text_mention">>, <<"user">> := #{<<"id">> := User}} <- Entities,
        User =:= maps:get(<<"id">>, Bot)],
    Reply = maps:get(<<"reply_to_message">>, M, #{}),
    ReplyBot = maps:get(<<"id">>, maps:get(<<"from">>, Reply, #{}), undefined) =:= maps:get(<<"id">>, Bot),
    Addressed = maps:get(<<"chat_type">>, N) =:= <<"private">> orelse ReplyBot orelse Named ++ Direct ++ UserMentions =/= [],
    Text = string:trim(lists:foldl(fun(V, T) -> binary:replace(T, V, <<>>, [global]) end, Raw, Named ++ Direct)),
    {Command, Argument, Targeted} = command(Text, Bot),
    true = Addressed orelse Targeted,
    Photo = photo(M, Reply),
    case Command of
        none ->
            Prompt = case {Text, Photo} of {<<>>, P} when P =/= null -> <<"Describe the attached image.">>; _ -> Text end,
            true = byte_size(Prompt) > 0,
            {ok, N#{<<"kind">> => <<"turn">>, <<"text">> => Prompt, <<"photo_file_id">> => Photo}};
        _ -> {ok, N#{<<"kind">> => <<"command">>, <<"command">> => Command, <<"argument">> => Argument}}
    end.

command(Text, Bot) ->
    case string:lexemes(Text, " \t\r\n") of
        [<<"/", _/binary>> = First | _] ->
            [Name | Targets] = binary:split(First, <<"@">>),
            Targeted = case Targets of
                [] -> false;
                [Target] -> true = string:casefold(Target) =:= string:casefold(maps:get(<<"username">>, Bot)), true
            end,
            true = lists:member(Name, [<<"/help">>, <<"/start">>, <<"/status">>, <<"/providers">>, <<"/provider">>,
                <<"/models">>, <<"/model">>, <<"/think">>, <<"/settings">>, <<"/new">>, <<"/cancel">>, <<"/retry">>,
                <<"/memory">>, <<"/forget">>, <<"/restart">>]),
            {Name, string:trim(binary:part(Text, byte_size(First), byte_size(Text) - byte_size(First))), Targeted};
        _ -> {none, <<>>, false}
    end.

callback(Id, C, Bot, Config) ->
    From = maps:get(<<"from">>, C), false = maps:get(<<"is_bot">>, From, false),
    M = maps:get(<<"message">>, C), true = maps:get(<<"id">>, Bot) =:= maps:get(<<"id">>, maps:get(<<"from">>, M)),
    N = route(Id, M, From, Bot), true = authorized(N, Config),
    Data = maps:get(<<"data">>, C), true = is_binary(Data) andalso byte_size(Data) =< 64,
    <<"ae:", _/binary>> = Data,
    CallbackId = maps:get(<<"id">>, C), true = is_binary(CallbackId) andalso byte_size(CallbackId) =< 256,
    {ok, N#{<<"kind">> => <<"command">>, <<"command">> => <<"callback">>, <<"argument">> => Data,
        <<"callback_id">> => CallbackId}}.

route(Id, M, From, Bot) ->
    #{<<"id">> := Chat, <<"type">> := Type} = maps:get(<<"chat">>, M),
    User = maps:get(<<"id">>, From), Topic = maps:get(<<"message_thread_id">>, M, 0),
    true = is_integer(Chat) andalso Chat > -(1 bsl 63) andalso Chat < (1 bsl 63) andalso
        is_integer(User) andalso User > 0 andalso User < (1 bsl 63),
    true = is_integer(Topic) andalso Topic >= 0 andalso Topic < (1 bsl 63),
    BotId = maps:get(<<"id">>, Bot), Message = maps:get(<<"message_id">>, M), true = is_integer(Message),
    #{<<"bot_id">> => BotId, <<"update_id">> => Id, <<"chat_id">> => Chat, <<"user_id">> => User,
        <<"topic_id">> => Topic, <<"message_id">> => Message, <<"chat_type">> => Type,
        <<"session_id">> => session(BotId, Chat, Topic),
        <<"request_id">> => <<"tg:", (integer_to_binary(BotId))/binary, ":", (integer_to_binary(Id))/binary>>}.

session(Bot, Chat, Topic) ->
    <<"tg:", (integer_to_binary(Bot))/binary, ":", (integer_to_binary(Chat))/binary, ":", (integer_to_binary(Topic))/binary>>.
authorized(#{<<"chat_id">> := Chat, <<"user_id">> := User, <<"chat_type">> := Type}, Config) ->
    case Type of
        <<"private">> -> Chat =:= User andalso lists:member(User, maps:get(users, Config));
        T when T =:= <<"group">>; T =:= <<"supergroup">> -> Chat < 0 andalso lists:member(Chat, maps:get(groups, Config));
        _ -> false
    end.
admin(#{<<"chat_type">> := <<"private">>, <<"user_id">> := Id} = Route, Config) ->
    authorized(Route, Config) andalso lists:member(Id, maps:get(admins, Config));
admin(_, _) -> false.
entity(Text, #{<<"offset">> := Offset, <<"length">> := Length})
        when is_integer(Offset), Offset >= 0, is_integer(Length), Length >= 0 ->
    UTF16 = unicode:characters_to_binary(Text, utf8, {utf16, little}),
    case (Offset + Length) * 2 =< byte_size(UTF16) of
        true -> case unicode:characters_to_binary(binary:part(UTF16, Offset * 2, Length * 2), {utf16, little}, utf8) of
            B when is_binary(B) -> B; _ -> <<>> end;
        false -> <<>> end;
entity(_, _) -> <<>>.
photo(Message, Reply) ->
    Photos = maps:get(<<"photo">>, Message, maps:get(<<"photo">>, Reply, [])),
    case Photos of
        [] -> null;
        _ when length(Photos) =< 32 ->
            File = maps:get(<<"file_id">>, lists:last(Photos)),
            true = is_binary(File) andalso byte_size(File) > 0 andalso byte_size(File) =< 512, File
    end.
