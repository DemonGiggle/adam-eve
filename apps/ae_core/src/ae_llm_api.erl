-module(ae_llm_api).
-export([complete/3, models/2, headers/1, thinking/2, normalize/5]).

complete(Messages, Config, Mode) ->
    try
        Profile = ae_llm:profile(Config),
        {InputLimit, OutputLimit} = limits(Mode, Config),
        case InputLimit of
            undefined -> ok;
            _ -> true = byte_size(jsx:encode(Messages)) + 256 * length(Messages) + 1024 =< InputLimit
        end,
        Wire = route(Profile),
        {Url, Body} = body(Wire, Messages, Profile, OutputLimit, Mode),
        case headers(Profile) of
            {ok, Headers} ->
                Timeout = maps:get(llm_timeout, Config),
                case ae_http:json(post, Url, Headers, Body, Timeout) of
                    {ok, 200, Reply} -> normalize(Wire, Reply, Mode, InputLimit, OutputLimit);
                    {ok, 401, _} -> {error, provider_authentication_failed};
                    {ok, 403, _} -> {error, provider_authentication_failed};
                    {ok, 429, _} -> {error, provider_rate_limited};
                    {ok, _, _} -> {error, provider_response_rejected};
                    _ -> {error, provider_unavailable}
                end;
            Error -> Error
        end
    catch _:_ -> {error, invalid_provider_response} end.

limits(ordinary, Config) -> {undefined, maps:get(max_tokens, Config)};
limits({budget, Tokens}, _) when is_integer(Tokens), Tokens >= 2 -> {Tokens div 2, Tokens - Tokens div 2}.
route(P) ->
    Routes = maps:get(model_routes, P, #{}),
    case maps:get(maps:get(model, P), Routes, undefined) of
        <<"responses">> -> responses;
        <<"messages">> -> messages;
        <<"chat_completions">> -> chat_completions;
        undefined -> maps:get(wire, P)
    end.

body(responses, Messages, #{url := Base, model := Model} = P, Output, Mode) ->
    B = #{<<"model">> => Model, <<"input">> => Messages, <<"store">> => false,
        <<"stream">> => false, <<"max_output_tokens">> => Output},
    {Base ++ "/responses", format(maps:merge(B, thinking(responses, P)), responses, Mode)};
body(chat_completions, Messages, #{url := Base, model := Model} = P, Output, Mode) ->
    B = #{<<"model">> => Model, <<"messages">> => Messages, <<"stream">> => false,
        <<"max_completion_tokens">> => Output},
    {Base ++ "/chat/completions", format(maps:merge(B, thinking(chat_completions, P)), chat_completions, Mode)};
body(messages, Messages, #{url := Base, model := Model} = P, Output, _Mode) ->
    Systems = [Text || #{<<"role">> := <<"system">>, <<"content">> := Text} <- Messages],
    Rest = [M || #{<<"role">> := Role} = M <- Messages, Role =/= <<"system">>],
    B = #{<<"model">> => Model, <<"messages">> => Rest, <<"max_tokens">> => Output,
        <<"stream">> => false, <<"system">> => iolist_to_binary(lists:join(<<"\n\n">>, Systems))},
    {Base ++ "/messages", maps:merge(B, thinking(messages, P))}.

format(Body, _, ordinary) -> Body;
format(Body, responses, {budget, _}) -> Body#{<<"text">> => #{<<"format">> => #{<<"type">> => <<"json_object">>}}};
format(Body, chat_completions, {budget, _}) -> Body#{<<"response_format">> => #{<<"type">> => <<"json_object">>}}.

thinking(_, #{thinking := Level}) when Level =:= <<>>; Level =:= <<"auto">> -> #{};
thinking(responses, #{thinking := Level}) -> #{<<"reasoning">> => #{<<"effort">> => Level}};
thinking(chat_completions, #{thinking := Level}) -> #{<<"reasoning_effort">> => Level};
thinking(messages, _) -> error(thinking_not_supported).

headers(Profile) ->
    case ae_credentials:resolve(maps:get(api_key_env, Profile), maps:get(api_key_path, Profile)) of
        {ok, Key} ->
            Adapter = maps:get(adapter, Profile),
            Auth = case Key of
                <<>> -> [];
                _ when Adapter =:= anthropic -> [{"x-api-key", binary_to_list(Key)}];
                _ -> [{"authorization", "Bearer " ++ binary_to_list(Key)}]
            end,
            Extra = case Adapter of
                opencode_go -> [{"user-agent", "adam-eve/0.1"}, {"x-opencode-session", binary_to_list(maps:get(session_id, Profile))}];
                anthropic -> [{"anthropic-version", "2023-06-01"}];
                _ -> [] end,
            {ok, Auth ++ Extra};
        Error -> Error
    end.

normalize(Wire, Reply, Mode, InputLimit, OutputLimit) ->
    {Text, Input, Output, Done} = decode(Wire, Reply),
    true = is_binary(Text) andalso byte_size(Text) > 0 andalso byte_size(Text) =< 65536 andalso Done,
    case Mode of
        ordinary -> {ok, #{<<"text">> => Text}};
        {budget, _} when is_integer(Input), Input >= 0, is_integer(Output), Output >= 0 ->
            case Input =< InputLimit andalso Output =< OutputLimit of
                true -> {ok, #{<<"text">> => Text, <<"input_tokens">> => Input, <<"output_tokens">> => Output}};
                false -> {error, provider_budget_violation}
            end;
        _ -> {error, provider_usage_missing}
    end.
decode(responses, R) ->
    Text = iolist_to_binary([T || #{<<"type">> := <<"message">>, <<"content">> := Parts} <- maps:get(<<"output">>, R),
        #{<<"type">> := <<"output_text">>, <<"text">> := T} <- Parts]),
    U = maps:get(<<"usage">>, R, #{}),
    {Text, maps:get(<<"input_tokens">>, U, undefined), maps:get(<<"output_tokens">>, U, undefined),
        maps:get(<<"status">>, R, undefined) =:= <<"completed">>};
decode(chat_completions, #{<<"choices">> := [Choice]} = R) ->
    #{<<"message">> := #{<<"content">> := Text}, <<"finish_reason">> := Finish} = Choice,
    U = maps:get(<<"usage">>, R, #{}),
    {Text, maps:get(<<"prompt_tokens">>, U, undefined), maps:get(<<"completion_tokens">>, U, undefined), Finish =:= <<"stop">>};
decode(messages, R) ->
    Text = iolist_to_binary([T || #{<<"type">> := <<"text">>, <<"text">> := T} <- maps:get(<<"content">>, R)]),
    U = maps:get(<<"usage">>, R, #{}),
    {Text, maps:get(<<"input_tokens">>, U, undefined), maps:get(<<"output_tokens">>, U, undefined),
        maps:get(<<"stop_reason">>, R, undefined) =:= <<"end_turn">>}.

models(#{adapter := Adapter, url := Url} = P, Timeout) ->
    {Endpoint, Field, Name} = case Adapter of
        ollama -> {string:slice(Url, 0, length(Url) - length("/api/chat")) ++ "/api/tags", <<"models">>, <<"name">>};
        _ -> {Url ++ "/models", <<"data">>, <<"id">>}
    end,
    case headers(P) of
        {ok, H} ->
            case ae_http:json(get, Endpoint, H, #{}, min(Timeout, 15000)) of
                {ok, 200, R} ->
                    try
                        Items = maps:get(Field, R), true = is_list(Items) andalso length(Items) =< 4096,
                        Found = lists:usort([maps:get(Name, I) || I <- Items]),
                        true = lists:all(fun(N) -> is_binary(N) andalso byte_size(N) > 0 andalso byte_size(N) =< 256 end, Found),
                        {ok, [#{<<"id">> => N, <<"metadata">> => maps:get(N, maps:get(models, P, #{}), #{})} || N <- Found]}
                    catch _:_ -> {error, invalid_provider_response} end;
                {ok, Code, _} when Code =:= 401; Code =:= 403 -> {error, provider_authentication_failed};
                _ -> {error, provider_models_unavailable}
            end;
        Error -> Error
    end.
