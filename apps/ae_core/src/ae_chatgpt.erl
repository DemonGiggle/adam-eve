-module(ae_chatgpt).
-include_lib("kernel/include/file.hrl").
-export([begin_login/1, finish_login/3, headers/1, models/2, complete/3, path/1]).

%% Console-only PKCE compatibility flow, following q-agent's subscription
%% adapter. No authorization URL, callback or credential is accepted in chat.
path(#{oauth_path := P}) when P =/= <<>> -> P;
path(_) -> list_to_binary(filename:join([os:getenv("HOME"), ".config", "adam-eve", "chatgpt-oauth.json"])).
begin_login(P) ->
    Verifier = b64(crypto:strong_rand_bytes(32)), State = b64(crypto:strong_rand_bytes(32)),
    Query = [{"client_id", binary_to_list(maps:get(client_id, P))}, {"response_type", "code"},
        {"redirect_uri", redirect()}, {"scope", "openid profile email offline_access"},
        {"code_challenge", binary_to_list(b64(crypto:hash(sha256, Verifier)))},
        {"code_challenge_method", "S256"}, {"state", binary_to_list(State)}],
    {<<(maps:get(oauth_authorize_url, P))/binary, "?", (list_to_binary(uri_string:compose_query(Query)))/binary>>,
        #{verifier => Verifier, state => State, expires_at => erlang:system_time(second) + 600}}.

finish_login(P, #{verifier := Verifier, state := State, expires_at := Expires}, Callback) ->
    try
        true = erlang:system_time(second) < Expires,
        #{scheme := "http", host := "localhost", port := 1455, path := "/auth/callback", query := Q} =
            uri_string:parse(binary_to_list(string:trim(Callback))),
        Query = uri_string:dissect_query(Q),
        true = length([ok || {"state", _} <- Query]) =:= 1,
        true = length([ok || {"code", _} <- Query]) =:= 1,
        State = list_to_binary(proplists:get_value("state", Query)),
        false = lists:keymember("error", 1, Query),
        Code = proplists:get_value("code", Query), true = Code =/= "",
        case token(P, [{"grant_type", "authorization_code"}, {"code", Code},
                {"redirect_uri", redirect()}, {"code_verifier", binary_to_list(Verifier)}]) of
            {ok, Tokens} -> save(path(P), Tokens);
            Error -> Error
        end
    catch _:_ -> {error, invalid_oauth_callback} end.

headers(P) ->
    case credentials(P, false) of
        {ok, T} -> {ok, auth_headers(T)};
        Error -> Error
    end.
credentials(P, Force) ->
    global:trans({{?MODULE, path(P)}, self()}, fun() ->
        case ae_credentials:read(path(P)) of
            {ok, Data} ->
                try
                    T = jsx:decode(Data, [return_maps, strict]),
                    Access = maps:get(<<"access_token">>, T), true = bearer(Access),
                    Expires = maps:get(<<"expires_at">>, T), true = is_integer(Expires),
                    case (Force =/= false andalso Force =:= Access) orelse Expires =< erlang:system_time(second) + 300 of
                        false -> {ok, T};
                        true ->
                            Refresh = maps:get(<<"refresh_token">>, T), true = bearer(Refresh),
                            case token(P, [{"grant_type", "refresh_token"}, {"refresh_token", binary_to_list(Refresh)}]) of
                                {ok, Fresh} ->
                                    Merged = maps:merge(T, Fresh),
                                    case save(path(P), Merged) of ok -> {ok, Merged}; Error -> Error end;
                                Error -> Error
                            end
                    end
                catch _:_ -> {error, chatgpt_login_required} end;
            _ -> {error, chatgpt_login_required}
        end
    end).

token(P, Fields) ->
    Endpoint = binary_to_list(maps:get(oauth_token_url, P)),
    Body = list_to_binary(uri_string:compose_query([{"client_id", binary_to_list(maps:get(client_id, P))} | Fields])),
    case ae_http:request(post, Endpoint, [], Body, 15000, 65536, "application/x-www-form-urlencoded") of
        {ok, 200, Data} ->
            try
                R = jsx:decode(Data, [return_maps, strict]),
                true = bearer(maps:get(<<"access_token">>, R)),
                Seconds = maps:get(<<"expires_in">>, R), true = is_integer(Seconds) andalso Seconds > 0,
                Account = account(maps:get(<<"id_token">>, R, maps:get(<<"access_token">>, R))),
                Clean = maps:with([<<"access_token">>, <<"refresh_token">>], R),
                Identity = case Account of <<>> -> #{}; _ -> #{<<"account_id">> => Account} end,
                {ok, maps:merge(Clean#{<<"expires_at">> => erlang:system_time(second) + Seconds}, Identity)}
            catch _:_ -> {error, invalid_oauth_response} end;
        _ -> {error, oauth_exchange_failed}
    end.

save(Path, T) ->
    try
        absolute = filename:pathtype(Path), ok = filelib:ensure_dir(Path), ok = ae_credentials:check_parent(Path),
        case file:read_link_info(Path) of {error, enoent} -> ok; {ok, _} -> {ok, _} = ae_credentials:read(Path) end,
        Parent = filename:dirname(Path), {ok, ParentInfo} = file:read_link_info(Parent),
        true = ParentInfo#file_info.type =:= directory andalso ParentInfo#file_info.mode band 8#022 =:= 0,
        {ok, Owner} = file:read_file_info(<<"/proc/self">>), true = ParentInfo#file_info.uid =:= Owner#file_info.uid,
        Temp = <<Path/binary, ".", (b64(crypto:strong_rand_bytes(12)))/binary>>,
        try
            {ok, F} = file:open(Temp, [raw, binary, write, exclusive]),
            try ok = file:change_mode(Temp, 8#600), ok = file:write(F, jsx:encode(T)), ok = file:sync(F)
            after file:close(F) end,
            ok = file:rename(Temp, Path),
            {ok, _} = ae_os:run("/usr/bin/python3", ["-I", "-c",
                "import os,sys; f=os.open(sys.argv[1],os.O_RDONLY|os.O_DIRECTORY); os.fsync(f); os.close(f)", binary_to_list(Parent)], 2000),
            ok
        after file:delete(Temp) end
    catch _:_ -> {error, oauth_storage_failed} end.

complete(_, _, {budget, _}) -> {error, subscription_authoring_not_supported};
complete(Messages, Config, ordinary) ->
    P = ae_llm:profile(Config),
    case credentials(P, false) of
        {ok, T} -> infer(Messages, Config, P, T, false);
        Error -> Error
    end.
infer(Messages, Config, P, T, Retried) ->
    Systems = [Text || #{<<"role">> := <<"system">>, <<"content">> := Text} <- Messages],
    Rest = [M || #{<<"role">> := Role} = M <- Messages, Role =/= <<"system">>],
    Instructions = case Systems of [] -> <<"You are the user's assistant.">>; _ -> iolist_to_binary(lists:join(<<"\n\n">>, Systems)) end,
    Body = maps:merge(#{<<"model">> => maps:get(model, P), <<"input">> => Rest,
        <<"instructions">> => Instructions, <<"store">> => false, <<"stream">> => true}, ae_llm_api:thinking(responses, P)),
    case ae_http:request(post, maps:get(url, P) ++ "/responses", auth_headers(T), jsx:encode(Body),
                         maps:get(llm_timeout, Config), 4194304) of
        {ok, 200, Data} -> stream(Data);
        {ok, 401, _} when Retried =:= false ->
            case credentials(P, maps:get(<<"access_token">>, T)) of {ok, Fresh} -> infer(Messages, Config, P, Fresh, true); Error -> Error end;
        {ok, Code, _} when Code =:= 401; Code =:= 403 -> {error, provider_authentication_failed};
        {ok, 429, _} -> {error, provider_rate_limited};
        _ -> {error, provider_unavailable}
    end.
stream(Data) ->
    try
        Events = [jsx:decode(string:trim(JSON), [return_maps, strict]) || <<"data:", JSON/binary>> <- binary:split(Data, <<"\n">>, [global]),
            string:trim(JSON) =/= <<"[DONE]">>],
        [] = [E || #{<<"type">> := Type} = E <- Events,
            Type =:= <<"error">> orelse Type =:= <<"response.failed">> orelse Type =:= <<"response.incomplete">>],
        [Response] = [R || #{<<"type">> := <<"response.completed">>, <<"response">> := R} <- Events],
        ae_llm_api:normalize(responses, Response, ordinary, undefined, undefined)
    catch _:_ -> {error, invalid_provider_response} end.

models(P, Timeout) ->
    case headers(P) of
        {ok, H} ->
            case ae_http:json(get, maps:get(url, P) ++ "/models?client_version=1.0.0", H, #{}, min(Timeout, 15000)) of
                {ok, 200, #{<<"models">> := Items}} when length(Items) =< 4096 ->
                    {ok, [#{<<"id">> => maps:get(<<"slug">>, I), <<"metadata">> => maps:with(
                        [<<"supported_reasoning_levels">>, <<"default_reasoning_level">>, <<"context_window">>], I)} || I <- Items,
                        maps:get(<<"visibility">>, I, <<"list">>) =:= <<"list">>]};
                {ok, Code, _} when Code =:= 401; Code =:= 403 -> {error, provider_authentication_failed};
                _ -> {error, provider_models_unavailable}
            end;
        Error -> Error
    end.
auth_headers(T) ->
    Base = [{"authorization", "Bearer " ++ binary_to_list(maps:get(<<"access_token">>, T))}],
    case maps:get(<<"account_id">>, T, <<>>) of
        <<>> -> Base;
        Account -> true = bearer(Account), [{"ChatGPT-Account-Id", binary_to_list(Account)} | Base]
    end.
account(JWT) ->
    try
        [_, Encoded, _] = binary:split(JWT, <<".">>, [global]),
        Pad = binary:copy(<<"=">>, (4 - byte_size(Encoded) rem 4) rem 4),
        Payload = binary:replace(binary:replace(Encoded, <<"-">>, <<"+">>, [global]), <<"_">>, <<"/">>, [global]),
        Claims = jsx:decode(base64:decode(<<Payload/binary, Pad/binary>>), [return_maps]),
        maps:get(<<"chatgpt_account_id">>, maps:get(<<"https://api.openai.com/auth">>, Claims, #{}), <<>>)
    catch _:_ -> <<>> end.
bearer(V) -> is_binary(V) andalso byte_size(V) > 0 andalso byte_size(V) =< 16384 andalso
    binary:match(V, [<<"\r">>, <<"\n">>, <<0>>]) =:= nomatch.
b64(B) -> binary:replace(binary:replace(binary:replace(base64:encode(B), <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]), <<"=">>, <<>>, [global]).
redirect() -> "http://localhost:1455/auth/callback".
