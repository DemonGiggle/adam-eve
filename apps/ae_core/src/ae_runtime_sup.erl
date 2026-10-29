-module(ae_runtime_sup).
-behaviour(supervisor).
-export([start_link/0, start_runtime/3, stop_runtime/1, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_runtime(Root, Routing, Config) ->
    supervisor:start_child(?MODULE, #{id => seed,
        start => {ae_runtime_worker, start_link, [Root, Routing, Config]},
        restart => temporary, shutdown => 5000}).
stop_runtime(Pid) ->
    case supervisor:terminate_child(?MODULE, seed) of
        ok -> supervisor:delete_child(?MODULE, seed);
        {error, not_found} -> catch gen_server:stop(Pid), ok
    end.
init([]) -> {ok, {#{strategy => one_for_one, intensity => 3, period => 30}, []}}.
