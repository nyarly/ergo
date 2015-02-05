-module(ergo_graphs).
-behavior(gen_server).
%% API
-export([start_link/1,
         dependency/3,requires/3,produces/3,joint_tasks/3,ordered_tasks/3,get_products/2,get_dependencies/2,build_list/2,task_batch/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(NOTEST, true).
-include_lib("eunit/include/eunit.hrl").

-include_lib("stdlib/include/qlc.hrl").

-define(VIA(WorkspaceName), {via, ergo_workspace_registry, {WorkspaceName, graph, only}}).
start_link(Workspace) ->
  gen_server:start_link({via, ergo_workspace_registry, {Workspace, graph, only}}, ?MODULE, [Workspace], []).

-type taskname() :: ergo:taskname().
-type productname() :: ergo:productname().
-type edge_id() :: integer().
-type normalized_product() :: string().

-record(task,    { name :: taskname(), command :: [binary()]}).
-record(product, { name :: productname() }).
-record(next_id, { kind :: atom(), value :: integer() }).

-record(seq, {
          edge_id :: edge_id(), before :: taskname(), then :: taskname() }).
-record(cotask, {
          edge_id :: edge_id(), task :: taskname(), also :: taskname() }).
-record(production, {
          edge_id :: edge_id(), task :: taskname(), produces :: normalized_product() }).
-record(requirement, {
          edge_id :: edge_id(), task :: taskname(), requires :: normalized_product() }).
-record(dep, {
          edge_id :: edge_id(), from :: normalized_product(), to :: normalized_product() }).
-type edge_record() :: #seq{} | #cotask{} | #production{} | #dep{}.

-record(provenence, { edge_id :: edge_id(), task :: taskname() }).
-record(edge_label, { from_edges :: [edge_id()] }).
-record(gen_edge,   { from :: taskname(), to :: taskname(), implied_by :: [edge_id()] }).

%% @spec:	requires(First::ergo:produced(), Second::ergo:produced()) -> ok.
%% @end
-spec(dependency(ergo:workspace_name(), ergo:produced(), ergo:produced()) -> ok).
dependency(Workspace, First, Second) ->
  gen_server:call(?VIA(Workspace), {new_dep, First, Second}).

%% @spec:	produces(Task::ergo:task(), Product::ergo:produced()) -> ok.
%% @end
-spec(produces(ergo:workspace_name(), ergo:task(), ergo:produced()) -> ok).
produces(Workspace, Task, Product) ->
  gen_server:call(?VIA(Workspace), {new_prod, Task, Product}).

%% @spec:	produces(Task::ergo:task(), Product::ergo:produced()) -> ok.
%% @end
-spec(requires(ergo:workspace_name(), ergo:task(), ergo:produced()) -> ok).
requires(Workspace, Task, Product) ->
  gen_server:call(?VIA(Workspace), {new_req, Task, Product}).

%% @spec:	joint_tasks(First::ergo:task(), Second::ergo:task()) -> ok.
%% @end
-spec(joint_tasks(ergo:workspace_name(), ergo:task(), ergo:task()) -> ok).
joint_tasks(Workspace, First, Second) ->
  gen_server:call(?VIA(Workspace), {co_task, First, Second}).

%% @spec:	get_products(Task::ergo:task()) -> ok.
%% @end
-spec(get_products(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_products(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {products, Task}).

%% @spec:	get_products(Task::ergo:task()) -> ok.
%% @end
-spec(get_dependencies(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_dependencies(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {dependencies, Task}).


%% @spec:	ordered_tasks(First::ergo:task(), Second::ergo:task()) -> ok.
%% @end
-spec(ordered_tasks(ergo:workspace_name(), ergo:task(), ergo:task()) -> ok).
ordered_tasks(Workspace, First, Second) ->
  gen_server:call(?VIA(Workspace), {task_seq, First, Second}).


%% @spec:	build_list(Targets::[ergo:target()]) -> ok.
%% @end
-spec(build_list(ergo:workspace_name(), [ergo:target()]) -> ok).
build_list(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {build_list, Targets}).

%% @spec:	task_batch(Task::ergo:taskname(),Graph::ergo:graph_item()) -> ok.
%% @doc:	Receives a batch of build-graph edges from a particular task.
%% @end

-spec(task_batch(ergo:workspace_name(), ergo:taskname(),Graph::ergo:graph_item()) -> ok).
task_batch(Workspace, Task,Graph) ->
  gen_server:call(?VIA(Workspace), {task_batch, Task, Graph}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
-record(state, { workspace :: ergo:workspace_name(),
                 workspace_root_re :: tuple(),
                 edges :: ets:tid(),
                 vertices :: ets:tid(),
                 provenence :: ets:tid()}).

init([Workspace]) ->
  {ok, build_state(Workspace) }.

handle_call({new_dep, FromProduct, ToProduct}, _From, State) ->
  {reply, new_dep(State, FromProduct, ToProduct), State};
handle_call({new_req, Task, Product}, _From, State) ->
  {reply, new_req(State, Task, Product), State};
handle_call({new_prod, Task, Product}, _From, State) ->
  {reply, new_prod(State, Task, Product), State};
handle_call({co_task, WhenTask, AlsoTask}, _From, State) ->
  {reply, co_task(State, WhenTask, AlsoTask), State};
handle_call({products, Task}, _From, State) ->
  {reply, products(State, Task), State};
handle_call({dependencies, Task}, _From, State) ->
  {reply, dependencies(State, Task), State};
handle_call({task_seq, First, Second}, _From, State) ->
  {reply, task_seq(State, First, Second), State};
handle_call({build_list, Targets}, _From, State) ->
  {NewState, Result} = handle_build_list(State,Targets),
  {reply, Result, NewState};
handle_call({task_batch, Task, Graph}, _From, State) ->
  {reply, process_task_batch(Task, Graph, State), State};

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


build_state(WorkspaceRoot) ->
  build_state(WorkspaceRoot, protected).

build_state(WorkspaceRoot, Access) ->
  {ok,Regex} = re:compile(["^", filename:flatten(filename:absname(WorkspaceRoot))]),
  load_from(#state{ workspace = WorkspaceRoot, workspace_root_re = Regex }).

cleanup_state(#state{edges=Etab,vertices=Vtab,provenence=Ptab}) ->
  maybe_delete_table(Etab),
  maybe_delete_table(Vtab),
  maybe_delete_table(Ptab),
  ok.

depgraph_path_for(Workspace) ->
  [Workspace, "/.ergo/depgraph"].

dump_to(State=#state{workspace=Workspace}) ->
  dump_to(State, depgraph_path_for(Workspace)).

-spec dump_to(#state{}, file:name()) -> #state{}.
dump_to(State=#state{vertices=VTab, edges=ETab, provenence=PTab}, FilenameBase) ->
  filelib:ensure_dir(FilenameBase),
  ct:pal("D2 ~p ~p ~p", [ETab, VTab, PTab]),
  ok = ets:tab2file(VTab, [FilenameBase, ".vtab"]),
  ok = ets:tab2file(ETab, [FilenameBase, ".etab"]),
  ok = ets:tab2file(PTab, [FilenameBase, ".ptab"]),
  State.

load_from(State=#state{workspace=Workspace}) ->
  load_from(State, depgraph_path_for(Workspace)).

load_from(State, FilenameBase) ->
  load_from(State, FilenameBase, protected).

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
  ct:pal("LrB: ~p", [Filename]),
  case ets:file2tab(Filename) of
    {ok, Tab} ->
      ct:pal("Loaded: ~p", [Tab]),
      Tab;
    {error, _Error} ->
      Tab = build_table(TableName, Type, Access),
      ct:pal("Built: ~p", [Tab]),
      Tab
  end.

build_table(vertices, Type, Access) ->
  VTab = ets:new(vertices, [Type, Access, {keypos, 2}]),
  ets:insert(VTab, #next_id{kind=edge_ids, value=0}),
  VTab;
build_table(Name, Type, Access) ->
  ets:new(Name, [Type, Access, {keypos, 2}]).

maybe_delete_table(undefined) ->
  ct:pal("no-delete"),
  ok;
maybe_delete_table(Table) ->
  ct:pal("delete: ~p", [Table]),
  case ets:info(Table) of
    undefined -> ok;
    _ -> ets:delete(Table)
  end.

-spec(process_task_batch(ergo:taskname(), [ergo:graph_item()], #state{}) -> ok).
process_task_batch(Taskname, ReceivedItems, State) ->
  maybe_notify_changed( record_task_batch(Taskname, ReceivedItems, State), State).

maybe_notify_changed(true, State=#state{workspace=Workspace}) ->
  dump_to(State),
  ergo_events:graph_changed(Workspace);
maybe_notify_changed(false, _State) ->
  ok.

-spec(record_task_batch(ergo:taskname(), [ergo:graph_item()], #state{}) -> true | false).
record_task_batch(Taskname, ReceivedItems, State) ->
  CurrentItems = normalize_items(State, ReceivedItems),
  KnownItems = items_for_task(State, Taskname),
  NewItems = CurrentItems -- KnownItems,
  MissingItems = KnownItems -- CurrentItems,
  AddAcc = fun(Item, Acc) -> (add_statement(State, Taskname, Item)) or Acc end,
  Added = lists:foldl(AddAcc, false, NewItems),
  Removed = lists:foldl(fun(Item, Acc) ->
                            del_statement(State, Taskname, Item) or Acc
                        end, false, MissingItems),
  Added or Removed.


-spec add_statement(#state{}, ergo:taskname(), ergo:graph_item()) -> true | false.
add_statement(State=#state{provenence=Provs}, Taskname, Item) ->
  {Newness, Edge} = add_statement(State, edge_for_statement(Item)),
  EdgeId = element(#seq.edge_id, Edge),
  ets:insert(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case Newness of
    ok -> true;
    exists -> false
  end.

del_statement(State=#state{provenence=Provs,edges=Edges}, Taskname, Item) ->
  {_, Edge} = add_statement(State, edge_for_statement(Item)),
  EdgeId = element(#seq.edge_id, Edge),
  ets:delete_object(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case ets:lookup(Provs, EdgeId) of
    [] -> ets:delete_object(Edges, Edge), true;
    _ -> false
  end.

-spec(normalize_product_name(#state{}, productname()) -> normalized_product()).
normalize_product_name(#state{workspace_root_re=Regex}, Name) ->
  re:replace(filename:flatten(filename:absname(Name)), Regex, "").

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

-spec(edge_for_statement(ergo:graph_item()) -> edge_record()).
edge_for_statement({seq, Before, Then}) ->
  #seq{before=Before,then=Then};
edge_for_statement({co, Task, Also}) ->
  #cotask{task=Task,also=Also};
edge_for_statement({prod, Task,Produces}) ->
  #production{task=Task,produces=Produces};
edge_for_statement({req, Task,Produces}) ->
  #requirement{task=Task,requires=Produces};
edge_for_statement({dep, From, To}) ->
  #dep{from=From,to=To};
edge_for_statement(Statement) ->
  {err, {unrecognized_statement, Statement}}.


-spec(statement_for_edge(edge_record()) -> ergo:graph_item()).
statement_for_edge(#seq{before=First,then=Second}) ->
  {seq, First, Second};
statement_for_edge(#cotask{task=WhenTask,also=AlsoTask}) ->
  {co, WhenTask, AlsoTask};
statement_for_edge(#production{task=Task,produces=Product}) ->
  {prod, Task, Product};
statement_for_edge(#dep{from=From,to=To}) ->
  {dep, From, To};
statement_for_edge(Edge) ->
  {err, {unrecognized_edge, Edge}}.

normalize_batch_statement(State, {dep, FromProd, ToProd}) ->
  {dep,
   normalize_product_name(State, FromProd),
   normalize_product_name(State, ToProd)};
normalize_batch_statement(State, {prod, Task, Prod}) ->
  {prod,
   Task,
   normalize_product_name(State, Prod)};
normalize_batch_statement(_State, Stmt={co, _, _}) ->
  Stmt;
normalize_batch_statement(_State, Stmt={seq, _, _}) ->
  Stmt;
normalize_batch_statement(_State, Statement) ->
  {err, {unrecognized_statement, Statement}}.


% Insert a dependency
-spec new_dep(#state{}, #product{}, #product{}) ->
  {ok, edge_record()} | {exists,edge_record()}.
new_dep(State, {product, ProductName}, {product, DependsOn}) ->
  add_product(State, ProductName), add_product(State, DependsOn),
  add_statement(State, #dep{from=ProductName,to=DependsOn}).

-spec new_req(#state{}, ergo:task(), #product{}) ->
  {ok, edge_record()} | {exists,edge_record()}.
new_req(State, {task, TaskName}, {product, ProductName}) ->
  add_task(State, TaskName), add_product(State, ProductName),
  add_statement(State, #requirement{task=TaskName,requires=ProductName}).

-spec new_prod(#state{}, ergo:task(), #product{}) ->
  {ok, edge_record()} | {exists,edge_record()}.
new_prod(State, {task, TaskName}, {product, ProductName}) ->
  add_task(State, TaskName), add_product(State, ProductName),
  add_statement(State, #production{task=TaskName,produces=ProductName}).

% Insert a co-task edge
-spec co_task(#state{}, ergo:task(), ergo:task()) ->
  {ok, edge_record()} | {exists,edge_record()}.
co_task(State, {task, Task}, {task, WithOther}) ->
  add_task(State, Task), add_task(State, WithOther),
  add_statement(State, #cotask{task=Task,also=WithOther}).

% Insert a task sequencing edge
-spec task_seq(#state{}, ergo:task(), ergo:task()) ->
  {ok, edge_record()} | {exists,edge_record()}.
task_seq(State, {task, First}, {task, Second}) ->
  add_task(State, First), add_task(State, Second),
  add_statement(State, #seq{before=First, then=Second}).

-spec add_statement(#state{}, edge_record()) ->
  {ok, edge_record()} | {exists,edge_record()}.
add_statement(State, Edge = #seq{before=Before,then=Then}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, seq), E#seq.before =:= Before, E#seq.then =:= Then]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #cotask{task=Task,also=Also}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, cotask), E#cotask.task =:= Task, E#cotask.also =:= Also]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #requirement{task=Task,requires=Product}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, requirement), E#requirement.task =:= Task, E#requirement.requires =:= Product]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #production{task=Task,produces=Product}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, production), E#production.task =:= Task, E#production.produces =:= Product]),
  insert_edge(State, Edge, Query);

add_statement(State, Edge = #dep{from=From,to=To}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, dep), E#dep.from =:= From, E#dep.to =:= To]),
  insert_edge(State, Edge, Query).


insert_edge(State=#state{edges=EdgeTable}, Edge, Query) ->
  case qlc:eval(Query) of
    [] ->
      EdgeWithId = setelement(2, Edge, next_edge_id(State)),
      true = ets:insert(EdgeTable, EdgeWithId),
      {ok, EdgeWithId};
    FoundList -> {exists, hd(FoundList)}
  end.

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
  qlc:eval(qlc:q([ E#production.produces || E <- ets:table(State#state.edges),
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
  ct:pal("~p:~p ~p", [?FILE, ?LINE, TaskName]),
  qlc:eval(task_deps_query(State, TaskName)).

-spec(prod_dep_query(#state{}, productname()) -> qlc:query_handle()).
prod_dep_query(#state{edges=Edges}, ProductName) ->
  qlc:q([ Dep#dep.to || Dep <- ets:table(Edges), Dep#dep.from =:= ProductName ]).

-spec(task_deps_query(#state{}, taskname()) -> qlc:query_handle()).
task_deps_query(#state{edges=Edges}, TaskName) ->
  ct:pal("~p ~p", [?FILE, ets:info(Edges)]),
  qlc:q([Depcy#dep.to || Pdctn <- ets:table(Edges), Depcy <- ets:table(Edges),
                TaskName =:= Pdctn#production.task, Pdctn#production.produces =:= Depcy#dep.from ]).


% Not currently used, but seems useful from a symmetry standpoint
%-spec(task_products_query(#state{}, taskname()) -> qlc:query_handle()).
%task_products_query(#state{vertices=Vertices, edges=Edges}, TaskName) ->
%  qlc:q([Product || Product <- ets:table(Vertices), Production <- ets:table(Edges),
%                    Product#product.name =:= Production#production.produces,
%                    Production#production.task =:= TaskName ]).

-spec(handle_build_list(#state{}, [ergo:target()]) -> ergo:build_spec()).
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

most_edges([Task | Rest], Tasks) ->
  most_edges(Rest, Tasks, Task, length(dict:fetch(Tasks, Task))).

most_edges([Task | Rest], Dict, Chosen, Count) ->
  NewCount = length(dict:fetch(Dict, Task)),
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
also_graph(State) ->
  intermediate_graph(State, digraph:new(), all_cotask_edges(State)).

-spec(seq_graph(#state{}) -> digraph:graph()).
seq_graph(State) ->
  intermediate_graph(State, digraph:new([acyclic]), all_seq_edges(State)).


-spec(intermediate_graph(#state{}, digraph:graph(), [edge_record()]) -> digraph:graph()).
intermediate_graph(State, Graph, EdgeList) ->
  TaskLookup = task_cache(Graph, all_tasks(State)),
  lists:foreach(
    fun(Edge) ->
        BeforeV = gb_trees:get(Edge#gen_edge.from, TaskLookup),
        ThenV = gb_trees:get(Edge#gen_edge.to, TaskLookup),
        digraph:add_edge(Graph, BeforeV, ThenV,
                         #edge_label{from_edges=Edge#gen_edge.implied_by})
    end, EdgeList), Graph.

task_cache(Graph, Tasks) ->
  lists:foldl( fun(Task, TaskLookup) ->
        gb_trees:insert(Task#task.name,
                        digraph:add_vertex(Graph, digraph:add_vertex(Graph), Task#task.name),
                        TaskLookup)
    end, gb_trees:empty(), Tasks).

-spec(all_tasks(#state{}) -> [#task{}]).
all_tasks(#state{vertices=Vertices}) ->
  qlc:eval(qlc:q([Task || Task <- ets:table(Vertices), is_record(Task, task)])).

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
  qlc:q([#gen_edge{from=Pdctn#production.task, to=Req#requirement.task,
                  implied_by=[Pdctn#production.edge_id,Req#requirement.edge_id]} ||
         Pdctn <- ets:table(Edges), Req <- ets:table(Edges),
         Pdctn#production.produces =:= Req#requirement.requires
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
  qlc:q([#gen_edge{from=PriorPdctn#production.task, to=PostPdctn#production.task,
                  implied_by=[PriorPdctn#production.edge_id,Depcy#dep.edge_id,PostPdctn#production.edge_id]} ||
         PriorPdctn <- ets:table(Edges), Depcy <- ets:table(Edges), PostPdctn <- ets:table(Edges),
         PostPdctn#production.produces =:= Depcy#dep.from, PriorPdctn#production.produces =:= Depcy#dep.to
        ]).


-spec(tasks_from_targets(#state{}, [ergo:target()]) -> [ergo:task()]).
tasks_from_targets(State, Targets) ->
  lists:map(
    fun(Target) ->
        case Target of
          {product, ProductName} ->
            case task_for_product(State, ProductName) of
              {err, Error} -> {error, Error};
              #task{name=Name} -> {task, Name}
            end;
          {task, _} -> Target
        end
    end,
    Targets ).

% Task for product
-spec(task_for_product(#state{}, productname()) -> #task{}).
task_for_product(#state{edges=Edges,vertices=Vertices}, ProductName) ->
  TaskQ = qlc:q([ V || E <- ets:table(Edges), V <- ets:table(Vertices),
                       E#production.produces =:= ProductName, E#production.task =:= V#task.name ]),
  FoundTasks = qlc:eval(TaskQ),
  case length(FoundTasks) of
    1 -> hd(FoundTasks);
    0 -> {err, {no_task_produces, ProductName}};
    _ -> {err, {violated_invariant, single_producer}}
  end.


% find_product_vertex(State, ProductName) ->
%   single_vertex(qlc:q([V || V <- ets:table(State#state.vertices),
%                             is_record(V, product), V#product.name =:= ProductName])).
% single_vertex(Query) ->
%   case length(FoundVertices = qlc:eval(Query)) of
%     1 -> {ok, hd(FoundVertices)};
%     0 -> false;
%     _ -> {error, {violated_invariant, single_vertex_per_entity}}
%   end.


%%% Tests

digraph_test_() ->
  ProductName = "x.out",
  DependsOn = "x.in",
  TaskName = [<<"compile">>,  <<"x">>],
  OtherTaskName = [<<"test">>, <<"x">>],

  {foreach, %local, %digraphs are trapped in their process
    fun() -> build_state("graph-test", public) end, %setup
    fun(State) -> cleanup_state(State) end, %teardown
    [
     fun(State) ->
         ?_test(begin
                  ?assertMatch([{[<<"new-task">>, <<"with-arg">>], []}],
                               handle_build_list(State, [{task, [<<"new-task">>, <<"with-arg">>]}]))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch({ok,{dep,1,"x.out","x.in"}},
                               new_dep(State, {product, ProductName}, {product, DependsOn})),
                  ?assertMatch({exists,{dep,1,"x.out","x.in"}},
                               new_dep(State, {product, ProductName}, {product, DependsOn})),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch({ok,{production,1,[<<"compile">>,<<"x">>],"x.out"}},
                               new_prod(State, {task, TaskName}, {product, ProductName})),
                  ?assertMatch({exists,{production,1,[<<"compile">>,<<"x">>],"x.out"}},
                               new_prod(State, {task, TaskName}, {product, ProductName})),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch({ok, {cotask,1,[<<"compile">>,<<"x">>],[<<"test">>,<<"x">>]}},
                               co_task(State, {task, TaskName}, {task, OtherTaskName})),
                  ?assertMatch({exists, {cotask,1,[<<"compile">>,<<"x">>],[<<"test">>,<<"x">>]}},
                               co_task(State, {task, TaskName}, {task, OtherTaskName})),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test(begin
                  ?assertMatch({ok,{seq,1, [<<"compile">>,<<"x">>], [<<"test">>,<<"x">>]}},
                               task_seq(State, {task, TaskName}, {task, OtherTaskName})),
                  ?assertMatch({exists,{seq,1, [<<"compile">>,<<"x">>], [<<"test">>,<<"x">>]}},
                               task_seq(State, {task, TaskName}, {task, OtherTaskName})),
                  ?assertEqual(1, length(ets:tab2list(State#state.edges)))
                end)
     end,
     fun(State) ->
         ?_test( begin
                   new_dep(State, {product, ProductName}, {product, DependsOn}),
                   ?assertMatch({ok,{production,2,[<<"compile">>,<<"x">>],"x.out"}},
                                new_prod(State, {task, TaskName}, {product, ProductName})),
                   ?assertEqual(
                      [DependsOn],
                      task_deps(State, TaskName)
                     )
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   dump_to(State),
                   ?assertEqual(
                      {error, [{no_task_produces, ProductName}]},
                      handle_build_list(State, [{product, ProductName}])
                     )
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   new_req(State, {task, TaskName}, {product, DependsOn}),
                   ?assertMatch({ok,#production{}},new_prod(State, {task, OtherTaskName}, {product, DependsOn})),
                   dump_to(State),
                   ?assertEqual(
                      [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                      handle_build_list(State, [{task, TaskName}])
                     )
                 end)
     end,
     fun(State) ->
         ?_test( begin
                   new_dep(State, {product, ProductName}, {product, DependsOn}),
                   ?assertMatch({ok, #production{}}, new_prod(State, {task, OtherTaskName}, {product, DependsOn})),
                   ?assertMatch({ok, #production{}}, new_prod(State, {task, TaskName}, {product, ProductName})),
                   NewState = dump_to(State),
                   ?assertEqual(
                      [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                      handle_build_list(NewState, [{product, ProductName}])
                     )
                 end)
     end
    ]
  }.
