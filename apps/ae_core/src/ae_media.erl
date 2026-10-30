-module(ae_media).
-export([attach/2, ollama/1, responses/1, chat/1, anthropic/1]).

attach(Messages, []) -> Messages;
attach(Messages, Images) ->
    Reversed = lists:reverse(Messages),
    [#{<<"role">> := <<"user">>} = Last | Rest] = Reversed,
    lists:reverse([Last#{<<"images">> => Images} | Rest]).
ollama(Messages) -> [case maps:take(<<"images">>, M) of
    {Images, Rest} -> Rest#{<<"images">> => [maps:get(<<"data_base64">>, I) || I <- Images]}; error -> M end || M <- Messages].
responses(Messages) -> transform(Messages, responses).
chat(Messages) -> transform(Messages, chat).
anthropic(Messages) -> transform(Messages, anthropic).
transform(Messages, Wire) -> [case maps:take(<<"images">>, M) of
    {Images, Rest} ->
        Text = maps:get(<<"content">>, Rest),
        Parts = case Wire of
            responses -> [#{<<"type">> => <<"input_text">>, <<"text">> => Text} | [#{<<"type">> => <<"input_image">>, <<"image_url">> => url(I)} || I <- Images]];
            chat -> [#{<<"type">> => <<"text">>, <<"text">> => Text} | [#{<<"type">> => <<"image_url">>, <<"image_url">> => #{<<"url">> => url(I)}} || I <- Images]];
            anthropic -> [#{<<"type">> => <<"text">>, <<"text">> => Text} | [#{<<"type">> => <<"image">>, <<"source">> =>
                #{<<"type">> => <<"base64">>, <<"media_type">> => maps:get(<<"mime">>, I), <<"data">> => maps:get(<<"data_base64">>, I)}} || I <- Images]]
        end,
        Rest#{<<"content">> := Parts};
    error -> M end || M <- Messages].
url(#{<<"mime">> := Mime, <<"data_base64">> := Data}) -> <<"data:", Mime/binary, ";base64,", Data/binary>>.
