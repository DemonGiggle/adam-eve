-module(ae_host_command_tests).
-include_lib("eunit/include/eunit.hrl").

executes_arguments_without_a_shell_test() ->
    {ok, <<"a;$(false) b">>} = ae_host_command:run("/usr/bin/printf", ["%s", "a;$(false) b"], [], 2000, 128),
    ?assertEqual({error, command_failed}, ae_host_command:run("/usr/bin/false", [], [], 2000, 128)).

bounds_time_and_output_test() ->
    ?assertEqual({error, timeout}, ae_host_command:run("/usr/bin/sleep", ["2"], [], 50, 128)),
    ?assertEqual({error, output_limit}, ae_host_command:run("/usr/bin/printf", ["%100s", "x"], [], 2000, 16)).
