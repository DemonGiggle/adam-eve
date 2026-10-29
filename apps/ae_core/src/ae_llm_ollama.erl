-module(ae_llm_ollama).
-export([complete/2, complete_budgeted/3]).

complete(Messages, #{max_tokens := Tokens} = Config) ->
    case request(Messages, Config, #{<<"num_predict">> => Tokens}, #{}) of
        {ok, Response} -> {ok, #{<<"text">> => content(Response)}};
        Error -> Error
    end.

complete_budgeted(Messages, Config, Tokens) when is_integer(Tokens), Tokens >= 2 ->
    %% Bound both prompt context and generated tokens within the reservation.
    %% Accounting is mandatory for authoring, unlike the development chat path.
    Context = Tokens div 2, Output = Tokens - Context,
    case request(Messages, Config, #{<<"num_ctx">> => Context, <<"num_predict">> => Output, <<"temperature">> => 0},
                 #{<<"format">> => authoring_schema()}) of
        {ok, Response} ->
            Prompt = maps:get(<<"prompt_eval_count">>, Response, undefined),
            Cached = maps:get(<<"prompt_eval_cached_count">>, Response, 0),
            Generated = maps:get(<<"eval_count">>, Response, undefined),
            case lists:all(fun(N) -> is_integer(N) andalso N >= 0 end, [Prompt, Cached, Generated]) of
                false -> {error, provider_usage_missing};
                true when Prompt + Cached =< Context, Generated =< Output ->
                    {ok, #{<<"text">> => content(Response), <<"input_tokens">> => Prompt + Cached,
                           <<"output_tokens">> => Generated}};
                true -> {error, provider_budget_violation}
            end;
        Error -> Error
    end;
complete_budgeted(_, _, _) -> {error, insufficient_token_reservation}.

authoring_schema() ->
    String = #{<<"type">> => <<"string">>},
    Number = #{<<"type">> => <<"integer">>, <<"minimum">> => 0},
    Strings = #{<<"type">> => <<"array">>, <<"items">> => String},
    #{<<"oneOf">> => [
        action_schema(<<"source_list">>, #{<<"offset">> => Number, <<"count">> => Number#{<<"minimum">> := 1, <<"maximum">> => 32}}),
        action_schema(<<"source_read">>, #{<<"path">> => String, <<"offset">> => Number,
            <<"bytes">> => Number#{<<"minimum">> := 1, <<"maximum">> => 65536}}),
        action_schema(<<"proposal">>, #{<<"patch">> => String, <<"hypothesis">> => String,
            <<"expected_benefit">> => String, <<"risks">> => Strings, <<"requested_tests">> => Strings})]}.
action_schema(Action, Properties) ->
    Fields = Properties#{<<"action">> => #{<<"const">> => Action}},
    #{<<"type">> => <<"object">>, <<"properties">> => Fields,
        <<"required">> => lists:sort(maps:keys(Fields)), <<"additionalProperties">> => false}.

content(#{<<"message">> := #{<<"content">> := Text}}) -> Text.

request(Messages, #{url := Url, model := Model, llm_timeout := Timeout}, Options, Extra) ->
    Body = jsx:encode(maps:merge(#{<<"model">> => Model, <<"messages">> => Messages,
                        <<"stream">> => false, <<"options">> => Options}, Extra)),
    case httpc:request(post, {Url, [], "application/json", Body},
                       [{timeout, Timeout}, {connect_timeout, 3000}, {autoredirect, false}],
                       [{body_format, binary}, {max_body_size, 1048576}, {max_header_size, 16384}]) of
        {ok, {{_, 200, _}, _, Response}} when byte_size(Response) =< 1048576 ->
            try jsx:decode(Response, [return_maps]) of
                #{<<"done">> := true, <<"message">> := #{<<"content">> := Text}} = Decoded
                    when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< 65536 ->
                    {ok, Decoded};
                _ -> {error, invalid_provider_response}
            catch _:_ -> {error, invalid_provider_response} end;
        {ok, _} -> {error, provider_response_rejected};
        {error, _} -> {error, provider_unavailable}
    end.
