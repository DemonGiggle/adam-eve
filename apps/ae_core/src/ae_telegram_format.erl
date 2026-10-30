-module(ae_telegram_format).
-export([split/1, html/1]).

split(Text) -> chunks(unicode:characters_to_list(Text), 0, [], []).
chunks([], _, [], Result) -> lists:reverse(Result);
chunks([], _, Current, Result) -> lists:reverse([unicode:characters_to_binary(lists:reverse(Current)) | Result]);
chunks([Char | Rest] = All, Units, Current, Result) ->
    N = case Char > 16#FFFF of true -> 2; false -> 1 end,
    case Units + N =< 3800 of
        true -> chunks(Rest, Units + N, [Char | Current], Result);
        false -> chunks(All, 0, [], [unicode:characters_to_binary(lists:reverse(Current)) | Result])
    end.

html(Text) ->
    Lines = binary:split(Text, <<"\n">>, [global]),
    {Parts, Code} = lists:mapfoldl(fun line/2, false, Lines),
    End = case Code of true -> <<"</code></pre>">>; false -> <<>> end,
    iolist_to_binary([lists:join(<<"\n">>, Parts), End]).
line(<<"```", _/binary>>, false) -> {<<"<pre><code>">>, true};
line(<<"```", _/binary>>, true) -> {<<"</code></pre>">>, false};
line(Line, true) -> {escape(Line), true};
line(Line, false) ->
    %% Only escaped text enters generated markup. Unbalanced Markdown stays
    %% readable text, and each independently split chunk closes its own tags.
    Safe = escape(Line),
    Bold = re:replace(Safe, <<"\\*\\*([^*]+)\\*\\*">>, <<"<b>\\1</b>">>, [global, {return, binary}]),
    Inline = re:replace(Bold, <<"`([^`]+)`">>, <<"<code>\\1</code>">>, [global, {return, binary}]),
    {Inline, false}.
escape(Text) ->
    lists:foldl(fun({From, To}, Value) -> binary:replace(Value, From, To, [global]) end,
        Text, [{<<"&">>, <<"&amp;">>}, {<<"<">>, <<"&lt;">>}, {<<">">>, <<"&gt;">>}]).
