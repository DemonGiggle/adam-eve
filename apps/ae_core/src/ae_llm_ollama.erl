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
                 #{<<"format">> => authoring_schema(Config)}) of
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

authoring_schema(Config) ->
    MaxRead = case maps:find(authoring_limits, Config) of
        {ok, Limits} -> (maps:get(<<"source_page_bytes">>, Limits) - 512) * 3 div 4;
        error -> 65536 end,
    String = #{<<"type">> => <<"string">>},
    Number = #{<<"type">> => <<"integer">>, <<"minimum">> => 0},
    Strings = #{<<"type">> => <<"array">>, <<"items">> => String},
    Replacement = #{<<"type">> => <<"object">>, <<"additionalProperties">> => false,
        <<"properties">> => #{<<"path">> => String, <<"old_text">> => String#{<<"minLength">> => 1}, <<"new_text">> => String},
        <<"required">> => [<<"path">>, <<"old_text">>, <<"new_text">>]},
    #{<<"oneOf">> => [
        action_schema(<<"source_list">>, #{<<"offset">> => Number, <<"count">> => Number#{<<"minimum">> := 1, <<"maximum">> => 32}}),
        action_schema(<<"source_read">>, #{<<"path">> => String, <<"offset">> => Number,
            <<"bytes">> => Number#{<<"minimum">> := 1, <<"maximum">> => MaxRead}}),
        action_schema(<<"edit">>, #{<<"edits">> => #{<<"type">> => <<"array">>, <<"items">> => Replacement,
            <<"minItems">> => 1, <<"maxItems">> => 32}, <<"hypothesis">> => String,
            <<"expected_benefit">> => String, <<"risks">> => Strings, <<"requested_tests">> => Strings}),
        action_schema(<<"edit">>, #{<<"path">> => String, <<"old_text">> => String,
            <<"new_text">> => String, <<"hypothesis">> => String, <<"expected_benefit">> => String,
            <<"risks">> => Strings, <<"requested_tests">> => Strings}),
        action_schema(<<"proposal">>, #{<<"patch">> => String, <<"hypothesis">> => String,
            <<"expected_benefit">> => String, <<"risks">> => Strings, <<"requested_tests">> => Strings})]}.
action_schema(Action, Properties) ->
    Fields = Properties#{<<"action">> => #{<<"const">> => Action}},
    #{<<"type">> => <<"object">>, <<"properties">> => Fields,
        <<"required">> => lists:sort(maps:keys(Fields)), <<"additionalProperties">> => false}.

content(#{<<"message">> := #{<<"content">> := Text}}) -> Text.

request(Messages, #{url := Url, model := Model, llm_timeout := Timeout} = Config, Options, Extra) ->
    Thinking = case maps:get(thinking, Config, <<>>) of
        Level when Level =:= <<>>; Level =:= <<"auto">> -> #{};
        <<"off">> -> #{<<"think">> => false};
        <<"on">> -> #{<<"think">> => true};
        Level -> #{<<"think">> => Level}
    end,
    Body = jsx:encode(maps:merge(#{<<"model">> => Model, <<"messages">> => ae_media:ollama(Messages),
                        <<"stream">> => false, <<"options">> => Options}, maps:merge(Thinking, Extra))),
    case ae_llm_api:headers(ae_llm:profile(Config)) of
      {ok, Headers} -> case ae_http:request(post, Url, Headers, Body, Timeout, 1048576) of
        {ok, 200, Response} ->
            try jsx:decode(Response, [return_maps]) of
                #{<<"done">> := true, <<"message">> := #{<<"content">> := Text}} = Decoded
                    when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< 65536 ->
                    {ok, Decoded};
                _ -> {error, invalid_provider_response}
            catch _:_ -> {error, invalid_provider_response} end;
        {ok, _, _} -> {error, provider_response_rejected};
        {error, _} -> {error, provider_unavailable}
      end;
      Error -> Error
    end.
