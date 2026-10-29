-module(ae_policy).
-export([baseline/1, same_baseline/2, other_slot/1, binding/1, digest/1]).

baseline(Route) -> maps:with([<<"slot">>, <<"runtime_instance_id">>, <<"epoch">>, <<"artifact">>], Route).
same_baseline(A, B) -> baseline(A) =:= baseline(B).
other_slot(<<"adam">>) -> <<"eve">>;
other_slot(<<"eve">>) -> <<"adam">>.

binding(Job) ->
    digest(#{<<"deployment_id">> => maps:get(<<"id">>, Job),
             <<"candidate">> => maps:get(<<"candidate">>, Job),
             <<"baseline">> => baseline(maps:get(<<"baseline">>, Job)),
             <<"evaluation">> => maps:get(<<"evaluation">>, Job)}).

digest(Term) ->
    Bytes = crypto:hash(sha256, jsx:encode(Term)),
    list_to_binary(lists:flatten([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bytes])).
