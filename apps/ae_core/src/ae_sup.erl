-module(ae_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(#{root := Root} = Config) ->
    Store = #{id => ae_store, start => {ae_store, start_link, [Root]}},
    Broker = #{id => ae_tool_broker, start => {ae_tool_broker, start_link, [Config]}},
    Runtimes = #{id => ae_runtime_sup, start => {ae_runtime_sup, start_link, []}, type => supervisor},
    Router = #{id => ae_router, start => {ae_router, start_link, [Config]}},
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 30},
           [Store, Broker, Runtimes, Router]}}.
