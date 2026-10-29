-module(ae_sup).
-behaviour(supervisor).
-export([start_link/1, init/1]).

start_link(Root) -> supervisor:start_link({local, ?MODULE}, ?MODULE, Root).

init(Root) ->
    Store = #{id => ae_store, start => {ae_store, start_link, [Root]}},
    {ok, {#{strategy => rest_for_one, intensity => 3, period => 30}, [Store]}}.
