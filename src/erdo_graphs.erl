-module(erdo_graphs).
-behavior(gen_server).
%% API
-export([start_link/0,requires/2,produces/2,joint_tasks/2,ordered_tasks/2,get_products/1,build_list/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(NOTEST, true).
-include_lib("eunit/include/eunit.hrl").

-define(SERVER, ?MODULE).
-record(state, {graph :: digraph:graph()}).
start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

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


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  {ok, #state{ graph=digraph:new() } }.

handle_call({new_dep, FromProduct, ToProduct}, _From, State) ->
  {reply, new_dep(State#state.graph, FromProduct, ToProduct), State};
handle_call({new_prod, Task, Product}, _From, State) ->
  {reply, new_prod(State#state.graph, Task, Product), State};
handle_call({co_task, WhenTask, AlsoTask}, _From, State) ->
  {reply, co_task(State#state.graph, WhenTask, AlsoTask), State};
handle_call({products, Task}, _From, State) ->
  {reply, products(State#state.graph, Task), State};
handle_call({task_seq, First, Second}, _From, State) ->
  {reply, task_seq(State#state.graph, First, Second), State};
handle_call({build_list, Targets}, _From, State) ->
  {reply, build_list(State#state.graph,Targets), State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
handle_info(_Info, State) ->
  {noreply, State}.
terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%

-record(vertex_label, {name :: string(), entity :: graph_entity()}).
-record(product, {name :: string()}).
-record(task, {name :: string(), command :: [binary()]}).
-record(dep_edge_label, {}). % emanates from a product that depends on the product the edge is incident on
-record(production_edge_label, {}).
-record(cotask_edge_label, {}).
-record(seq_edge_label, {}). % emanates from a task which much precede the task the edge is incident on

-type graph_entity() :: #product{} | #task{}.

-spec(dump_to(digraph:graph(), binary()) -> ok).
dump_to({digraph, VTab, ETab, NTab, Cyclic}, FilenameBase) ->
  ets:tab2file(VTab, [FilenameBase, ".vtab"]),
  ets:tab2file(ETab, [FilenameBase, ".etab"]),
  ets:tab2file(NTab, [FilenameBase, ".ntab"]),
  ok.

-spec(load_from(binary()) -> digraph:graph()).
load_from(FilenameBase) ->
  {ok, VTab} = ets:file2tab([FilenameBase, ".vtab"]),
  {ok, ETab} = ets:file2tab([FilenameBase, ".etab"]),
  {ok, NTab} = ets:file2tab([FilenameBase, ".ntab"]),
  {digraph, VTab, ETab, NTab, true}.

% Insert a dependency
-spec(new_dep(digraph:graph(), erdo:produced(), erdo:produced()) -> digraph:edge()).
new_dep(Graph, {product, ProductName}, {product, DependsOn}) ->
  {SVertex, _Product} = get_product_vertex(Graph, ProductName),
  {DVertex, _Depend} = get_product_vertex(Graph, DependsOn),
  add_statement(Graph, SVertex, DVertex,
    fun({_From, _To, Label}) -> is_record(Label, dep_edge_label); (_) -> false end,
      #dep_edge_label{}).

-spec(new_prod(digraph:graph(), erdo:task(), erdo:produced()) -> digraph:edge()).
new_prod(Graph, {task, TaskName}, {product, ProductName}) ->
  {Vertex, _Product} = get_task_vertex(Graph, TaskName),
  {DVertex, _Depend} = get_product_vertex(Graph, ProductName),
  add_statement(Graph, Vertex, DVertex,
    fun({_From, _To, Label}) -> is_record(Label, production_edge_label); (_) -> false end,
      #production_edge_label{}).

% Insert a co-task edge
-spec(co_task(digraph:graph(), erdo:task(), erdo:task()) -> digraph:edge()).
co_task(Graph, Task, WithOther) ->
  {FromV, _} = get_task_vertex(Graph, Task),
  {ToV, _} = get_task_vertex(Graph, WithOther),
  add_statement(Graph, FromV, ToV,
    fun({_From, _To, Label}) -> is_record(Label, cotask_edge_label); (_) -> false end,
      #cotask_edge_label{}).

% Insert a task sequencing edge
-spec(task_seq(digraph:graph(), erdo:task(), erdo:task()) -> digraph:edge()).
task_seq(Graph, First, Second) ->
  {FromV, _} = get_task_vertex(Graph, First),
  {ToV, _} = get_task_vertex(Graph, Second),
  add_statement(Graph, FromV, ToV,
    fun({_From, _To, Label}) -> is_record(Label, seq_edge_label); (_) -> false end,
      #seq_edge_label{}).

add_statement(Graph, SVertex, DVertex, EdgePred, NewLabel) ->
  case lists:any(EdgePred, [ {From, To, Label} ||
        {_Edge, From, To, Label} <- [digraph:edge(Graph, Edge) || Edge <- digraph:out_edges(Graph, SVertex)],
        From =:= SVertex,
        To =:= DVertex
      ]) of
    false ->
      digraph:add_edge(Graph, SVertex, DVertex, NewLabel), ok;
    _ ->
      exists
  end.

% Products for a task
-spec(products(digraph:graph(), erdo:task()) -> [erdo:produced()]).
products(Graph, TaskName) ->
  case find_task_vertex(Graph, {task, TaskName}) of
    false -> [];
    {ok, {Vertex, _Label}} ->
      lists:filtermap(
        fun(Edge) ->
            case digraph:edge(Graph, Edge) of
              {_Edge, _TVertex, ProductVertex, #production_edge_label{}} ->
                {_Vertex, #vertex_label{entity=#product{name=Product}}} = digraph:vertex(Graph, ProductVertex) ,
                { true, {product, Product} };
              _ -> false
            end
        end,
        digraph:out_edges(Graph, Vertex))
  end.

% Task for product
-spec(task(digraph:graph(), erdo:produced()) -> erdo:task()).
task(Graph, {product, ProductName}) ->
  FoundTasks = case find_product_vertex(Graph, ProductName) of
    false -> [];
    {ok, {Vertex, _Label}} ->
      lists:filtermap(
        fun(Edge) ->
            case digraph:edge(Graph, Edge) of
              {_Edge, TaskVertex, _PVertex, #production_edge_label{}} ->
                {_Vertex, #vertex_label{entity=#task{name=Task}}} = digraph:vertex(Graph, TaskVertex) ,
                { true, {task, Task} };
              _ -> false
            end
        end,
        digraph:in_edges(Graph, Vertex))
  end,
  case length(FoundTasks) of
    0 -> false;
    1 -> hd(FoundTasks);
    _ -> {err, {violated_invariant, single_producer}}
  end.

-spec(dependencies(digraph:graph(), erdo:produced()) -> [erdo:produced()]).
dependencies(Graph, {product, ProductName}) ->
  case find_product_vertex(Graph, ProductName) of
    false -> [];
    {ok, {Vertex, _Label}} -> vertex_dependencies(Graph, Vertex)
  end.

vertex_dependencies(Graph, Vertex) ->
  lists:filtermap(
    fun(Edge) ->
        case digraph:edge(Graph, Edge) of
          {_Edge, _TVertex, ProductVertex, #dep_edge_label{}} ->
            {_Vertex, #vertex_label{entity=#product{name=Product}}} = digraph:vertex(Graph, ProductVertex) ,
            { true, {product, Product} };
          _ -> false
        end
    end,
    digraph:out_edges(Graph, Vertex)).

-spec(build_list(digraph:graph(), [erdo:target()]) -> [erdo:build_spec()]).
build_list(Graph, Targets) ->
  SeqGraph = seq_graph(Graph),
  AlsoGraph = also_graph(Graph),
  Tasks = digraph_utils:reachable(
    lists:filtermap(fun({ok, {Vertex, _Label}}) -> {true, Vertex}; (_) -> false end,
        [find_task_vertex(Graph, Task) || Task <- tasks(Graph, Targets)]),
    AlsoGraph),
  Specs = [{task_from_vertex(Graph, Task), [task_from_vertex(Graph, PredTask) || PredTask <- digraph_utils:reaching_neighbours([Task], SeqGraph)]} ||
    Task <- digraph_utils:topsort(digraph_utils:subgraph(SeqGraph, Tasks))],
  digraph:delete(AlsoGraph), digraph:delete(SeqGraph),
  Specs.

task_from_vertex(Graph, Vertex) ->
  {Vertex, #vertex_label{name=TaskName}} = digraph:vertex(Graph,Vertex),
  TaskName.

-spec(task_deps(digraph:graph(), binary()) -> [erdo:produced()]).
task_deps(Graph, TaskName) ->
  {TaskVertex, _Label} = get_task_vertex(Graph, TaskName),
  ProducedVertices = [ DVertex ||
    {Edge, _TVertex, DVertex, Label} <- [digraph:edge(Graph, Edge) || Edge <- digraph:out_edges(Graph,TaskVertex)],
    is_record(Label, production_edge_label)
  ],
  lists:flatmap(fun(ProductVertex) -> vertex_dependencies(Graph, ProductVertex) end, ProducedVertices).

-spec(seq_graph(digraph:graph()) -> digraph:graph()).
seq_graph(Graph) ->
  SeqGraph = digraph:new([acyclic]),
  lists:foreach(
    fun(Vertex) ->
        case digraph:vertex(Graph, Vertex) of
          {Vertex, Label = #vertex_label{entity=#task{}}} ->
            digraph:add_vertex(SeqGraph, Vertex, Label);
          _ -> false
        end
    end,
    digraph:vertices(Graph)
  ),
  lists:foreach(
    fun({_Edge, FromTask, ToTask, Label = #seq_edge_label{}}) ->
        digraph:add_edge(SeqGraph, FromTask, ToTask, Label);
      ({_Edge, FromTask, ToProduct, _Label = #production_edge_label{}}) ->
        {ToProduct, #vertex_label{name=ProductName}} = digraph:vertex(Graph, ToProduct),
        lists:foreach(
          fun(Product) ->
              {task, TaskName} = task(Graph, Product),
              {ok, {ToTask, #vertex_label{}}} = find_task_vertex(Graph, TaskName),
              %seq runs opposite of dep
              digraph:add_edge(SeqGraph, ToTask, FromTask, #seq_edge_label{})
          end,
          dependencies(Graph, {product, ProductName}));
      (_) -> ok
    end,
    [digraph:edge(Graph, Edge) || Edge <- digraph:edges(Graph)]),
  SeqGraph.

-spec(also_graph(digraph:graph()) -> digraph:graph()).
also_graph(Graph) ->
  AlsoGraph = digraph:new(),
  lists:foreach(
    fun(Vertex) ->
        case digraph:vertex(Graph, Vertex) of
          {Vertex, Label = #vertex_label{entity=#task{}}} ->
            digraph:add_vertex(AlsoGraph, Vertex, Label);
          _ -> false
        end
    end,
    digraph:vertices(Graph)
  ),
  lists:foreach(
    fun({_Edge, FromTask, ToTask, Label = #cotask_edge_label{}}) ->
        digraph:add_edge(AlsoGraph, FromTask, ToTask, Label);
      ({_Edge, FromTask, ToProduct, _Label = #production_edge_label{}}) ->
        {ToProduct, #vertex_label{name=ProductName}} = digraph:vertex(Graph, ToProduct),
        lists:foreach(
          fun(Product) ->
              {task, TaskName} = task(Graph, Product),
              {ok, {ToTask, #vertex_label{}}} = find_task_vertex(Graph, TaskName),
              digraph:add_edge(AlsoGraph, FromTask, ToTask, #cotask_edge_label{})
          end,
          dependencies(Graph, {product, ProductName}));
      (_) -> ok
    end,
    [digraph:edge(Graph, Edge) || Edge <- digraph:edges(Graph)]),
  AlsoGraph.

-spec(tasks(digraph:graph(), [erdo:target()]) -> [erdo:task()]).
tasks(Graph, Targets) ->
  lists:map(
    fun(Target) ->
        case Target of
          {product, _ProductName} -> task(Graph, Target);
          {task, _} -> Target
        end
    end,
    Targets
  ).


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
-spec(find_task_vertex(digraph:graph(), string() | erdo:task()) -> false | {ok, {digraph:vertex(), #vertex_label{}}}).
find_task_vertex(Graph, {task, TaskName}) ->
  find_task_vertex(Graph, TaskName);
find_task_vertex(Graph, TaskName) ->
  find_entity_vertex(Graph, TaskName, task) .

-spec(find_entity_vertex(digraph:graph(), string(), atom()) -> false | {ok, {digraph:vertex(), #vertex_label{}}}).
find_entity_vertex(Graph, Name, Type) ->
  FoundVertices = lists:filter(
    fun({_Vertex, #vertex_label{name=LabelName, entity=Entity}}) ->
        is_record(Entity, Type) andalso LabelName =:= Name;
      (_) -> false
    end,
    [ digraph:vertex(Graph, Vertex) || Vertex <- digraph:vertices(Graph) ]
  ),
  case length(FoundVertices) of
    1 -> {ok, hd(FoundVertices)};
    0 -> false;
    _ -> {error, {violated_invariant, single_vertex_per_entity}}
  end.

get_product_vertex(Graph, ProductName) ->
  get_entity_vertex(Graph, product, ProductName, #product{name=ProductName}).

get_task_vertex(Graph, TaskName) ->
  get_entity_vertex(Graph, task, TaskName, #task{name=TaskName}).

find_product_vertex(Graph, ProductName) ->
  find_entity_vertex(Graph, ProductName, product).

get_entity_vertex(Graph, Type, Name, Entity) ->
  case find_entity_vertex(Graph, Name, Type) of
    {ok, EntityVertex} -> EntityVertex;
    false ->
      Vertex = digraph:add_vertex(Graph),
      Label = #vertex_label{name=Name, entity=Entity},
      digraph:add_vertex(Graph, Vertex, Label),
      {Vertex, Entity};
    _ -> {err, blegh}
  end.

%%% Tests

digraph_test_() ->
  ProductName = "x.out",
  DependsOn = "x.in",
  TaskName = [<<"compile">>,  <<"x">>],
  OtherTaskName = [<<"test">>, <<"x">>],
  DumpFilename = "test-dump.erdograph",

  {foreach, local, %digraphs are trapped in their process
    fun() -> digraph:new() end, %setup
    fun(Graph) -> digraph:delete(Graph) end, %teardown
    [
      fun(Graph) ->
          ?_test(begin
                ?assertMatch(ok, new_dep(Graph, {product, ProductName}, {product, DependsOn})),
                ?assertMatch(exists, new_dep(Graph, {product, ProductName}, {product, DependsOn})),
                ?assertEqual(1, length(digraph:edges(Graph)))
            end)
      end,
      fun(Graph) ->
          ?_test(begin
                ?assertMatch(ok, new_prod(Graph, {task, TaskName}, {product, ProductName})),
                ?assertMatch(exists, new_prod(Graph, {task, TaskName}, {product, ProductName})),
                ?assertEqual(1, length(digraph:edges(Graph)))
            end)
      end,
      fun(Graph) ->
          ?_test(begin
                ?assertMatch(ok, co_task(Graph, {task, TaskName}, {task, OtherTaskName})),
                ?assertMatch(exists, co_task(Graph, {task, TaskName}, {task, OtherTaskName})),
                ?assertEqual(1, length(digraph:edges(Graph)))
            end)
      end,
      fun(Graph) ->
          ?_test(begin
                ?assertMatch(ok, task_seq(Graph, {task, TaskName}, {task, OtherTaskName})),
                ?assertMatch(exists, task_seq(Graph, {task, TaskName}, {task, OtherTaskName})),
                ?assertEqual(1, length(digraph:edges(Graph)))
            end)
      end,
      fun(Graph) ->
          ?_test( begin
                new_dep(Graph, {product, ProductName}, {product, DependsOn}),
                ?assertMatch(ok,new_prod(Graph, {task, TaskName}, {product, ProductName})),
                ?assertEqual(
                  [{product, DependsOn}],
                  task_deps(Graph, TaskName)
                )
            end)
      end,
      fun(Graph) ->
          ?_test( begin
                new_dep(Graph, {product, ProductName}, {product, DependsOn}),
                ?assertMatch(ok,new_prod(Graph, {task, OtherTaskName}, {product, DependsOn})),
                ?assertMatch(ok,new_prod(Graph, {task, TaskName}, {product, ProductName})),
                ?assertEqual(
                  [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                  build_list(Graph, [{product, ProductName}])
                )
            end)
      end,
      fun(Graph) ->
          ?_test( begin
                new_dep(Graph, {product, ProductName}, {product, DependsOn}),
                ?assertMatch(ok,new_prod(Graph, {task, OtherTaskName}, {product, DependsOn})),
                ?assertMatch(ok,new_prod(Graph, {task, TaskName}, {product, ProductName})),
                ?assertMatch(ok, dump_to(Graph, DumpFilename)),
                NewGraph = load_from(DumpFilename),
                ?assertEqual(
                  [{OtherTaskName, []},{TaskName, [OtherTaskName]}],
                  build_list(NewGraph, [{product, ProductName}])
                )
            end)
      end
    ]
  }.
