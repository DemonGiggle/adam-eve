-module(ae_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_Type, _Args) ->
    {ok, Config} = application:get_env(ae_core, config),
    ae_sup:start_link(Config).

stop(_State) -> ok.
