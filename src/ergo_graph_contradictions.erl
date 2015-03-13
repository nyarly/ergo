-module(ergo_graph_contradictions).

-include("ergo_graphs.hrl").
-include_lib("stdlib/include/qlc.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(contradiction, {rule_name, subject, statements}).
-record(endorsed_statement, {statement, provenences}).

-export([resolve/2]).

resolve(Taskname, State) ->
  Rules = statement_invariants(),
  {resolve_self_contradictions(Taskname, State, Rules), resolve_contradictions(State, Rules)}.

statement_invariants() ->
  [
   {single_producer,
    fun(EdgeQuery) ->
        qlc:q([Edge || Edge=#production{task=T1,produces=P1} <- EdgeQuery,
                       #production{     task=T2,produces=P2} <- EdgeQuery,
                       T1 =/= T2, P1 =:= P2
              ])
    end,
    fun(#production{produces=Product}) -> Product end
   },
   {unique_fresh_taskmeta,
    fun(EdgeQuery) ->
        qlc:q([Edge || Edge=#task_meta{about=A1,name=fresh,value=V1} <- EdgeQuery,
                       #task_meta{     about=A2,name=fresh,value=V2} <- EdgeQuery,
                       A1 =:= A2, V1 =/= V2
              ])
    end,
    fun(#task_meta{about=Task, name=Name}) -> {Task, Name} end
   },
   {unique_fresh_filemeta,
    fun(EdgeQuery) ->
        qlc:q([Edge || Edge=#file_meta{about=A1,name=fresh,value=V1} <- EdgeQuery,
                       #file_meta{     about=A2,name=fresh,value=V2} <- EdgeQuery,
                       A1 =:= A2, V1 =/= V2
              ])
    end,
    fun(#file_meta{about=Product, name=Name}) -> {Product, Name} end
   }
  ].

resolve_self_contradictions(Taskname, State, Rules) ->
  format_contradictions(fix_self_contradictions(find_self_contradictions(Taskname, State, Rules), State)).

resolve_contradictions(State, Rules) ->
  format_contradictions(fix_contradictions(find_contradictions(State, Rules), State)).

format_contradictions(List) ->
  [ format_contradiction(Contra) || Contra <- List ].

format_contradiction(#contradiction{rule_name=Rule, subject=About, statements=List}) ->
  {Rule, About, [{Prov#provenence.task, ergo_graphs:statement_for_edge(Edge)} ||
                 #endorsed_statement{statement=Edge, provenences=Provs} <- List, Prov <- Provs]}.

fix_self_contradictions(Contras, State) ->
  [ fix_self_contradiction(List, State) || #contradiction{statements=List} <- Contras ],
  Contras.

fix_self_contradiction(Contras, State) ->
  {New, Reit, Old} = lists:foldl(
                       fun (Contra, Groups) ->
                           winnow_statements(Contra, Groups, State)
                       end, {[],[],[]}, Contras),
  retain_best_group(Reit, New, Old, State).

winnow_statements(Contra=#endorsed_statement{statement=#seq{batch_id=BatchId}},
                  {New, Reit, Old}, #state{batch_id=BatchId}) ->
  {[Contra | New], Reit, Old};
winnow_statements(Contra=#endorsed_statement{statement=#seq{removed_id=RemoveId}},
                  {New, Reit, Old}, #state{removed_id=RemoveId}) ->
  {New, Reit, [Contra | Old]};
winnow_statements(Contra, {New, Reit, Old}, _) ->
  {New, [Contra | Reit], Old}.

retain_best_group([], _New, Old, State) ->
  remove_all_of(Old, State);
retain_best_group(_Reit, New, Old, State) ->
  remove_all_of(New, State), remove_all_of(Old, State).

fix_contradictions(Contras, State=#state{batch_id=BatchId}) ->
  remove_all_of([ Contra ||
    #contradiction{ statements=List } <- Contras,
    Contra=#endorsed_statement{ statement=Stmt } <-  List,
    element(#seq.batch_id, Stmt) =/= BatchId % seq as examplar for edges
  ], State),
  Contras.

remove_all_of(Contras, State) ->
  [ remove_contradicted_statement(Contra, Provs, State) ||
    #endorsed_statement{ statement=Contra, provenences=Provs } <-  Contras
  ].

remove_contradicted_statement(Statement, Provenence, #state{edges=Edges,provenence=Provs}) ->
    [ets:delete_object(Provs, Prov) || Prov <- Provenence],
    ets:delete_object(Edges, Statement).

find_contradictions(State=#state{edges=Edges}, Rules) ->
  contradictions( ets:table(Edges), State, Rules).

find_self_contradictions(Taskname, State=#state{edges=Edges,provenence=Provs}, Rules) ->
  contradictions( qlc:q([Edge || Edge <- ets:table(Edges), Prov <- ets:table(Provs),
                                         Edge#seq.edge_id =:= Prov#provenence.edge_id,
                                         Prov#provenence.task =:= Taskname]),
        State, Rules).

contradictions(BaseQuery, State, Rules) ->
  lists:foldl(
    fun({Name, QueryFun, Grouping}, List) ->
        case build_contradictions(Name, QueryFun(BaseQuery), Grouping, State) of
          [] -> List;
          Contras -> Contras ++ List
        end
    end,
    [], Rules
   ).

build_contradictions(Name, Query, GroupBy, #state{provenence=ProvTab}) ->
  ContraTree = lists:foldl(
    fun({Contra, Provs}, Tree) ->
        Key = {Name, GroupBy(Contra)},
        case gb_trees:lookup(Key, Tree) of
          none -> gb_trees:enter(Key, [#endorsed_statement{statement=Contra, provenences=Provs}], Tree);
          {value, List} -> gb_trees:enter(Key, [#endorsed_statement{statement=Contra, provenences=Provs} | List], Tree)
        end
    end,
    gb_trees:empty(),
    [{
      Contra,
      qlc:eval(qlc:q( [ Prov || Prov <- ets:table(ProvTab),
                                Prov#provenence.edge_id =:= Contra#production.edge_id ] ))
     } ||
     Contra <- qlc:eval(Query, [{unique_all, true}]) ]),
  [ #contradiction{rule_name=Rule,subject=About,statements=gb_trees:get(Key, ContraTree)}  || Key={Rule, About} <- gb_trees:keys(ContraTree) ].
