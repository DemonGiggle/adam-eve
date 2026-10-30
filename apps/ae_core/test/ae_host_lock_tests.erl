-module(ae_host_lock_tests).
-include_lib("eunit/include/eunit.hrl").

uses_the_same_exclusive_flock_as_other_processes_test() ->
    Path = filename:join("/tmp", "ae-host-lock-" ++ integer_to_list(erlang:unique_integer([positive]))),
    try
        ok = ae_host_lock:with(Path, 2000, fun() ->
            ?assertEqual({error, command_failed}, ae_host_command:run("/usr/bin/flock", ["-n", Path, "/usr/bin/true"], [], 2000, 128)), ok
        end),
        ?assertEqual({ok, <<>>}, ae_host_command:run("/usr/bin/flock", ["-w", "2", Path, "/usr/bin/true"], [], 3000, 128))
    after file:delete(Path) end.
