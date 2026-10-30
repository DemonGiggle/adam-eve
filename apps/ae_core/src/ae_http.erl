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
                [{sync, false}, {stream, {self, once}}, {max_body_size, MaxBytes}, {max_header_size, 16384}]) of
            {ok, Id} ->
                case get(ae_http_owner) of
                    {Owner, Ref} -> Owner ! {http_request, Ref, Id};
                    _ -> ok end,
                collect(Id, MaxBytes, erlang:monotonic_time(millisecond) + Timeout, undefined, 200, 0, []);
            {error, _} -> {error, http_unavailable}
        end
    catch _:_ -> {error, http_unavailable} end.

collect(Id, Max, Deadline, Handler, Status, Size, Chunks) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {http, {Id, stream_start, Headers, Pid}} ->
            Code = case lists:keymember("content-range", 1, Headers) of true -> 206; false -> 200 end,
            httpc:stream_next(Pid), collect(Id, Max, Deadline, Pid, Code, Size, Chunks);
        {http, {Id, stream, Part}} when Size + byte_size(Part) =< Max ->
            httpc:stream_next(Handler), collect(Id, Max, Deadline, Handler, Status, Size + byte_size(Part), [Part | Chunks]);
        {http, {Id, stream, _}} -> httpc:cancel_request(Id), {error, http_response_too_large};
        {http, {Id, stream_end, _}} -> {ok, Status, iolist_to_binary(lists:reverse(Chunks))};
        {http, {Id, {{_, Code, _}, _, Data}}} when byte_size(Data) =< Max -> {ok, Code, Data};
        {http, {Id, _}} -> {error, http_unavailable}
    after Wait -> httpc:cancel_request(Id), {error, http_unavailable}
    end.
