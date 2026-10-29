-module(ae_llm_ollama).
-export([complete/2]).

complete(Messages, #{url := Url, model := Model, llm_timeout := Timeout, max_tokens := Tokens}) ->
    Body = jsx:encode(#{<<"model">> => Model, <<"messages">> => Messages,
                        <<"stream">> => false, <<"options">> => #{<<"num_predict">> => Tokens}}),
    case httpc:request(post, {Url, [], "application/json", Body},
                       [{timeout, Timeout}, {connect_timeout, 3000}, {autoredirect, false}],
                       [{body_format, binary}, {max_body_size, 1048576}, {max_header_size, 16384}]) of
        {ok, {{_, 200, _}, _, Response}} when byte_size(Response) =< 1048576 ->
            try jsx:decode(Response, [return_maps]) of
                #{<<"done">> := true, <<"message">> := #{<<"content">> := Text}}
                    when is_binary(Text), byte_size(Text) > 0, byte_size(Text) =< 65536 ->
                    {ok, #{<<"text">> => Text}};
                _ -> {error, invalid_provider_response}
            catch _:_ -> {error, invalid_provider_response} end;
        {ok, _} -> {error, provider_response_rejected};
        {error, _} -> {error, provider_unavailable}
    end.
