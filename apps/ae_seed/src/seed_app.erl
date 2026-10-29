-module(seed_app).
-behaviour(application).
-export([start/2, stop/1]).
start(_, _) -> seed_sup:start_link().
stop(_) -> ok.
