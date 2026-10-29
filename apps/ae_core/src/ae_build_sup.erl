-module(ae_build_sup).
-behaviour(supervisor).
-export([start_link/0, init/1, start_job/3]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
init([]) -> {ok, {#{strategy => one_for_one, intensity => 3, period => 30}, []}}.
start_job(Id, Config, Notify) ->
    supervisor:start_child(?MODULE, #{id => Id, start => {ae_builder, start_link, [Id, Config, Notify]},
        restart => temporary, shutdown => 10000}).
