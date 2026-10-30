-module(ae_http).
-export([request/6, request/7, json/5, url/1]).

url(Url) ->
    Parsed = uri_string:parse(Url),
    #{scheme := Scheme, host := Host} = Parsed,
    true = lists:member(Scheme, ["http", "https"]) andalso Host =/= "",
    true = not maps:is_key(userinfo, Parsed) andalso not maps:is_key(fragment, Parsed),
    Parsed.

json(Method, Url, Headers, Body, Timeout) ->
    case request(Method, Url, Headers, jsx:encode(Body), Timeout, 4194304) of
        {ok, Status, Data} ->
            try {ok, Status, jsx:decode(Data, [return_maps, strict])}
            catch _:_ -> {error, invalid_http_response} end;
        Error -> Error
    end.

request(Method, Url, Headers, Body, Timeout, MaxBytes) ->
    request(Method, Url, Headers, Body, Timeout, MaxBytes, "application/json").
request(Method, Url, Headers, Body, Timeout, MaxBytes, ContentType) ->
    try
        #{host := Host, scheme := Scheme} = url(Url),
        TLS = case Scheme of
            "https" -> [{ssl, [{verify, verify_peer}, {depth, 5},
                {cacertfile, "/etc/ssl/certs/ca-certificates.crt"}, {server_name_indication, Host},
                {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}];
            _ -> [] end,
        Request = case Method of get -> {Url, Headers}; _ -> {Url, Headers, ContentType, Body} end,
        case httpc:request(Method, Request,
                [{timeout, Timeout}, {connect_timeout, min(Timeout, 5000)}, {autoredirect, false} | TLS],
                [{body_format, binary}, {max_body_size, MaxBytes}, {max_header_size, 16384}]) of
            {ok, {{_, Status, _}, _, Data}} when byte_size(Data) =< MaxBytes -> {ok, Status, Data};
            {ok, _} -> {error, http_response_too_large};
            {error, _} -> {error, http_unavailable}
        end
    catch _:_ -> {error, http_unavailable} end.
