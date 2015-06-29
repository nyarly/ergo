-module (ergo_graph_disclaims).

-include("ergo_graphs.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(NOTEST, true).
-include_lib("eunit/include/eunit.hrl").

-export([resolve/2]).

-type report() :: {disclaim, {prod, ergo:taskname(), ergo:product()}, [ergo:taskname()]}.

resolve(TaskName, State) ->
  Disclaimers = check(TaskName, State),
  clear_disclaimers(Disclaimers, State),
  Disclaimers.

clear_disclaimers(Disclaimers, State) ->
  [ ergo_graphs:remove_statement(Statement, State) || {disclaim, Statement, _} <- Disclaimers ].

check(TaskName, #state{edges=Etab,provenence=Ptab}) ->
  Claims = production_claims(TaskName, Etab, Ptab),
  format_disclaimers( only_gossip( gathered_products(Claims), TaskName, Claims), TaskName).

production_claims(TaskName, Etab, Ptab) ->
  qlc:eval(qlc:q([{Prod, Says}
                  || #production{edge_id=Id, task=By, produces=Prod} <- ets:table(Etab),
                     #provenence{edge_id=About,task=Says} <- ets:table(Ptab),
                     Id =:= About,
                     By =:= TaskName
                 ])).

gathered_products(Claims) ->
  lists:foldl(fun gather_by_product/2, dict:new(), Claims).

only_gossip(ProdDict, TaskName, Claims) ->
  lists:foldl(fun({Prod, T}, Dict) -> strip_claimed(TaskName, Prod, T, Dict) end, ProdDict, Claims).

format_disclaimers(BadDict, TaskName) ->
  map_to_list(fun(Product, Liars) -> format_disclaimer(TaskName, Product, Liars) end, BadDict).

gather_by_product({Prod, Says}, Dict) ->
  dict:append(Prod, Says, Dict).

strip_claimed(TaskName, Prod, Claimer, Dict) when Claimer =:= TaskName -> dict:erase(Prod, Dict);
strip_claimed(_, _, _, Dict) -> Dict.

map_to_list(Fun, Dict) ->
  dict:fold(fun(Key, Value, List) ->
                [Fun(Key, Value) | List]
            end, [], Dict).

-spec(format_disclaimer(ergo:taskname(), ergo:product(), [ergo:taskname()]) -> report()).
format_disclaimer(TaskName, Product, Liars) -> {disclaim, {prod, TaskName, Product}, Liars}.

%%% Tests

disclaim_test_() ->
  TheTask=[<<"supposed_to_produce">>],
  Gossiper=[<<"says_they_produce">>],
  TheProduct="output/product.dat",
  ProdStmt = #production{
                edge_id=1,
                batch_id=1,
                task=TheTask,
                produces=TheProduct
               },
  SelfAssertion = #provenence{edge_id=1, task=TheTask},
  Gossip = #provenence{edge_id=1, task=Gossiper},
  {
   foreach,
   fun() -> %setup
       dbg:tracer(),
       dbg:p(all,c),
       Etab = ets:new(edge, [bag, public, {keypos, 2}]),
       Vtab = ets:new(vertex, [set, public, {keypos, 2}]),
       Ptab = ets:new(provenence, [bag, public, {keypos, 2}]),
       ets:insert_new(Vtab, #task{name=TheTask}),
       ets:insert_new(Vtab, #task{name=Gossiper}),

       #state{
          edges = Etab,
          vertices=Vtab,
          provenence= Ptab
         }
   end,
   fun(#state{edges=Es,vertices=Vs,provenence=Ps}) -> %teardown
       dbg:ctp(),
       dbg:p(all, clear),
       ets:delete(Es), ets:delete(Vs), ets:delete(Ps)
   end,
   [
    fun(State) ->
        {"Null case: empty state produces no disclaimers",
         ?_test(begin
                  Disclaimed = check(TheTask, State),
                  ?assertEqual(length(Disclaimed), 0)
                end)
        }
    end,
    fun(State=#state{edges=Etab,provenence=Ptab}) ->
        {"Disclaimer when task itself doesn't support production statement",
         ?_test(begin
                  true = ets:insert_new(Etab, ProdStmt),
                  true = ets:insert(Ptab, Gossip),
                  Disclaimed = check(TheTask, State),
                  ?assertNotEqual(length(Disclaimed), 0),
                  ?assertMatch(Disclaimed, [{disclaim, {prod, TheTask, TheProduct}, [Gossiper]}])
                end)
        }
    end,
    fun(State=#state{edges=Etab,provenence=Ptab}) ->
        {"No disclaimer when task itself supports the production statement",
         ?_test(begin
                  true = ets:insert_new(Etab, ProdStmt),
                  true = ets:insert(Ptab, Gossip),
                  true = ets:insert(Ptab, SelfAssertion),
                  Disclaimed = check(TheTask, State),
                  ?assertEqual(length(Disclaimed), 0)
                end)
        }
    end
   ]
  }.
