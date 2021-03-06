-module(ergo_graphs).
-behavior(gen_server).
%% API
-export([get_products/2,get_dependencies/2,get_metadata/2,
         all_transitive_requirements/2, leaf_transitive_requirements/2,
         build_list/2,task_batch/5,task_invalid/3]).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("stdlib/include/qlc.hrl").

-include("ergo_graphs.hrl").
-export_type([change_status/0]).

-define(VIA(WorkspaceName), {via, ergo_workspace_registry, {WorkspaceName, graph, only}}).
start_link(Workspace) ->
  gen_server:start_link({via, ergo_workspace_registry, {Workspace, graph, only}}, ?MODULE, [Workspace], []).


-spec(get_products(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_products(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {products, Task}).

-spec(get_dependencies(ergo:workspace_name(), ergo:task()) -> [ergo:productname()]).
get_dependencies(Workspace, Task) ->
  gen_server:call(?VIA(Workspace), {dependencies, Task}).

-spec(build_list(ergo:workspace_name(), [ergo:target()]) -> ergo:build_spec()).
build_list(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {build_list, Targets}).

-spec(all_transitive_requirements(ergo:workspace_name(), [ergo:target()]) -> [ergo:produced()]).
all_transitive_requirements(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {all_transitive_requirements, Targets}).

-spec(leaf_transitive_requirements(ergo:workspace_name(), [ergo:target()]) -> [ergo:produced()]).
leaf_transitive_requirements(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {leaf_transitive_requirements, Targets}).

-spec(get_metadata(ergo:workspace_name(), ergo:target()) -> [{atom(), term()}]).
get_metadata(Workspace, Target) ->
  gen_server:call(?VIA(Workspace), {get_metadata, Target}).


%% @spec:	task_batch(Task::ergo:taskname(),Graph::ergo:graph_item()) -> ok.
%% @doc:	Receives a batch of build-graph edges from a particular task.
%% @end

%% XXX change boolean "Succeeded" to atoms - Result: succees|failure
-spec(task_batch(ergo:workspace_name(), ergo:build_id(), ergo:taskname(),Graph::[ergo:graph_item()], Succeeded::boolean()) -> change_report()).
task_batch(Workspace, BuildId, Task, Graph, Succeeded) ->
  gen_server:call(?VIA(Workspace), {task_batch, BuildId, Task, Graph, Succeeded}).

-spec(task_invalid(ergo:workspace_name(), ergo:build_id(), ergo:taskname()) -> ok).
task_invalid(Workspace, BuildId, Task) ->
  gen_server:call(?VIA(Workspace), {task_invalid, BuildId, Task}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([Workspace]) ->
  {ok, ergo_graph_db:build_state(Workspace) }.

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
  {reply, ergo_graph_db:products(State, Task), State};
handle_call({dependencies, Task}, _From, State) ->
  {reply, ergo_graph_db:dependencies(State, Task), State};
handle_call({build_list, Targets}, _From, State) ->
  {NewState, Result} = ergo_graph_db:handle_build_list(State,Targets),
  {reply, Result, NewState};
handle_call({all_transitive_requirements, Targets}, _From, State) ->
  {NewState, Result} = ergo_graph_db:all_transitive_requirements(State,Targets),
  {reply, {ok, Result}, NewState};
handle_call({leaf_transitive_requirements, Targets}, _From, State) ->
  {NewState, Result} = ergo_graph_db:leaf_transitive_requirements(State,Targets),
  {reply, {ok, Result}, NewState};
handle_call({task_invalid, BuildId, Task}, _From, State) ->
  {reply, invalidate_task(BuildId, Task, State), State};
handle_call({task_batch, BuildId, Task, Graph, Succeeded}, _From, OldState) ->
  State = ergo_graph_db:update_batch_id(OldState),
  {reply, ergo_graph_db:absorb_task_batch(BuildId, Task, Graph, Succeeded, State), State};
handle_call({get_metadata, Thing}, _From, State) ->
  {reply, ergo_graph_db:handle_get_metadata(Thing, State), State};

handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
handle_info(_Info, State) ->
  {noreply, State}.
terminate(_Reason, State) ->
  ergo_graph_db:cleanup_state(State),
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%

invalidate_task(BuildId, Task, State) ->
  report_invalid_provenences( ergo_graph_db:remove_task(Task, State), Task, BuildId, State).

report_invalid_provenences(EPs, Task, BuildId, #state{workspace=Workspace}) ->
  [report_invalid_provenence(Workspace, BuildId, Task, EP) || EP <- EPs].

-spec(report_invalid_provenence(ergo:workspace_name(), ergo:build_id(), ergo:taskname(), {ergo:graph_item(), ergo:taskname()}) -> ok).
report_invalid_provenence(Workspace, BuildId, About, {Statement, Asserter}) ->
  ergo_events:invalid_provenence(Workspace, BuildId, About, Asserter, Statement).
