-module(ae_tool_broker).
-behaviour(gen_server).
-export([start_link/1, request/3, request_evolution/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

start_link(Config) -> gen_server:start_link({local, ?MODULE}, ?MODULE, Config, []).
request(Auth, Request, Message) -> gen_server:call(?MODULE, {tool, Auth, Request, Message}, 310000).
request_evolution(Auth, Id, Message) ->
    Timeout = case ae_store:evolution({get, Id}) of
        #{<<"deadline">> := Deadline} -> max(10000, Deadline - erlang:system_time(millisecond) + 10000);
        _ -> 10000 end,
    gen_server:call(?MODULE, {evolution_tool, Auth, Id, Message}, Timeout).
init(Config) -> {ok, Config}.
handle_call({evolution_tool, Auth, Job, Message}, _, Config) ->
    Reply = case ae_store:authorized(Auth) of
        ok -> ae_authoring_broker:request(Auth, Job, Message, Config);
        Error -> Error
    end,
    {reply, Reply, Config};
handle_call({tool, Auth, Request, Message}, _, Config) ->
    Reply = case ae_store:authorized(Auth) of
        ok -> authorize(Auth, Request, Message, Config);
        Error -> Error
    end,
    {reply, Reply, Config};
handle_call(_, _, Config) -> {reply, {error, denied}, Config}.
handle_cast(_, Config) -> {noreply, Config}.
handle_info(_, Config) -> {noreply, Config}.

authorize({_, _, Epoch}, Request,
          #{<<"request_id">> := Request, <<"epoch">> := Epoch,
            <<"tool">> := <<"memory_read">>, <<"args">> := Args,
            <<"idempotency_key">> := <<"memory_read">>}, Config) when map_size(Args) =:= 0 ->
    {ok, #{<<"messages">> => ae_context:messages(Request, Config)}};
authorize({_, _, Epoch} = Auth, Request,
          #{<<"request_id">> := Request, <<"epoch">> := Epoch, <<"tool">> := <<"llm">>,
            <<"args">> := #{<<"messages">> := Messages} = Args,
            <<"idempotency_key">> := <<"llm">>}, Config) when map_size(Args) =:= 1 ->
    case ae_context:messages(Request, Config) of
        Messages ->
            case ae_store:reserve_tool(Auth, Request, <<"llm">>, maps:get(max_llm_attempts, Config)) of
                {ok, reserved} ->
                    Result = case ae_llm:select(ae_store:session({turn, Request}), Config) of
                      {ok, Selected} -> case ae_llm:complete(Messages, Selected) of
                        {ok, Value} -> Value;
                        {error, Reason} -> #{<<"error">> => atom_to_binary(Reason, utf8)}
                      end;
                      {error, Reason} -> #{<<"error">> => atom_to_binary(Reason, utf8)} end,
                    ae_store:finish_tool(Auth, Request, <<"llm">>, Result);
                {ok, {completed, Result}} -> {ok, Result};
                {error, Reason} -> {ok, #{<<"error">> => atom_to_binary(Reason, utf8)}}
            end;
        _ -> {error, context_mismatch}
    end;
authorize(_, _, _, _) -> {error, denied}.
