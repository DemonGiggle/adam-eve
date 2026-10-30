-module(ae_media_tests).
-include_lib("eunit/include/eunit.hrl").

provider_image_encodings_test() ->
    M = [#{<<"role">> => <<"user">>, <<"content">> => <<"describe">>}],
    Image = #{<<"mime">> => <<"image/png">>, <<"data_base64">> => <<"aGVsbG8=">>},
    Attached = ae_media:attach(M, [Image]),
    ?assertMatch([#{<<"images">> := [<<"aGVsbG8=">>]}], ae_media:ollama(Attached)),
    ?assertMatch([#{<<"content">> := [_, #{<<"type">> := <<"input_image">>, <<"image_url">> := <<"data:image/png;base64,aGVsbG8=">>}]}], ae_media:responses(Attached)),
    ?assertMatch([#{<<"content">> := [_, #{<<"type">> := <<"image_url">>}]}], ae_media:chat(Attached)),
    ?assertMatch([#{<<"content">> := [_, #{<<"type">> := <<"image">>, <<"source">> := #{<<"media_type">> := <<"image/png">>}}]}], ae_media:anthropic(Attached)).
