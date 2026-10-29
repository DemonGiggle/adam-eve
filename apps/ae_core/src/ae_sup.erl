-module(ae_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

start_link(Config) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Config).

init(#{root := Root} = Config) ->
    Store = #{id => ae_store, start => {ae_store, start_link, [Root]}},
    Broker = #{id => ae_tool_broker, start => {ae_tool_broker, start_link, [Config]}},
    Runtimes = #{id => ae_runtime_sup, start => {ae_runtime_sup, start_link, []}, type => supervisor},
    Builds = #{id => ae_build_sup, start => {ae_build_sup, start_link, []}, type => supervisor},
    Evaluations = #{id => ae_eval_sup, start => {ae_eval_sup, start_link, []}, type => supervisor},
    Router = #{id => ae_router, start => {ae_router, start_link, [Config]}},
    Deployment = #{id => ae_deployment, start => {ae_deployment, start_link, [Config]}},
    Evolution = #{id => ae_evolution, start => {ae_evolution, start_link, [Config]}},
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 30},
           [Store, Broker, Runtimes, Builds, Evaluations, Router, Deployment, Evolution]}}.
