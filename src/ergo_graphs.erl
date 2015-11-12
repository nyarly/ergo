-module(ergo_graphs).
-behavior(gen_server).
%% API
-export([start_link/1, get_products/2,get_dependencies/2,get_metadata/2, build_list/2,task_batch/5,task_invalid/3]).
-export([statement_for_edge/1, edge_for_statement/1, remove_statement/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("stdlib/include/qlc.hrl").

-define(VIA(WorkspaceName), {via, ergo_workspace_registry, {WorkspaceName, graph, only}}).
start_link(Workspace) ->
  gen_server:start_link({via, ergo_workspace_registry, {Workspace, graph, only}}, ?MODULE, [Workspace], []).

-include("ergo_graphs.hrl").

-spec(get_products(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_products(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {products, Task}).

-spec(get_dependencies(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_dependencies(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {dependencies, Task}).

-spec(build_list(ergo:workspace_name(), [ergo:target()]) -> ergo:build_spec()).
build_list(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {build_list, Targets}).


-spec(get_metadata(ergo:workspace_name(), ergo:target()) -> [{atom(), term()}]).
get_metadata(Workspace, Target) ->
  gen_server:call(?VIA(Workspace), {get_metadata, Target}).


%% @spec:	task_batch(Task::ergo:taskname(),Graph::ergo:graph_item()) -> ok.
%% @doc:	Receives a batch of build-graph edges from a particular task.
%% @end

%% XXX change boolean "Succeeded" to atoms - Result: succees|failure
-spec(task_batch(ergo:workspace_name(), ergo:build_id(), ergo:taskname(),Graph::ergo:graph_item(), boolean()) -> {ok, changed|no_change}).
task_batch(Workspace, BuildId, Task, Graph, Succeeded) ->
  gen_server:call(?VIA(Workspace), {task_batch, BuildId, Task, Graph, Succeeded}).

-spec(task_invalid(ergo:workspace_name(), ergo:build_id(), ergo:taskname()) -> ok).
task_invalid(Workspace, BuildId, Task) ->
  gen_server:call(?VIA(Workspace), {task_invalid, BuildId, Task}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Workspace]) ->
  {ok, build_state(Workspace) }.

%handle_call({new_dep, FromProduct, ToProduct}, _From, State) ->
%  {reply, new_dep(State, FromProduct, ToProduct), State};
%handle_call({new_req, Task, Product}, _From, State) ->
%  {reply, new_req(State, Task, Product), State};
%handle_call({new_prod, Task, Product}, _From, State) ->
%  {reply, new_prod(State, Task, Product), State};
%handle_call({co_task, WhenTask, AlsoTask}, _From, State) ->
%  {reply, co_task(State, WhenTask, AlsoTask), State};
%handle_call({task_seq, First, Second}, _From, State) ->
%  {reply, task_seq(State, First, Second), State};

handle_call({products, Task}, _From, State) ->
  {reply, products(State, Task), State};
handle_call({dependencies, Task}, _From, State) ->
  {reply, dependencies(State, Task), State};
handle_call({build_list, Targets}, _From, State) ->
  {NewState, Result} = handle_build_list(State,Targets),
  {reply, Result, NewState};
handle_call({task_invalid, BuildId, Task}, _From, State) ->
  {reply, invalidate_task(BuildId, Task, State), State};
handle_call({task_batch, BuildId, Task, Graph, Succeeded}, _From, OldState) ->
  State = update_batch_id(OldState),
  {reply, absorb_task_batch(BuildId, Task, Graph, Succeeded, State), State};
handle_call({get_metadata, Thing}, _From, State) ->
  {reply, handle_get_metadata(Thing, State), State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
handle_info(_Info, State) ->
  {noreply, State}.
terminate(_Reason, State) ->
  cleanup_state(State),
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%

absorb_task_batch(BuildId, Task, Graph, Succeeded, State) ->
  maybe_notify_changed(process_task_batch(Task, Graph, Succeeded, State), BuildId, Task, State).

invalidate_task(BuildId, Task, State) ->
  report_invalid_provenences( remove_task(Task, State), Task, BuildId, State).

remove_task_provenences(Task, #state{provenence=Pvs}) ->
  qlc:eval(qlc:q([ets:delete_object(Pvs, Prv) || Prv=#provenence{task=T} <- ets:table(Pvs), T=:=Task])).

provenence_about_edges(EdgeList, #state{provenence=Pvs}) ->
  qlc:eval(qlc:q([{Edge, Prv} || Prv=#provenence{edge_id=E} <- ets:table(Pvs),
                                 Edge <- EdgeList,
                                 E=:=element(#seq.edge_id, Edge)])).

remove_edge_pairs(EPs, #state{edges=ETab, provenence=PTab}) ->
  [{ets:delete_object(ETab, Edge), ets:delete_object(PTab, Prv)} || {Edge, Prv} <- EPs].

-spec(report_invalid_provenence(ergo:workspace_name(), ergo:build_id(), ergo:taskname(), {edge_record(), #provenence{}}) -> ok).
report_invalid_provenence(Workspace, BuildId, About, {Edge, #provenence{task=Asserter}}) ->
  ergo_events:invalid_provenence(Workspace, BuildId, About, Asserter, statement_for_edge(Edge)).


report_invalid_provenences(EPs, Task, BuildId, State=#state{workspace=Workspace}) ->
  _State = dump_to(State),
  [report_invalid_provenence(Workspace, BuildId, Task, EP) || EP <- EPs].

remove_task_by_name(TaskName, State=#state{vertices=Vs}) ->
  remove_task_vertex(task_by_name(TaskName, State), Vs).

remove_task_vertex(no_task_recorded, _Vs) ->
  ok;
remove_task_vertex(TaskV, Vs) ->
  ets:delete_object(Vs, TaskV).

remove_task(TaskName, State) ->
  InvalidEdges = edges_about_task(TaskName, State),
  InvProvs = provenence_about_edges(InvalidEdges, State),

  remove_task_by_name(TaskName, State),
  _ = remove_task_provenences(TaskName, State),
  _ = remove_edge_pairs(InvProvs, State),
  InvProvs.

edges_about_task(Task, State) ->
  qlc:eval( qlc:append(
              [
               meta_about_task(Task, State),
               seq_about_task(Task, State),
               also_about_task(Task, State),
               production_about_task(Task, State),
               requirement_about_task(Task, State)
              ])).

meta_about_task(Task, #state{edges=Es}) ->
  qlc:q([Edge || Edge=#task_meta{about=T} <- ets:table(Es), Task =:= T]).

seq_about_task(Task, #state{edges=Es}) ->
  qlc:q([Edge || Edge=#seq{before=B,then=T} <- ets:table(Es), (B =:= Task) or (T =:= Task)]).

also_about_task(Task, #state{edges=Es}) ->
  qlc:q([Edge || Edge=#cotask{task=B,also=T} <- ets:table(Es), (B =:= Task) or (T =:= Task)]).

production_about_task(Task, #state{edges=Es}) ->
  qlc:q([Edge || Edge=#production{task=T} <- ets:table(Es), T =:= Task]).

requirement_about_task(Task, #state{edges=Es}) ->
  qlc:q([Edge || Edge=#requirement{task=T} <- ets:table(Es), T =:= Task]).






%%% Persistence
%%%

build_state(WorkspaceRoot) ->
  build_state(WorkspaceRoot, protected).

build_state(WorkspaceRoot, Access) ->
  State = construct_state(WorkspaceRoot),
  load_from(State, Access).

cleanup_state(#state{edges=Etab,vertices=Vtab,provenence=Ptab}) ->
  maybe_delete_table(Etab),
  maybe_delete_table(Vtab),
  maybe_delete_table(Ptab),
  ok.

-ifdef(EUNIT).
clobber_files(WorkspaceRoot) ->
  [file:delete([depgraph_path_for(WorkspaceRoot), TabKind]) || TabKind <- [".vtab", ".etab", ".ptab"]].
-endif.

depgraph_path_for(Workspace) ->
  [Workspace, "/.ergo/depgraph"].

dump_to(State=#state{workspace=Workspace}) ->
  dump_to(State, depgraph_path_for(Workspace)).

-spec dump_to(#state{}, file:name()) -> #state{}.
dump_to(State=#state{vertices=VTab, edges=ETab, provenence=PTab}, FilenameBase) ->
  ok = filelib:ensure_dir(FilenameBase),
  ok = ets:tab2file(VTab, [FilenameBase, ".vtab"]),
  ok = ets:tab2file(ETab, [FilenameBase, ".etab"]),
  ok = ets:tab2file(PTab, [FilenameBase, ".ptab"]),
  State.

load_from(State) ->
  load_from(State, protected).

load_from(State=#state{workspace=Workspace}, Access) ->
  load_from(State, depgraph_path_for(Workspace), Access).

-spec load_from(#state{}, file:name(), public | protected) -> #state{}.
load_from(State, FilenameBase, Access) ->
  ETab = load_or_build([FilenameBase, ".etab"], edges, bag, Access),
  VTab = load_or_build([FilenameBase, ".vtab"], vertices, set, Access),
  PTab = load_or_build([FilenameBase, ".ptab"], provenence, bag, Access),
  maybe_delete_table(State#state.edges),
  maybe_delete_table(State#state.vertices),
  maybe_delete_table(State#state.provenence),
  State#state{edges = ETab, vertices = VTab, provenence = PTab}.

load_or_build(Filename, TableName, Type, Access) ->
  case ets:file2tab(Filename) of
    {ok, Tab} ->
      Tab;
    {error, _Error} ->
      Tab = build_table(TableName, Type, Access),
      Tab
  end.

build_table(vertices, Type, Access) ->
  VTab = ets:new(vertices, [Type, Access, {keypos, 2}]),
  ets:insert(VTab, #next_id{kind=edge_ids, value=0}),
  ets:insert(VTab, #next_id{kind=batch_ids, value=0}),
  VTab;
build_table(Name, Type, Access) ->
  ets:new(Name, [Type, Access, {keypos, 2}]).

maybe_delete_table(undefined) ->
  ok;
maybe_delete_table(Table) ->
  case ets:info(Table) of
    undefined -> ok;
    _Info -> ets:delete(Table)
  end.


%%%%%%%%%%%%%%

construct_state(WorkspaceRoot) ->
  Workspace = filename:absname(WorkspaceRoot),
  {ok,Regex} = re:compile(["^", filename:flatten(Workspace), "/"]),
  #state{ workspace = Workspace, workspace_root_re = Regex }.

update_batch_id(State=#state{vertices=VerTab}) ->
  State#state{removed_id  = ets:update_counter(VerTab, batch_ids, {#next_id.value, 1}),
              batch_id = ets:update_counter(VerTab, batch_ids, {#next_id.value, 1})}.


-record(batch_status, {
          changed,
          build_id,
          taskname,
          workspace,
          state,
          contradictions,
          disclaimers
         }).

-record(contradictions, { self, whole }).

-spec(maybe_notify_changed(boolean(), ergo:build_id(), ergo:taskname(), #state{}) -> change_report()).
maybe_notify_changed(Changed, BuildId, Taskname, State) ->
  maybe_notify_changed(#batch_status{changed=Changed, build_id=BuildId, taskname=Taskname, state=State}).



maybe_notify_changed(#batch_status{changed=false}) ->
  {ok, no_change};

maybe_notify_changed(Status=#batch_status{contradictions=undefined,taskname=Taskname,state=State}) ->
  {Self,Whole} = ergo_graph_contradictions:resolve(Taskname, State),
  maybe_notify_changed(Status#batch_status{contradictions=#contradictions{self=Self,whole=Whole}});
maybe_notify_changed(Status=#batch_status{disclaimers=undefined,taskname=Taskname,state=State}) ->
  maybe_notify_changed(Status#batch_status{disclaimers=ergo_graph_disclaims:resolve(Taskname, State)});

maybe_notify_changed(#batch_status{
                        disclaimers=[],
                        contradictions=#contradictions{self=[],whole=Contras},
                        build_id=BuildId, taskname=Taskname, state=State=#state{workspace=Workspace}}) ->
  report_contradictions(Workspace, BuildId, Taskname, Contras),
  _S = dump_to(State),
  ergo_events:graph_changed(Workspace),
  {ok, changed};
maybe_notify_changed(#batch_status{
                        disclaimers=[],
                        contradictions=#contradictions{self=List},
                        build_id=BuildId, taskname=Taskname, state=#state{workspace=Workspace}}) ->
  report_contradictions(Workspace, BuildId, Taskname, List),
  {err, {self_contradictions, List}};
maybe_notify_changed(#batch_status{
                        disclaimers=List,
                        build_id=BuildId, taskname=Taskname, state=State=#state{workspace=Workspace}}) ->
  report_production_disclaimers(Workspace, BuildId, Taskname, List),
  _S = dump_to(State),
  {err, {disclaimed_production, List}}.

-spec(report_production_disclaimers(ergo:workspace_name(), ergo:build_id(), ergo:taskname(), [ergo_graph_disclaims:report()]) -> ok).
report_production_disclaimers(Workspace, BuildId, Taskname, List) ->
  ergo_events:disclaimed_production(Workspace, BuildId, Taskname, List).

report_contradictions(Workspace, BuildId, Taskname, Contras) ->
  [ ergo_events:graph_contradiction(Workspace, BuildId, Taskname, Contra) || Contra <- Contras],
  ok.

-spec(process_task_batch(ergo:taskname(), [ergo:graph_item()], boolean(), #state{}) -> true | false).
process_task_batch(Taskname, ReceivedItems, false, State) ->
  {CurrentItems, KnownItems} = comparable_items(State, ReceivedItems, Taskname),
  tag_old_statements(KnownItems -- CurrentItems, State),
  add_statements(CurrentItems -- KnownItems, State, Taskname);
process_task_batch(Taskname, ReceivedItems, true, State) ->
  {CurrentItems, KnownItems} = comparable_items(State, ReceivedItems, Taskname),
  add_statements(CurrentItems -- KnownItems, State, Taskname) or
    remove_statements(KnownItems -- CurrentItems, State, Taskname).

% returns { CurrentItems, NewItems }
comparable_items(State, ReceivedItems, Taskname) ->
  { normalize_items(State, ReceivedItems), items_for_task(State, Taskname) }.


add_statements(NewItems, State, Taskname) ->
  change_graph(NewItems, State, Taskname, fun add_statement/3).

remove_statements(MissingItems, State, Taskname) ->
  change_graph(MissingItems, State, Taskname, fun del_statement/3).

tag_old_statements(OldItems, State=#state{edges=Edges, removed_id=RemovedId}) ->
  {Keeps, All} = lists:foldl( fun(Item, {Keeps,All}) ->
                             case add_statement(State, edge_for_statement(Item)) of
                               {ok, Edge} -> {[Keeps], [Edge | All]};
                               {exists, Edge} -> {[Edge | Keeps], [Edge | All]}
                             end
                         end, {[],[]}, OldItems),
  [ ets:delete_object(Edges, Edge) || Edge <- All ],
  ets:insert(Edges, [setelement(#seq.removed_id, Edge, RemovedId) || Edge <- Keeps]).


change_graph(Items, State, Taskname, Fun) ->
  Acc = fun(Item, Acc) -> Fun(State, Taskname, Item) or Acc end,
  lists:foldl(Acc, false, Items).

-spec add_statement(#state{}, ergo:taskname(), ergo:graph_item()) -> true | false.
add_statement(State=#state{provenence=Provs}, Taskname, Item) ->
  {Newness, Edge} = add_statement(State, edge_for_statement(Item)),
  EdgeId = element(#seq.edge_id, Edge),
  ets:insert(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case Newness of
    ok -> true;
    exists -> false
  end.

%XXX this should be "remove support" or something
del_statement(State=#state{provenence=Provs,edges=Edges}, Taskname, Item) ->
  {_, Edge} = add_statement(State, edge_for_statement(Item)), % XXX
  EdgeId = element(#seq.edge_id, Edge),
  ets:delete_object(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case ets:lookup(Provs, EdgeId) of
    [] -> ets:delete_object(Edges, Edge), true;
    _ -> false
  end.

remove_statement({prod, Task, Product}, State=#state{edges=Es}) ->
  Ids = [Id || [Id] <- ets:match(Es, #production{edge_id='$1', task=Task, produces=Product, _='_'})],
  [ remove_edge_with_id(Id, State) || Id <- Ids ].

remove_edge_with_id(Id, #state{edges=Es, provenence=Ps}) ->
  ets:delete(Es, Id),
  ets:match_delete(Ps, #provenence{edge_id=Id, _='_'}).


-spec(normalize_product_name(#state{}, productname()) -> normalized_product()).
normalize_product_name(#state{workspace_root_re=Regex,workspace=WS}, Name) ->
  re:replace(filename:flatten(filename:absname(Name,WS)), Regex, "", [{return,list}]).

normalize_items(State, Items) ->
  [ normalize_batch_statement(State, Item) || Item <- Items ].

items_for_task(#state{edges=Edges,provenence=Provs}, Taskname) ->
  [ statement_for_edge(Edge) ||
    Edge <- qlc:eval(qlc:q( [ Edge ||
              Edge <- ets:table(Edges),
              Prov <- ets:table(Provs),
              Prov#provenence.task =:= Taskname,
              Prov#provenence.edge_id =:= element(#seq.edge_id, Edge)
            ]))
  ].

-spec(edge_for_statement(ergo:graph_item())              -> edge_record()).
edge_for_statement({seq, A, B})                          -> #seq{before=A, then=B};
edge_for_statement({co, T, A})                           -> #cotask{task=T, also=A};
edge_for_statement({prod, T,P})                          -> #production{task=T, produces=P};
edge_for_statement({req, T, P})                          -> #requirement{task=T, requires=P};
edge_for_statement({dep, A, B})                          -> #dep{from=A, to=B};
edge_for_statement({file_meta, P, N, V})                 -> #file_meta{about=P, name=N, value=V};
edge_for_statement({task_meta, T, N, V})                 -> #task_meta{about=T, name=N, value=V};
edge_for_statement(Statement)                            -> {err, {unrecognized_statement, Statement}}.


-spec(statement_for_edge(edge_record())                  -> ergo:graph_item()).
statement_for_edge(#seq{before=A,then=B})                -> {seq, A, B};
statement_for_edge(#cotask{task=T,also=A})               -> {co, T, A};
statement_for_edge(#production{task=T,produces=Product}) -> {prod, T, Product};
statement_for_edge(#requirement{task=T, requires=P})     -> {req, T, P};
statement_for_edge(#dep{from=From,to=To})                -> {dep, From, To};
statement_for_edge(#task_meta{about=A,name=N, value=V})  -> {task_meta, A, N, V};
statement_for_edge(#file_meta{about=A,name=N, value=V})  -> {file_meta, A, N, V};
statement_for_edge(Edge)                                 -> {err, {unrecognized_edge, Edge}}.

normalize_batch_statement(State, {dep, FromProd, ToProd}) ->
  {dep,
   normalize_product_name(State, FromProd),
   normalize_product_name(State, ToProd)};
normalize_batch_statement(State, {req, Task, Prod}) ->
  {req,
   Task,
   normalize_product_name(State, Prod)};
normalize_batch_statement(State, {prod, Task, Prod}) ->
  {prod,
   Task,
   normalize_product_name(State, Prod)};
normalize_batch_statement(State, {file_meta, Prod, Name, Value}) ->
  {file_meta,
   normalize_product_name(State, Prod),
   Name, Value};
normalize_batch_statement(_State, Stmt={co, _, _}) ->
  Stmt;
normalize_batch_statement(_State, Stmt={seq, _, _}) ->
  Stmt;
normalize_batch_statement(_State, Stmt={task_meta, _, _, _}) ->
  Stmt;
normalize_batch_statement(_State, Statement) ->
  {err, {unrecognized_batch_statement, Statement}}.


-spec add_statement(#state{}, edge_record()) -> {ok, edge_record()} | {exists,edge_record()}.
add_statement(State, Edge = #seq{before=Before,then=Then}) ->
  add_task(State, Before), add_task(State, Then),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, seq), E#seq.before =:= Before, E#seq.then =:= Then]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #cotask{task=Task,also=Also}) ->
  add_task(State, Task), add_task(State, Also),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, cotask), E#cotask.task =:= Task, E#cotask.also =:= Also]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #requirement{task=Task,requires=Product}) ->
  add_task(State, Task), add_product(State, Product),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, requirement), E#requirement.task =:= Task,
                         E#requirement.requires =:= Product]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #file_meta{about=Product,name=Name,value=Value}) ->
  add_product(State, Product),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, file_meta), E#file_meta.about =:= Product,
                         E#file_meta.name =:= Name, E#file_meta.value =:= Value]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #task_meta{about=Task,name=Name,value=Value}) ->
  add_task(State, Task),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, task_meta), E#task_meta.about =:= Task,
                         E#task_meta.name =:= Name, E#task_meta.value =:= Value]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #production{task=Task,produces=Product}) ->
  add_task(State, Task), add_product(State, Product),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, production), E#production.task =:= Task,
                         E#production.produces =:= Product]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #dep{from=From,to=To}) ->
  add_product(State, From), add_product(State, To),
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, dep), E#dep.from =:= From, E#dep.to =:= To]),
  insert_edge(State, Edge, Query).


insert_edge(State=#state{edges=EdgeTable,batch_id=BatchId}, Edge, Query) ->
  case qlc:eval(Query) of
    [] ->
      EdgeWithIds = set_edge_ids(Edge, BatchId, State),
      true = ets:insert(EdgeTable, EdgeWithIds),
      {ok, EdgeWithIds};
    FoundList -> {exists, hd(FoundList)}
  end.

set_edge_ids(Edge, BatchId, State) ->
  EdgeWithId = setelement(#seq.edge_id, Edge, next_edge_id(State)),
  setelement(#seq.batch_id, EdgeWithId, BatchId).


add_product(State, ProductName) ->
  add_vertex_if_missing(State, #product{name=ProductName}).

add_task(State, TaskName) ->
  add_vertex_if_missing(State, #task{name=TaskName}).

add_vertex_if_missing(#state{vertices=Vertices}, Vertex) ->
  ets:insert_new(Vertices, Vertex), ok.

next_edge_id(#state{vertices=Vertices}) ->
  ets:update_counter(Vertices, edge_ids, {#next_id.value, 1}).

% Products for a task
-spec(products(#state{}, ergo:task()) -> [ergo:produced()]).
products(State, {task, TaskName}) ->
  qlc:eval(qlc:q([ E#production.produces || E <- ets:table(State#state.edges), is_record(E,production),
                                            E#production.task =:= TaskName ])).

-spec(dependencies(#state{}, ergo:produced() | ergo:task()) -> [ergo:productname()]).
dependencies(State, {product, ProductName}) ->
  prod_deps(State, ProductName);
dependencies(State, {task, TaskName}) ->
  task_deps(State, TaskName).

-spec(prod_deps(#state{}, ergo:productname()) -> [ergo:productname()]).
prod_deps(State, ProductName) ->
  qlc:eval(prod_dep_query(State, ProductName)).

-spec(task_deps(#state{}, ergo:taskname()) -> [ergo:productname()]).
task_deps(State, TaskName) ->
  qlc:eval(task_deps_query(State, TaskName)).

handle_get_metadata({task, Taskname}, State) ->
  get_task_metadata(Taskname, State);
handle_get_metadata({produced, Product}, State) ->
  get_product_metadata(normalize_product_name(State, Product), State).

get_task_metadata(Taskname, #state{edges=Edges}) ->
  qlc:eval(qlc:q([ {Md#task_meta.name, Md#task_meta.value} || Md <- ets:table(Edges),
                           is_record(Md, task_meta), Md#task_meta.about =:= Taskname ])).

get_product_metadata(Product, #state{edges=Edges}) ->
  qlc:eval(qlc:q([ {Md#file_meta.name, Md#file_meta.value} || Md <- ets:table(Edges),
                           is_record(Md, file_meta), Md#file_meta.about =:= Product ])).

% Not currently used, but seems useful from a symmetry standpoint
%-spec(task_products_query(#state{}, taskname()) -> qlc:query_handle()).
%task_products_query(#state{vertices=Vertices, edges=Edges}, TaskName) ->
%  qlc:q([Product || Product <- ets:table(Vertices), Production <- ets:table(Edges),
%                    Product#product.name =:= Production#production.produces,
%                    Production#production.task =:= TaskName ]).

-spec(handle_build_list(#state{}, [ergo:target()]) -> {#state{}, ergo:build_spec()}).
handle_build_list(BaseState, Targets) ->
  State = load_from(BaseState),
  {State, run_build_list(State, targets_to_tasks(State, Targets))}.


targets_to_tasks(State, Targets) ->
  TasksList = tasks_from_targets(State, Targets),
  case [Error || {error, Error} <- TasksList] of
    [] -> [Taskname || {task, Taskname} <- TasksList];
    ErrorList -> {error, ErrorList}
  end.

run_build_list(_State, Errors={error, _}) ->
  Errors;
run_build_list(State, TargetTasks) ->
  SeqGraph = seq_graph(State),
  AlsoGraph = also_graph(State),

  TargetVertices = tasknames_to_vertices(AlsoGraph, TargetTasks),
  BaseTasknames = vertices_to_tasknames(AlsoGraph, digraph_utils:reachable(TargetVertices, AlsoGraph)),
  DeterminedBy = determining_edges(SeqGraph, AlsoGraph, BaseTasknames),
  Endorsers = extra_endorser_tasks(DeterminedBy, BaseTasknames, State),

  AllVertices = tasknames_to_vertices(AlsoGraph, TargetTasks ++ Endorsers),
  NeededTasknames = vertices_to_tasknames(AlsoGraph, digraph_utils:reachable(AllVertices, AlsoGraph)),

  SeqVs = digraph_utils:topsort(digraph_utils:subgraph(SeqGraph, tasknames_to_vertices(SeqGraph, NeededTasknames))),
  Specs = [{taskname_from_vertex(SeqGraph, TV),
            [taskname_from_vertex(SeqGraph, PredTask) || PredTask <- digraph_utils:reaching_neighbours([TV], SeqGraph)]
           } || TV <- SeqVs ],
  digraph:delete(AlsoGraph), digraph:delete(SeqGraph),
  add_unknown_tasks(TargetTasks, Specs).

add_unknown_tasks([], Specs) ->
  Specs;
add_unknown_tasks([Task | Rest], Specs) ->
  add_unknown_tasks(
    Rest,
    maybe_add_task(
      Task,
      Specs,
      [ Spec || Spec={KnownTask, _List} <- Specs, KnownTask =:= Task ]
     )
   ).

maybe_add_task(Task, Specs, []) ->
  [ {Task,[]} | Specs ];
maybe_add_task(_Task, Specs, _Matched) ->
  Specs.

extra_endorser_tasks(Edges, KnownTasks, State = #state{provenence=Prov}) ->
  {TaskDict, EdgeDict} = lists:foldl(fun(EdgeId, {TDict, EDict}) ->
                                         lists:foldl(fun(#provenence{task=Taskname}, {TaskDict, EdgeDict}) ->
                                                         {
                                                          dict:update(Taskname, fun(List) -> [EdgeId | List] end, [], TaskDict),
                                                          dict:update(EdgeId, fun(List) -> [Taskname | List] end, [], EdgeDict)
                                                         }
                                                     end,
                                                     {TDict, EDict},
                                                     ets:lookup(Prov, EdgeId))
                                     end,
                                     {dict:new(), dict:new()}, Edges -- edges_endorsed_by(State, KnownTasks)),
  reduced_endorser_set(TaskDict, EdgeDict, []).

edges_endorsed_by(#state{provenence=Prov}, Tasklist) ->
  gb_sets:to_list(
    lists:foldl(fun(T, Set) ->
                    lists:foldl(fun(Id, S) -> gb_sets:add(Id, S) end,
                                Set, qlc:eval(qlc:q([EdgeId ||
                                                          #provenence{edge_id=EdgeId, task=Task} <- ets:table(Prov), Task =:= T])))
                end, gb_sets:new(), Tasklist)).

reduced_endorser_set(Tasks, Edges, Chosen) ->
  case dict:is_empty(Edges) of
    true -> Chosen;
    _ ->
      NewChoice = choose_task(Tasks, Edges),
      reduced_endorser_set(dict:erase(NewChoice, Tasks), satisfy_edges(NewChoice, Tasks, Edges), [NewChoice | Chosen])
  end.

choose_task(Tasks, Edges) ->
  case first_singular_task(dict:fetch_keys(Edges), Edges) of
    {ok, Task} -> Task;
    _ -> most_edges(dict:fetch_keys(Tasks), Tasks)
  end.

first_singular_task([EdgeId | Rest], Edges) ->
  Tasks = dict:fetch(EdgeId, Edges),
  case length(Tasks) of
    1 -> {ok, hd(Tasks)};
    _ -> first_singular_task(Rest, Edges)
  end;
first_singular_task([], _Edges) ->
  none.

% XXX Concerned here that this function only gets used if an invariant has been violated...
most_edges([], _) ->
  none;
most_edges([Task | Rest], Tasks) ->
  most_edges(Rest, Tasks, Task, length(dict:fetch(Task, Tasks))).

most_edges([], _, Chosen, _) ->
  Chosen;
most_edges([Task | Rest], Dict, Chosen, Count) ->
  NewCount = length(dict:fetch(Task, Dict)),
  if Count < NewCount -> most_edges(Rest, Dict, Task, NewCount);
     true -> most_edges(Rest, Dict, Chosen, Count)
  end.

satisfy_edges(Task, Tasks, Edges) ->
  lists:foldl(fun(Edge, EdgeDict) ->
                  dict:erase(Edge, EdgeDict)
              end, Edges, dict:fetch(Task, Tasks)).

seq_subgraph(SeqGraph, Tasknames) ->
  TaskVs = tasknames_to_vertices(SeqGraph, Tasknames),
  Reachable = gb_sets:from_list(digraph_utils:reachable(TaskVs, SeqGraph)),
  Reaching = gb_sets:from_list(digraph_utils:reaching(TaskVs, SeqGraph)),
  SubVs = gb_sets:to_list(gb_sets:intersection(Reachable, Reaching)),
  digraph_utils:subgraph(SeqGraph, SubVs).

also_subgraph(Graph, Tasknames) ->
  digraph_utils:subgraph(Graph, tasknames_to_vertices(Graph, Tasknames)).

-spec(determining_edges(digraph:graph(), digraph:graph(), [taskname()]) -> [edge_id()]).
determining_edges(SeqGraph, AlsoGraph, Tasknames) ->
  EdgeSet = collect_edge_ids(seq_subgraph(SeqGraph, Tasknames),
                             collect_edge_ids(also_subgraph(AlsoGraph, Tasknames), gb_sets:new())),
  gb_sets:to_list(EdgeSet).

-spec(collect_edge_ids(digraph:graph(), gb_sets:set())-> gb_sets:set(edge_id())).
collect_edge_ids(Subgraph, EdgeSet) ->
  lists:foldl(
    fun({_E, _V1, _V2, #edge_label{from_edges=Edges}}, Set) ->
        lists:foldl(fun gb_sets:add/2, Set, Edges)
    end,
    EdgeSet, [ digraph:edge(Subgraph, E) || E <- digraph:edges(Subgraph) ]).

taskname_from_vertex(Graph, Vertex) ->
  {_V, Taskname} = digraph:vertex(Graph, Vertex),
  Taskname.

-spec(vertices_to_tasknames(digraph:graph(), [digraph:vertex()]) -> [taskname()]).
vertices_to_tasknames(Graph, Vertices) ->
  [ Label || {_Vert, Label} <- [digraph:vertex(Graph, Vertex) || Vertex <- Vertices ]].

-spec(tasknames_to_vertices(digraph:graph(), [taskname()]) -> [digraph:vertex()]).
tasknames_to_vertices(Graph, Tasknames) ->
  [ Vert || {Vert, Label} <- [digraph:vertex(Graph, Vertex) || Vertex <- digraph:vertices(Graph)],
            Taskname <- Tasknames, Label =:= Taskname ].


-spec(also_graph(#state{}) -> digraph:graph()).
also_graph(State) -> intermediate_graph(State, digraph:new(), all_cotask_edges(State)).

-spec(seq_graph(#state{}) -> digraph:graph()).
seq_graph(State) -> intermediate_graph(State, digraph:new([acyclic]), all_seq_edges(State)).

-spec(intermediate_graph(#state{}, digraph:graph(), [edge_record()]) -> digraph:graph()).
intermediate_graph(State, Graph, EdgeList) ->
  TaskLookup = task_cache(Graph, all_tasks(State)),
  _ = [ add_intermediate_edge(Edge, TaskLookup, Graph) || Edge <- EdgeList ],
  Graph.

add_intermediate_edge(Edge, TaskLookup, Graph) ->
  BeforeV = gb_trees:get(element(#gen_edge.from, Edge), TaskLookup),
  ThenV = gb_trees:get(element(#gen_edge.to, Edge), TaskLookup),
  digraph:add_edge(Graph, BeforeV, ThenV, #edge_label{from_edges=element(#gen_edge.implied_by, Edge)}).

task_cache(Graph, Tasks) ->
  lists:foldl( fun(Task, TaskLookup) ->
                   cache_one_task(Task, Graph, TaskLookup)
               end, gb_trees:empty(), Tasks).

cache_one_task(#task{name=Name}, Graph, TaskLookup) ->
  gb_trees:insert(Name,
                  digraph:add_vertex(Graph, digraph:add_vertex(Graph), Name),
                  TaskLookup).

-spec(all_tasks(#state{}) -> [#task{}]).
all_tasks(#state{vertices=Vertices}) ->
  qlc:eval(qlc:q([Task || Task <- ets:table(Vertices), is_record(Task, task)])).

-spec(task_by_name(ergo:taskname(), #state{}) -> #task{} | no_task_recorded).
task_by_name(Name, #state{vertices=Vs}) ->
  case qlc:eval(qlc:q([Task || Task=#task{name=N} <- ets:table(Vs), N =:= Name])) of
    [] ->
      no_task_recorded;
    [Task | _] -> Task
  end.

-spec(all_seq_edges(#state{}) -> [#seq{}]).
all_seq_edges(State) ->
  qlc:eval(qlc:append([dep_implied_seq_query(State), req_implied_seq_query(State), explicit_seq_query(State)])).

dep_implied_seq_query(State) ->
  qlc:q([Edge || Edge <- task_to_task_dep_query(State)]).

req_implied_seq_query(State) ->
  qlc:q([Edge || Edge <- task_to_task_req_query(State)]).

explicit_seq_query(#state{edges=Edges}) ->
  qlc:q([#gen_edge{from=Seq#seq.before, to=Seq#seq.then, implied_by=[Seq#seq.edge_id]} ||
         Seq <- ets:table(Edges), is_record(Seq, seq)]).

-spec(all_cotask_edges(#state{}) -> [#cotask{}]).
all_cotask_edges(State) ->
  qlc:eval(qlc:append([dep_implied_cotask_query(State), req_implied_cotask_query(State), explicit_cotask_query(State)])).

-spec(prod_dep_query(#state{}, productname()) -> qlc:query_handle()).
prod_dep_query(#state{edges=Edges}, ProductName) ->
  qlc:q([ Dep#dep.to || Dep <- ets:table(Edges), Dep#dep.from =:= ProductName ]).

-spec(task_deps_query(#state{}, taskname()) -> qlc:query_handle()).
task_deps_query(State, TaskName) ->
  qlc:append([explicit_task_req_query(State, TaskName), dep_implied_task_req_query(State, TaskName)]).

explicit_task_req_query(#state{edges=Edges}, TaskName) ->
  qlc:q([Req || #requirement{task=T,requires=Req} <- ets:table(Edges), T=:=TaskName]).

dep_implied_task_req_query(#state{edges=Edges}, TaskName) ->
  qlc:q([To || #production{task=PT, produces=P1} <- ets:table(Edges),
               #dep{from=P2, to=To} <- ets:table(Edges),
               TaskName =:= PT, P1 =:= P2 ]).


dep_implied_cotask_query(State) ->
  qlc:q([#gen_edge{from=From,to=To,implied_by=ImpliedBy} ||
         #gen_edge{from=To,to=From,implied_by=ImpliedBy} <- task_to_task_dep_query(State)]).

req_implied_cotask_query(State) ->
  qlc:q([#gen_edge{from=From,to=To,implied_by=ImpliedBy} ||
         #gen_edge{from=To,to=From,implied_by=ImpliedBy} <- task_to_task_req_query(State)]).

explicit_cotask_query(#state{edges=Edges}) ->
  qlc:q([#gen_edge{from=Also#cotask.task, to=Also#cotask.also, implied_by=[Also#cotask.edge_id]} ||
         Also <- ets:table(Edges), is_record(Also, cotask)]).



% A Req + Pdctn edge imply a Seq and a reverse Cotask edge
%  (Prior) -----+
%                \
%     ^           \
%     |            \
%  [Seq/            \
%    Cotask]       Req
%     |               \
%     v                \
%                       \
%                        \
%                        _|
%  (Post) --- Pdctn --> (Prod)
-spec(task_to_task_req_query(#state{}) -> qlc:query_handle()).
task_to_task_req_query(#state{edges=Edges}) ->
  qlc:q([#gen_edge{from=PT, to=RT, implied_by=[PI,RI]} ||
         #production{task=PT, edge_id=PI, produces=PP} <- ets:table(Edges),
         #requirement{task=RT, edge_id=RI, requires=RR} <- ets:table(Edges),
         PP =:= RR
        ]).


% The PriorPdctn, Depcy and PostPdctn edges imply a Seq edge (and a reverse Cotask)
%    ( Prior  ) --- PriorPdctn -- > (Dep)
%     |      ^                        |
%     |      |                        |
%   [Seq] [Cotask]                  Depcy
%     |      |                        |
%     v      |                        v
%    (  Post  ) --- PostPdctn ---> (Prod)
-spec(task_to_task_dep_query(#state{}) -> qlc:query_handle()).
task_to_task_dep_query(#state{edges=Edges}) ->
  Q = qlc:q([ {DI, AI, DT, AT} ||
         #dep{edge_id=DI, from=DF, to=DT} <- ets:table(Edges),
         #production{task=AT, edge_id=AI, produces=AP} <- ets:table(Edges),
         DF =:= AP ]),
  qlc:q([#gen_edge{from=BT, to=AT, implied_by=[BI,DI,AI]} ||
         #production{task=BT, edge_id=BI, produces=BP} <- ets:table(Edges),
         {DI, AI, DT, AT} <- Q,
         BP =:= DT
        ]).


-spec(tasks_from_targets(#state{}, [ergo:target()]) -> [ergo:task()|{error,term()}]).
tasks_from_targets(State, Targets) ->
  [ task_from_target(State, Target) || Target <- Targets ].

task_from_target(State, {product,Product}) ->
  task_or_error(task_for_product(State, Product), Product);
task_from_target(_, Target={task,_}) ->
  Target.

task_or_error([], Product) -> {error, {no_task_produces, Product}};
task_or_error([#task{name=Name}], _P) -> {task, Name};
task_or_error(FoundTasks, Product) -> {error, {violated_invariant, single_producer, Product, FoundTasks}}.

% Task for product
-spec(task_for_product(#state{}, productname()) -> [#task{}] | {error, term()}).
task_for_product(#state{edges=Edges,vertices=Vertices}, ProductName) ->
  TaskQ = qlc:q([ V || E <- ets:table(Edges), V <- ets:table(Vertices),
                       E#production.produces =:= ProductName, E#production.task =:= V#task.name ]),
  qlc:eval(TaskQ).


% find_product_vertex(State, ProductName) ->
%   single_vertex(qlc:q([V || V <- ets:table(State#state.vertices),
%                             is_record(V, product), V#product.name =:= ProductName])).
% single_vertex(Query) ->
%   case length(FoundVertices = qlc:eval(Query)) of
%     1 -> {ok, hd(FoundVertices)};
%     0 -> false;
%     _ -> {error, {violated_invariant, single_vertex_per_entity}}
%   end.


-ifdef(TEST).
%%% Tests
digraph_test_() ->
  ProductName = "x.out",
  DependsOn = "x.in",
  TaskName = [<<"compile">>,  <<"x">>],
  OtherTaskName = [<<"test">>, <<"x">>],
  {foreach, %local, %digraphs are trapped in their process
    fun() ->
        dbg:tracer(),
        clobber_files("graph-test"), update_batch_id(build_state("graph-test", public))
    end, %setup
    fun(State) ->
        cleanup_state(State), clobber_files("graph-test"),
        {ok,_} = dbg:p(all, clear)
    end, %teardown
    [

     fun(State) ->
         ?_test(begin
                  {_NewState, List} = handle_build_list(State, [{task, [<<"new-task">>, <<"with-arg">>]}]),
                  ?assertMatch([{[<<"new-task">>, <<"with-arg">>], []}], List)
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch(true,
                               process_task_batch(TaskName, [ {file_meta, ProductName, fresh, digest} ], true, State)),
                  ?assertMatch(false,
                               process_task_batch(TaskName, [ {file_meta, ProductName, fresh, digest} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch(true,
                               process_task_batch(TaskName, [ {task_meta, TaskName, fresh, digest} ], true, State)),
                  ?assertMatch(false,
                               process_task_batch(TaskName, [ {task_meta, TaskName, fresh, digest} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges))),
                  ?assertEqual([{fresh, digest}],
                               handle_get_metadata({task, TaskName}, State))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  process_task_batch(TaskName, [ {req, TaskName, DependsOn} ], true, State),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges))),
                  ?assertEqual([DependsOn], task_deps(State, TaskName))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch(true,
                               process_task_batch(TaskName, [ {dep, ProductName, DependsOn} ], true, State)),
                  ?assertMatch(false,
                               process_task_batch(TaskName, [ {dep, ProductName, DependsOn} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) -> % invalid task is removed
         ?_test(begin
                  process_task_batch(OtherTaskName, [
                                                     {prod, TaskName, ProductName},
                                                     {req, OtherTaskName, ProductName}
                                                    ], true, State),
                  ?assertMatch([#task{name=TaskName}], ets:select(State#state.vertices, [{#task{name=TaskName, _='_'},[],['$_']}])),
                  Pairs = remove_task(TaskName, State),
                  ?assertNotEqual(length(Pairs), 0),
                  ?assertNotMatch([#task{name=TaskName}], ets:select(State#state.vertices, [{#task{name=TaskName, _='_'},[],['$_']}])),
                  {_NewState,List} = handle_build_list(dump_to(State), [{task, OtherTaskName}]),
                  ?assertEqual([{OtherTaskName, []}], List)
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch(true,
                               process_task_batch(TaskName, [
                                                             {prod, TaskName, ProductName},
                                                             {file_meta, ProductName, fresh, digest},
                                                             {task_meta, TaskName,    fresh, digest}

                                                            ], true, State)),
                  ?assertEqual({[],[]},
                               ergo_graph_contradictions:resolve( TaskName, State )),
                  NewState = update_batch_id(State),
                  ?assertMatch(true,
                               process_task_batch(OtherTaskName, [ {prod, OtherTaskName, ProductName},
                                                                   {file_meta, ProductName, fresh, never},
                                                                   {task_meta, TaskName,    fresh, never}

                                                                 ], true, NewState)),
                  ?assertMatch({_,[_,_,_]},
                               ergo_graph_contradictions:resolve( OtherTaskName, NewState )),
                  ?assertMatch([_,_,_], ets:tab2list(State#state.edges))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch(true,
                               process_task_batch(TaskName, [ {prod, TaskName, ProductName} ], true, State)),
                  ?assertMatch(false,
                               process_task_batch(TaskName, [ {prod, TaskName, ProductName} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                   ?assertMatch(true,
                                process_task_batch(TaskName, [ {co, TaskName, OtherTaskName} ], true, State)),
                   ?assertMatch(false,
                                process_task_batch(TaskName, [ {co, TaskName, OtherTaskName} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                   ?assertMatch(true,
                                process_task_batch(TaskName, [ {seq, TaskName, OtherTaskName} ], true, State)),
                   ?assertMatch(false,
                                process_task_batch(TaskName, [ {seq, TaskName, OtherTaskName} ], true, State)),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test( begin
                   ?assertMatch(true,
                                process_task_batch(
                                  TaskName, [
                                             {dep, ProductName, DependsOn},
                                             {prod, TaskName, ProductName}
                                            ], true, State)),
                   ?assertEqual(
                      [DependsOn],
                      task_deps(State, TaskName)
                     )
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   {_NewState,List} = handle_build_list(dump_to(State), [{product, ProductName}]),
                   ?assertEqual( {error, [{no_task_produces, ProductName}]}, List)
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   ?assertMatch(true,
                                process_task_batch(
                                  TaskName, [
                                             { req, TaskName, DependsOn },
                                             { prod, OtherTaskName, DependsOn }
                                            ], true, State)),

                   {_NewState,List} = handle_build_list(dump_to(State), [{task, TaskName}]),
                   ?assertEqual(
                      [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                      List
                     )
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   ?assertMatch(true,
                                process_task_batch(TaskName,
                                                   [
                                                    {dep, ProductName, DependsOn},
                                                    {prod, OtherTaskName, DependsOn},
                                                    {prod, TaskName, ProductName}
                                                   ], true, State)),

                   {_NewState,List} = handle_build_list(dump_to(State), [{product, ProductName}]),
                   ?assertEqual( [{OtherTaskName, []},{TaskName, [OtherTaskName]}], List)
                 end)
     end
    ]
  }.
-endif.
