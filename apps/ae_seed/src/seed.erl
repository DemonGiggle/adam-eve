-module(seed).
-export([main/1]).

main([Path, Token]) ->
    application:load(ae_seed),
    application:set_env(ae_seed, connection, {Path, list_to_binary(Token)}),
    {ok, _} = application:ensure_all_started(ae_seed),
    Ref = monitor(process, whereis(seed_sup)),
    receive {'DOWN', Ref, process, _, _} -> halt(1) end;
main(_) -> halt(64).
