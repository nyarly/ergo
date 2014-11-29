-module(erdo_graphs).
-behavior(gen_server).
%% API
-export([start_link/0,
         requires/2,produces/2,joint_tasks/2,ordered_tasks/2,get_products/1,get_dependencies/1,build_list/1,task_batch/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(NOTEST, true).
-include_lib("eunit/include/eunit.hrl").

-include_lib("stdlib/include/qlc.hrl").

-define(SERVER, ?MODULE).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).


-type task_name() :: string().
-type product_name() :: file:name_all().
-type edge_id() :: integer().
-type normalized_product() :: string().

-record(task, {name :: task_name(), command :: [binary()]}).
-record(product, { name :: product_name() }).
-record(next_id, { kind :: atom(), value :: integer() }).

-record(seq, {
          edge_id :: edge_id(), before :: task_name(), then :: task_name() }).
-record(cotask, {
          edge_id :: edge_id(), task :: task_name(), also :: task_name() }).
-record(production, {
          edge_id :: edge_id(), task :: task_name(), produces :: normalized_product() }).
-record(dep, {
          edge_id :: edge_id(), from :: normalized_product(), to :: normalized_product() }).
-type edge_record() :: #seq{} | #cotask{} | #production{} | #dep{}.

-record(provenence, {
          edge_id :: edge_id(), task :: task_name() }).


%% @spec:	requires(First::erdo:produced(), Second::erdo:produced()) -> ok.
%% @end
-spec(requires(erdo:produced(), erdo:produced()) -> ok).
requires(First, Second) ->
  gen_server:call(?SERVER, {new_dep, First, Second}).

%% @spec:	produces(Task::erdo:task(), Product::erdo:produced()) -> ok.
%% @end
-spec(produces(erdo:task(), erdo:produced()) -> ok).
produces(Task, Product) ->
  gen_server:call(?SERVER, {new_prod, Task, Product}).

%% @spec:	joint_tasks(First::erdo:task(), Second::erdo:task()) -> ok.
%% @end
-spec(joint_tasks(erdo:task(), erdo:task()) -> ok).
joint_tasks(First, Second) ->
  gen_server:call(?SERVER, {co_task, First, Second}).

%% @spec:	get_products(Task::erdo:task()) -> ok.
%% @end
-spec(get_products(erdo:task()) -> ok).
get_products(Task) ->
  gen_server:call(?SERVER, {products, Task}).

%% @spec:	get_products(Task::erdo:task()) -> ok.
%% @end
-spec(get_dependencies(erdo:task()) -> ok).
get_dependencies(Task) ->
  gen_server:call(?SERVER, {dependencies, Task}).


%% @spec:	ordered_tasks(First::erdo:task(), Second::erdo:task()) -> ok.
%% @end
-spec(ordered_tasks(erdo:task(), erdo:task()) -> ok).
ordered_tasks(First, Second) ->
  gen_server:call(?SERVER, {task_seq, First, Second}).


%% @spec:	build_list(Targets::[erdo:target()]) -> ok.
%% @end
-spec(build_list([erdo:target()]) -> ok).
build_list(Targets) ->
  gen_server:call(?SERVER, {build_list, Targets}).

%% @spec:	task_batch(Task::erdo:taskname(),Graph::erdo:graph_item()) -> ok.
%% @doc:	Receives a batch of build-graph edges from a particular task.
%% @end

-spec(task_batch(erdo:taskname(),Graph::erdo:graph_item()) -> ok).
task_batch(Task,Graph) ->
  gen_server:call(?SERVER, {task_batch, Task, Graph}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
-record(state, {project_root_re :: re:mp(), edges :: ets:tid(), vertices :: ets:tid(), provenence :: ets:tid()}).

init([]) ->
  {ok, build_state() }.

handle_call({new_dep, FromProduct, ToProduct}, _From, State) ->
  {reply, new_dep(State, FromProduct, ToProduct), State};
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
  {reply, build_list(State,Targets), State};
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


build_state() ->
  build_state("/").

build_state(ProjectRoot) ->
  build_state(ProjectRoot, protected).

build_state(ProjectRoot, Access) ->
  Vertices = ets:new(vertices, [set, Access, {keypos, 2}]),
  Edges = ets:new(edges, [bag, Access, {keypos, 2}]),
  Provenence = ets:new(provenence, [bag, Access, {keypos, 2}]),
  ets:insert(Vertices, #next_id{kind=edge_ids, value=0}),
  {ok,Regex} = re:compile(["^", filename:flatten(filename:absname(ProjectRoot))]),
  #state{ project_root_re = Regex, edges=Edges, vertices=Vertices, provenence=Provenence }.

cleanup_state(State) ->
  ets:delete(State#state.edges),
  ets:delete(State#state.vertices),
  ets:delete(State#state.provenence),
  ok.

-spec(process_task_batch(erdo:task_name(), [erdo:graph_item()], digraph:graph()) -> ok).
process_task_batch(Taskname, ReceivedItems, State) ->
  CurrentItems = normalize_items(State, ReceivedItems),
  KnownItems = items_for_task(State, Taskname),
  NewItems = CurrentItems -- KnownItems,
  MissingItems = KnownItems -- CurrentItems,
  Added = lists:foldl(fun(Item, Acc) -> add_statement(State, Taskname, Item) =/= ok or Acc end, false, NewItems),
  Removed = lists:foldl(fun(Item, Acc) -> del_statement(State, Taskname, Item) =/= ok or Acc end, false, MissingItems),
  if Added or Removed -> erdo_events:graph_changed(Added, Removed) end,
  ok.

-spec(normalize_product_name(#state{}, product_name()) -> normalized_product()).
normalize_product_name(#state{project_root_re=Regex}, Name) ->
  re:replace(filename:flatten(filename:absname(Name)), Regex, "").

normalize_items(State, Items) ->
  [ normalize_batch_statement(State, Item) || Item <- Items ].

items_for_task(#state{edges=Edges,provenence=Provs}, Taskname) ->
  [ statement_for_edge(Edge) || Edge <- ets:table(Edges), Prov <- ets:table(Provs),
                                Prov#provenence.task =:= Taskname, Prov#provenence.edge_id =:= element(#seq.edge_id, Edge) ].

add_statement(State=#state{provenence=Provs}, Taskname, Item) ->
  {Newness, Edge} = add_statement(State, edge_for_statement(Item)),
  EdgeId = element(#seq.edge_id, Edge),
  ets:insert(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case Newness of
    ok -> added;
    exists -> ok
  end.

del_statement(State=#state{provenence=Provs,edges=Edges}, Taskname, Item) ->
  {_, Edge} = add_statement(State, edge_for_statement(Item)),
  EdgeId = element(#seq.edge_id, Edge),
  ets:delete_object(Provs, #provenence{edge_id=EdgeId,task=Taskname}),
  case ets:lookup(Provs, EdgeId) of
    [] -> ets:delete_object(Edges, Edge), deleted;
    _ -> ok
  end.

-spec(edge_for_statement(erdo:graph_item()) -> edge_record()).
edge_for_statement({seq, Before, Then}) ->
  #seq{before=Before,then=Then};
edge_for_statement({co, Task, Also}) ->
  #cotask{task=Task,also=Also};
edge_for_statement({prod, Task,Produces}) ->
  #production{task=Task,produces=Produces};
edge_for_statement({dep, From, To}) ->
  #dep{from=From,to=To};
edge_for_statement(Statement) ->
  {err, {unrecognized_statement, Statement}}.


-spec(statement_for_edge(edge_record()) -> erdo:graph_item()).
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


-spec(dump_to(#state{}, binary()) -> ok).
dump_to(#state{vertices=VTab, edges=ETab, provenence=PTab}, FilenameBase) ->
  ets:tab2file(VTab, [FilenameBase, ".vtab"]),
  ets:tab2file(ETab, [FilenameBase, ".etab"]),
  ets:tab2file(PTab, [FilenameBase, ".ptab"]),
  ok.

-spec(load_from(#state{}, binary()) -> digraph:graph()).
load_from(State, FilenameBase) ->
  {ok, VTab} = ets:file2tab([FilenameBase, ".vtab"]),
  {ok, ETab} = ets:file2tab([FilenameBase, ".etab"]),
  {ok, PTab} = ets:file2tab([FilenameBase, ".ptab"]),
  maybe_delete_table(State#state.edges),
  maybe_delete_table(State#state.vertices),
  maybe_delete_table(State#state.provenence),
  State#state{edges = ETab, vertices = VTab, provenence = PTab}.

maybe_delete_table(undefined) ->
  ok;
maybe_delete_table(Table) ->
  ets:delete(Table).

% Insert a dependency
-spec(new_dep(digraph:graph(), erdo:produced(), erdo:produced()) -> digraph:edge()).
new_dep(State, {product, ProductName}, {product, DependsOn}) ->
  add_product(State, ProductName), add_product(State, DependsOn),
  add_statement(State, #dep{from=ProductName,to=DependsOn}).

-spec(new_prod(digraph:graph(), erdo:task(), erdo:produced()) -> digraph:edge()).
new_prod(State, {task, TaskName}, {product, ProductName}) ->
  add_task(State, TaskName), add_product(State, ProductName),
  add_statement(State, #production{task=TaskName,produces=ProductName}).

% Insert a co-task edge
-spec(co_task(digraph:graph(), erdo:task(), erdo:task()) -> digraph:edge()).
co_task(State, {task, Task}, {task, WithOther}) ->
  add_task(State, Task), add_task(State, WithOther),
  add_statement(State, #cotask{task=Task,also=WithOther}).

% Insert a task sequencing edge
-spec(task_seq(digraph:graph(), erdo:task(), erdo:task()) -> digraph:edge()).
task_seq(State, {task, First}, {task, Second}) ->
  add_task(State, First), add_task(State, Second),
  add_statement(State, #seq{before=First, then=Second}).

-spec(add_statement(#state{}, edge_record()) -> ok | false).
add_statement(State, Edge = #seq{before=Before,then=Then}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, seq), E#seq.before =:= Before, E#seq.then =:= Then]),
  add_edge_if_missing(State, Edge, Query);

add_statement(State, Edge = #cotask{task=Task,also=Also}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, cotask), E#cotask.task =:= Task, E#cotask.also =:= Also]),
  add_edge_if_missing(State, Edge, Query);

add_statement(State, Edge = #production{task=Task,produces=Product}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, production), E#production.task =:= Task, E#production.produces =:= Product]),
  add_edge_if_missing(State, Edge, Query);

add_statement(State, Edge = #dep{from=From,to=To}) ->
  Query = qlc:q([E|| E <- ets:table(State#state.edges),
                         is_record(E, dep), E#dep.from =:= From, E#dep.to =:= To]),
  add_edge_if_missing(State, Edge, Query).


add_edge_if_missing(State=#state{edges=EdgeTable}, Edge, Query) ->
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
-spec(products(digraph:graph(), erdo:task()) -> [erdo:produced()]).
products(State, {task, TaskName}) ->
  qlc:eval(qlc:q([ E#production.produces || E <- ets:table(State#state.edges),
                                            E#production.task =:= TaskName ])).

% Task for product
-spec(task_for_product(#state{}, product_name()) -> #task{}).
task_for_product(#state{edges=Edges,vertices=Vertices}, ProductName) ->
  TaskQ = qlc:q([ V || E <- ets:table(Edges), V <- ets:table(Vertices),
                       E#production.produces =:= ProductName, E#production.task =:= V#task.name ]),
  FoundTasks = qlc:eval(TaskQ),
  case length(FoundTasks) of
    0 -> false;
    1 -> hd(FoundTasks);
    _ -> {err, {violated_invariant, single_producer}}
  end.

-spec(dependencies(digraph:graph(), erdo:produced() | erdo:task()) -> [erdo:produced()]).
dependencies(State, {product, ProductName}) ->
  prod_deps(State, ProductName);
dependencies(State, {task, TaskName}) ->
  task_deps(State, TaskName).

-spec(prod_deps(#state{}, erdo:productname()) -> [erdo:produced()]).
prod_deps(State, ProductName) ->
  [ {product, PName} || PName <- product_dependencies(State, ProductName) ].

-spec(task_deps(digraph:graph(), binary()) -> [erdo:produced()]).
task_deps(State, TaskName) ->
  [ {product, PName} || PName <- task_dependencies(State, TaskName) ].

-spec(product_dependencies(#state{}, product_name()) -> [#product{}]).
product_dependencies(State, ProductName) ->
  qlc:eval(prod_dep_query(State, ProductName)).

-spec(task_dependencies(#state{}, task_name()) -> [#product{}]).
task_dependencies(State, TaskName) ->
  qlc:eval(task_deps_query(State, TaskName)).

-spec(prod_dep_query(#state{}, product_name()) -> qlc:query_handle()).
prod_dep_query(#state{edges=Edges}, ProductName) ->
  qlc:q([ Dep#dep.to || Dep <- ets:table(Edges), Dep#dep.from =:= ProductName ]).

-spec(task_deps_query(#state{}, task_name()) -> qlc:query_handle()).
task_deps_query(#state{edges=Edges}, TaskName) ->
  qlc:q([Depcy#dep.to || Pdctn <- ets:table(Edges), Depcy <- ets:table(Edges),
                TaskName =:= Pdctn#production.task, Pdctn#production.produces =:= Depcy#dep.from ]).


-spec(task_products_query(#state{}, task_name()) -> qlc:query_handle()).
task_products_query(#state{vertices=Vertices, edges=Edges}, TaskName) ->
  qlc:q([Product || Product <- ets:table(Vertices), Production <- ets:table(Edges),
                    Product#product.name =:= Production#production.produces,
                    Production#production.task =:= TaskName ]).

-spec(build_list(digraph:graph(), [erdo:target()]) -> [erdo:build_spec()]).
build_list(State, Targets) ->
  SeqGraph = seq_graph(State),
  AlsoGraph = also_graph(State),
  TargetVertices = tasknames_to_vertices(AlsoGraph, [Taskname || {task, Taskname} <- tasks_from_targets(State, Targets)]),
  NeededTasknames = vertices_to_tasknames(AlsoGraph, digraph_utils:reachable(TargetVertices, AlsoGraph)),
  SeqVs = digraph_utils:topsort(digraph_utils:subgraph(SeqGraph, tasknames_to_vertices(SeqGraph, NeededTasknames))),
  Specs = [{taskname_from_vertex(SeqGraph, TV),
            [taskname_from_vertex(SeqGraph, PredTask) || PredTask <- digraph_utils:reaching_neighbours([TV], SeqGraph)]
           } || TV <- SeqVs ],
  digraph:delete(AlsoGraph), digraph:delete(SeqGraph),
  Specs.

taskname_from_vertex(Graph, Vertex) ->
  {_V, Taskname} = digraph:vertex(Graph, Vertex),
  Taskname.

-spec(vertices_to_tasknames(digraph:graph(), [digraph:vertex()]) -> [task_name()]).
vertices_to_tasknames(Graph, Vertices) ->
  [ Label || {_Vert, Label} <- [digraph:vertex(Graph, Vertex) || Vertex <- Vertices ]].

-spec(tasknames_to_vertices(digraph:graph(), [task_name()]) -> [digraph:vertex()]).
tasknames_to_vertices(Graph, Tasknames) ->
  [ Vert || {Vert, Label} <- [digraph:vertex(Graph, Vertex) || Vertex <- digraph:vertices(Graph)],
            Taskname <- Tasknames, Label =:= Taskname ].


-spec(also_graph(#state{}) -> digraph:graph()).
also_graph(State) ->
  AlsoGraph = digraph:new(),
  TaskLookup = task_cache(AlsoGraph, all_tasks(State)),
  lists:foreach(
    fun(AlsoEdge) ->
        TaskV = gb_trees:get(AlsoEdge#cotask.task, TaskLookup),
        AlsoV = gb_trees:get(AlsoEdge#cotask.also, TaskLookup),
        digraph:add_edge(AlsoGraph, TaskV, AlsoV)
    end, all_cotask_edges(State)),
  AlsoGraph.

-spec(seq_graph(#state{}) -> digraph:graph()).
seq_graph(State) ->
  SeqGraph = digraph:new([acyclic]),
  TaskLookup = task_cache(SeqGraph, all_tasks(State)),
  lists:foreach(
    fun(SeqEdge) ->
        BeforeV = gb_trees:get(SeqEdge#seq.before, TaskLookup),
        ThenV = gb_trees:get(SeqEdge#seq.then, TaskLookup),
        digraph:add_edge(SeqGraph, BeforeV, ThenV)
    end, all_seq_edges(State)),
  SeqGraph.

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
  qlc:eval(qlc:append(implied_seq_query(State), explicit_seq_query(State))).

implied_seq_query(State) ->
  qlc:q([#seq{before=BeforeTask,then=ThenTask} ||
         {BeforeTask, ThenTask} <- task_to_task_dep_query(State)]).

explicit_seq_query(#state{edges=Edges}) ->
  qlc:q([Seq || Seq <- ets:table(Edges), is_record(Seq, seq)]).

-spec(all_cotask_edges(#state{}) -> [#cotask{}]).
all_cotask_edges(State) ->
  qlc:eval(qlc:append(implied_cotask_query(State), explicit_cotask_query(State))).

implied_cotask_query(State) ->
  qlc:q([#cotask{task=Task,also=Also} ||
         {Also, Task} <- task_to_task_dep_query(State)]).

explicit_cotask_query(#state{edges=Edges}) ->
  qlc:q([Also || Also <- ets:table(Edges), is_record(Also, cotask)]).


%  (Prior) --- PriorPdctn --- > (Dep)
%                                 |
%                                 |
%                               Depcy
%                                 |
%                                 v
%  (Post) --- PostPdctn -----> (Prod)
-spec(task_to_task_dep_query(#state{}) -> [{task_name(), task_name()}]).
task_to_task_dep_query(#state{edges=Edges}) ->
  qlc:q([{PriorPdctn#production.task, PostPdctn#production.task} ||
         PriorPdctn <- ets:table(Edges), Depcy <- ets:table(Edges), PostPdctn <- ets:table(Edges),
         PostPdctn#production.produces =:= Depcy#dep.from, PriorPdctn#production.produces =:= Depcy#dep.to
        ]).


-spec(tasks_from_targets(digraph:graph(), [erdo:target()]) -> [erdo:task()]).
tasks_from_targets(State, Targets) ->
  lists:map(
    fun(Target) ->
        case Target of
          {product, ProductName} -> {task, (task_for_product(State, ProductName))#task.name};
          {task, _} -> Target
        end
    end,
    Targets ).


-type edge() :: term().
%
% Update old/new graph edges
-spec(task_update(#state{}, erdo:task(), [edge()], [edge()]) -> ok).
task_update(Graphs, Task, OldEdges, NewEdges) ->
  ok.

% Edges declared by task
-spec(declared_by(#state{}, erdo:task()) -> [edge()]).
declared_by(Graphs, Task) ->
  ok.


find_product_vertex(State, ProductName) ->
  single_vertex(qlc:q([V || V <- ets:table(State#state.vertices),
                            is_record(V, product), V#product.name =:= ProductName])).
single_vertex(Query) ->
  case length(FoundVertices = qlc:eval(Query)) of
    1 -> {ok, hd(FoundVertices)};
    0 -> false;
    _ -> {error, {violated_invariant, single_vertex_per_entity}}
  end.


%%% Tests

digraph_test_() ->
  ProductName = "x.out",
  DependsOn = "x.in",
  TaskName = [<<"compile">>,  <<"x">>],
  OtherTaskName = [<<"test">>, <<"x">>],
  DumpFilename = "test-dump.erdograph",

  {foreach, %local, %digraphs are trapped in their process
    fun() -> build_state("/", public) end, %setup
    fun(State) -> cleanup_state(State) end, %teardown
    [
      fun(State) ->
          ?_test(begin
                ?assertMatch({ok, _Edge}, new_dep(State, {product, ProductName}, {product, DependsOn})),
                ?assertMatch({exists, _Edge}, new_dep(State, {product, ProductName}, {product, DependsOn})),
                ?assertEqual(1, length(ets:tab2list(State#state.edges)))
            end)
      end,
      fun(State) ->
          ?_test(begin
                ?assertMatch({ok, _Edge}, new_prod(State, {task, TaskName}, {product, ProductName})),
                ?assertMatch({exists, _Edge}, new_prod(State, {task, TaskName}, {product, ProductName})),
                ?assertEqual(1, length(ets:tab2list(State#state.edges)))
            end)
      end,
      fun(State) ->
          ?_test(begin
                ?assertMatch({ok, _Edge}, co_task(State, {task, TaskName}, {task, OtherTaskName})),
                ?assertMatch({exists, _Edge}, co_task(State, {task, TaskName}, {task, OtherTaskName})),
                ?assertEqual(1, length(ets:tab2list(State#state.edges)))
            end)
      end,
      fun(State) ->
          ?_test(begin
                ?assertMatch({ok, _Edge}, task_seq(State, {task, TaskName}, {task, OtherTaskName})),
                ?assertMatch({exists, _Edge}, task_seq(State, {task, TaskName}, {task, OtherTaskName})),
                ?assertEqual(1, length(ets:tab2list(State#state.edges)))
            end)
      end,
      fun(State) ->
          ?_test( begin
                new_dep(State, {product, ProductName}, {product, DependsOn}),
                ?assertMatch({ok, _Edge},new_prod(State, {task, TaskName}, {product, ProductName})),
                ?assertEqual(
                  [{product, DependsOn}],
                  task_deps(State, TaskName)
                )
            end)
      end,
      fun(State) ->
          ?_test( begin
                new_dep(State, {product, ProductName}, {product, DependsOn}),
                ?assertMatch({ok, _Edge},new_prod(State, {task, OtherTaskName}, {product, DependsOn})),
                ?assertMatch({ok, _Edge},new_prod(State, {task, TaskName}, {product, ProductName})),
                ?assertEqual(
                  [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                  build_list(State, [{product, ProductName}])
                )
            end)
      end,
      fun(State) ->
          ?_test( begin
                new_dep(State, {product, ProductName}, {product, DependsOn}),
                ?assertMatch({ok, _Edge},new_prod(State, {task, OtherTaskName}, {product, DependsOn})),
                ?assertMatch({ok, _Edge},new_prod(State, {task, TaskName}, {product, ProductName})),
                ?assertMatch(ok, dump_to(State, DumpFilename)),
                NewState = load_from(#state{}, DumpFilename),
                ?assertEqual(
                  [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                  build_list(NewState, [{product, ProductName}])
                )
            end)
      end
    ]
  }.
