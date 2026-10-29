-module(ae_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Root} = application:get_env(ae_core, data_root),
    ae_sup:start_link(Root).

stop(_State) -> ok.
