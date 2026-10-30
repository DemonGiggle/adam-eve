-module(ae_telegram_config).
-export([enabled/1, normalize/1]).

enabled(Config) ->
    Raw = maps:get(telegram_config, Config, #{}),
    case os:getenv("AE_TELEGRAM_ENABLED") of
        false -> maps:get(<<"enabled">>, Raw, false);
        "true" -> true;
        "false" -> false
    end.
normalize(Config) ->
    Raw = maps:get(telegram_config, Config, #{}),
    Users = maps:get(<<"allowed_users">>, Raw, []), Groups = maps:get(<<"allowed_groups">>, Raw, []),
    Admins = maps:get(<<"admin_user_ids">>, Raw, []),
    true = is_list(Users) andalso is_list(Groups) andalso is_list(Admins),
    true = length(Users) + length(Groups) =< 4096 andalso Users ++ Groups =/= [],
    true = lists:all(fun(I) -> is_integer(I) andalso I > 0 andalso I < (1 bsl 63) end, Users),
    true = lists:all(fun(I) -> is_integer(I) andalso I < 0 andalso I > -(1 bsl 63) end, Groups),
    true = lists:all(fun(I) -> lists:member(I, Users) end, Admins),
    Path = maps:get(<<"token_path">>, Raw, <<>>),
    Env = maps:get(<<"token_env">>, Raw, case Path of <<>> -> <<"TELEGRAM_BOT_TOKEN">>; _ -> <<>> end),
    true = is_binary(Env) andalso is_binary(Path) andalso (Env =:= <<>> orelse Path =:= <<>>),
    Base = binary_to_list(maps:get(<<"base_url">>, Raw, <<"https://api.telegram.org">>)),
    Parsed = ae_http:url(Base), true = not maps:is_key(query, Parsed),
    case maps:get(scheme, Parsed) of
        "https" -> ok;
        _ -> true = lists:member(maps:get(host, Parsed), ["localhost", "127.0.0.1", "::1"])
    end,
    Poll = maps:get(<<"poll_timeout_seconds">>, Raw, 25),
    Capacity = maps:get(<<"queue_capacity">>, Raw, 128),
    true = is_integer(Poll) andalso Poll >= 0 andalso Poll =< 25,
    true = is_integer(Capacity) andalso Capacity >= 1 andalso Capacity =< 1024,
    #{token_env => Env, token_path => Path, base_url => string:trim(Base, trailing, "/"),
        users => Users, groups => Groups, admins => Admins, poll_seconds => Poll,
        capacity => Capacity, controller => Config}.
