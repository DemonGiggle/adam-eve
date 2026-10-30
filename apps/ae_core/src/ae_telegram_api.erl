-module(ae_telegram_api).
-export([call/3, send/3, typing/2, photo/2, commands/0]).

call(Config, Method, Body) ->
    case token(Config) of
        {ok, Token} ->
            Url = maps:get(base_url, Config) ++ "/bot" ++ binary_to_list(Token) ++ "/" ++ binary_to_list(Method),
            Timeout = case Method of <<"getUpdates">> -> (maps:get(poll_seconds, Config) + 10) * 1000; _ -> 15000 end,
            case ae_http:json(post, Url, [], Body, Timeout) of
                {ok, 200, #{<<"ok">> := true, <<"result">> := Result}} -> {ok, Result};
                {ok, _, #{<<"error_code">> := Code} = Reply} ->
                    Delay = maps:get(<<"retry_after">>, maps:get(<<"parameters">>, Reply, #{}), 0),
                    Safe = case is_integer(Delay) andalso Delay > 0 andalso Delay =< 86400 of true -> Delay; false -> 0 end,
                    {error, {telegram, Code, Safe}};
                _ -> {error, telegram_unavailable}
            end;
        Error -> Error
    end.
token(Config) ->
    case ae_credentials:resolve(maps:get(token_env, Config), maps:get(token_path, Config)) of
        {ok, T} ->
            case re:run(T, <<"^[0-9]+:[A-Za-z0-9_-]+$">>, [{capture, none}]) of
                match -> {ok, T}; _ -> {error, invalid_bot_token} end;
        Error -> Error
    end.

send(Config, Route, #{<<"text">> := Text} = Message) ->
    Base = route(Route),
    Extras = maps:with([<<"reply_markup">>], Message),
    Payload = maps:merge(Base#{<<"text">> => ae_telegram_format:html(Text), <<"parse_mode">> => <<"HTML">>,
        <<"link_preview_options">> => #{<<"is_disabled">> => true}}, Extras),
    case call(Config, <<"sendMessage">>, Payload) of
        {error, {telegram, 400, _}} ->
            %% A rejected 400 has not delivered a message. Plain text preserves
            %% every original byte if Telegram rejects the Markdown subset.
            call(Config, <<"sendMessage">>, maps:remove(<<"parse_mode">>, Payload#{<<"text">> := Text}));
        Result -> Result
    end.
typing(Config, Route) -> call(Config, <<"sendChatAction">>, (route(Route))#{<<"action">> => <<"typing">>}).
route(#{<<"chat_id">> := Chat, <<"topic_id">> := Topic}) ->
    Base = #{<<"chat_id">> => Chat},
    case Topic of 0 -> Base; _ -> Base#{<<"message_thread_id">> => Topic} end.

photo(Config, FileId) ->
    case call(Config, <<"getFile">>, #{<<"file_id">> => FileId}) of
        {ok, #{<<"file_path">> := Path} = File} ->
            try
                true = is_binary(Path) andalso byte_size(Path) =< 1024,
                nomatch = binary:match(Path, [<<"..">>, <<":">>, <<"?">>, <<"#">>, <<"\\">>]),
                true = binary:first(Path) =/= $/,
                true = maps:get(<<"file_size">>, File, 0) =< 2097152,
                {ok, Token} = token(Config),
                Url = maps:get(base_url, Config) ++ "/file/bot" ++ binary_to_list(Token) ++ "/" ++ binary_to_list(Path),
                {ok, 200, Bytes} = ae_http:request(get, Url, [], <<>>, 15000, 2097152),
                Mime = mime(Bytes),
                {ok, [#{<<"mime">> => Mime, <<"data_base64">> => base64:encode(Bytes)}]}
            catch _:_ -> {error, invalid_or_oversized_photo} end;
        _ -> {error, photo_unavailable}
    end.
mime(<<16#FF, 16#D8, 16#FF, _/binary>>) -> <<"image/jpeg">>;
mime(<<137, "PNG\r\n", 26, "\n", _/binary>>) -> <<"image/png">>;
mime(<<"GIF8", _/binary>>) -> <<"image/gif">>;
mime(<<"RIFF", _:4/binary, "WEBP", _/binary>>) -> <<"image/webp">>.

commands() -> [#{<<"command">> => C, <<"description">> => D} || {C, D} <- [
    {<<"help">>, <<"Show commands">>}, {<<"status">>, <<"Show agent and chat status">>},
    {<<"provider">>, <<"Choose this chat's provider">>}, {<<"models">>, <<"Choose a model">>},
    {<<"model">>, <<"Set this chat's model">>}, {<<"think">>, <<"Set thinking effort or auto">>},
    {<<"settings">>, <<"Show or reset chat settings">>}, {<<"new">>, <<"Start fresh topic context">>},
    {<<"cancel">>, <<"Cancel this topic's pending requests">>}, {<<"retry">>, <<"Explicitly retry a failed request">>},
    {<<"memory">>, <<"Show this chat's memory">>}, {<<"forget">>, <<"Clear this chat's memory">>},
    {<<"restart">>, <<"Restart the active agent (private admin only)">>}]].
