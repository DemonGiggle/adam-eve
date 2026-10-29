-module(ae_context).
-export([messages/2]).

messages(Request, #{context_turns := Limit}) ->
    fit(ae_store:context(Request, Limit)).

fit(Messages) when is_list(Messages) ->
    %% JSON escaping can expand a stored text sixfold. Reserve envelope space,
    %% and drop complete old turns rather than splitting a user/reply pair.
    case byte_size(jsx:encode(Messages)) =< ae_protocol:max_bytes() - 4096 of
        true -> Messages;
        false ->
            [_, _ | Rest] = Messages,
            fit(Rest)
    end;
fit(Error) -> Error.
