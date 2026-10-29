-module(ae_runtime_sup).
-behaviour(supervisor).
-export([start_link/0, start_runtime/3, stop_runtime/1, stop_all/0, stop_inactive/1, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_runtime(Root, Routing, Config) ->
    supervisor:start_child(?MODULE, #{id => {maps:get(<<"slot">>, Routing), make_ref()},
        start => {ae_runtime_worker, start_link, [Root, Routing, Config]},
        restart => temporary, shutdown => 5000}).
stop_runtime(Pid) ->
    [supervisor:terminate_child(?MODULE, Id) || {Id, Child, _, _} <- supervisor:which_children(?MODULE),
                                                Child =:= Pid], ok.
stop_all() ->
    [supervisor:terminate_child(?MODULE, Id) || {Id, _, _, _} <- supervisor:which_children(?MODULE)], ok.
stop_inactive(ActiveSlot) ->
    [supervisor:terminate_child(?MODULE, Id) || {{Slot, _} = Id, _, _, _} <- supervisor:which_children(?MODULE),
                                                Slot =/= ActiveSlot], ok.
init([]) -> {ok, {#{strategy => one_for_one, intensity => 3, period => 30}, []}}.
