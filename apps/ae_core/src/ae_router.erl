-module(ae_router).
-behaviour(gen_server).
-export([start_link/1, turn/3, restart/0, status/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
turn(Request, Session, Message) -> gen_server:call(?MODULE, {turn, Request, Session, Message}, 320000).
restart() -> gen_server:call(?MODULE, restart, 30000).
status() -> gen_server:call(?MODULE, status).

init(#{root := Root} = Config) ->
    Routing = case ae_store:routing() of
        undefined ->
            Manifest = ae_artifacts:bootstrap(Root),
            ok = ae_artifacts:verify(Root, Manifest),
            ae_store:boot(Manifest);
        Existing -> Existing
    end,
    {ok, Runtime} = ae_runtime_sup:start_runtime(Root, Routing, Config),
    Ref = monitor(process, Runtime),
    {ok, #{runtime => Runtime, monitor => Ref, config => Config}}.

handle_call({turn, Request, Session, Message}, _, #{runtime := Runtime} = State) ->
    Validation = ae_protocol:validate(#{<<"protocol_version">> => 1, <<"type">> => <<"user_turn">>,
        <<"request_id">> => Request, <<"session_id">> => Session, <<"message">> => Message,
        <<"epoch">> => 1, <<"memory_cursor">> => 0}),
    Reply = case Validation of
        ok ->
            try
                Auth = ae_runtime_worker:auth(Runtime),
                case ae_store:begin_turn(Auth, Request, Session, Message) of
                    {ok, {completed, Text}} -> {ok, Text};
                    {ok, pending} ->
                        case ae_runtime_worker:turn(Runtime, Request, Session, Message) of
                            {ok, Text} -> ae_store:finish_turn(Auth, Request, Text);
                            Error -> Error
                        end;
                    Error -> Error
                end
            catch exit:_ -> {error, runtime_unavailable} end;
        Error -> Error
    end,
    {reply, Reply, State};
handle_call(status, _, #{runtime := Runtime} = State) ->
    Reply = #{<<"routing">> => ae_store:routing(),
              <<"os_pid">> => ae_runtime_worker:os_pid(Runtime),
              <<"runtime_health">> => case ae_runtime_worker:health(Runtime) of
                  ok -> <<"ok">>; _ -> <<"unhealthy">> end,
              <<"evolution_enabled">> => false, <<"last_event_seq">> => ae_store:last_seq()},
    {reply, Reply, State};
handle_call(restart, _, State) ->
    {reply, ok, replace(State)}.
handle_cast(_, State) -> {noreply, State}.
handle_info({'DOWN', Ref, process, _, Reason}, #{monitor := Ref} = State) ->
    {stop, {runtime_down, Reason}, State};
handle_info(_, State) -> {noreply, State}.
terminate(_, #{runtime := Runtime}) -> catch ae_runtime_sup:stop_runtime(Runtime), ok.

replace(#{runtime := Runtime, monitor := Ref, config := #{root := Root} = Config} = State) ->
    demonitor(Ref, [flush]),
    ae_runtime_sup:stop_runtime(Runtime),
    {ok, Next} = ae_runtime_sup:start_runtime(Root, ae_store:routing(), Config),
    State#{runtime := Next, monitor := monitor(process, Next)}.
