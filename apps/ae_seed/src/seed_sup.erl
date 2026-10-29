-module(seed_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 0, period => 30},
        [#{id => seed_agent, start => {seed_agent, start_link, []}}]}}.
