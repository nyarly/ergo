-module(erdo_build).
-behavior(gen_event).

%% API
-export([start/3]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {requested_targets, build_spec, build_id, workspace_dir, complete_tasks, run_counts, waiters}).

-define(VIA(Workspace), {via, erdo_workspace_registry, {Workspace, events, only}}).
-define(ID(Workspace, Id), {?MODULE, {Workspace, Id}}).
-define(RUN_LIMIT,20).

%%%===================================================================
%%% Module API
%%%===================================================================

start(WorkspaceName, BuildId, Targets) ->
  Events = ?VIA(WorkspaceName),
  gen_event:add_hander(Events, ?ID(WorkspaceName, BuildId), {WorkspaceName, BuildId, Targets}),
  gen_event:notify(Events, {build_start, WorkspaceName, BuildId}).

link_to(Workspace, Id, Pid) ->
  gen_event:call(?VIA(Workspace), ?ID(Workspace, Id), {exit_when_done, Pid}).


%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init({WorkspaceName, BuildId, Targets}) ->
  BuildSpec=erdo_graphs:build_spec(Targets),
  {ok, #state{
      requested_targets=Targets,
      complete_tasks=[],
      build_spec=BuildSpec,
      build_id=BuildId,
      workspace_dir=WorkspaceName,
      run_counts=dict:new(),
      waiters=[]
    }
  }.

handle_event({build_start, WorkspaceName, BuildId},
             State=#state{build_spec=BuildSpec,build_id=BuildId,workspace_dir=WorkspaceName}) ->
  {ok, start_tasks(WorkspaceName, BuildSpec, [], dict:new()), State};
handle_event({task_completed, Task}, State) ->
  {ok, task_completed(Task, State)};
handle_event({build_completed, BuildId}, State=#state{build_id=BuildId}) ->
  build_completed(State),
  remove_handler;
handle_event(_Event, State) ->
  {ok, State}.

handle_call({exit_when_done, Pid}, State=#state{waiters=Waiters}) ->
  {ok, ok, State#state{waiters=[Pid|Waiters]}};
handle_call(_Request, State) ->
  Reply = ok,
  {ok, Reply, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%% Internal functions

-spec(task_executable([file:name_all()], binary()) -> file:name_all()).
task_executable(TaskPath, Taskname) ->
  file:path_open(TaskPath, Taskname).

task_completed(Task, State = #state{build_spec=BuildSpec, workspace_dir=WorkspaceDir, complete_tasks=PrevCompleteTasks}) ->
  RunCounts = State#state.run_counts,
  CompleteTasks = [Task | PrevCompleteTasks],
  erdo_freshness:store(Task, WorkspaceDir, task_deps(Task), task_products(Task)),
  start_tasks(WorkspaceDir, BuildSpec, CompleteTasks, RunCounts),
  State#state{
    complete_tasks=CompleteTasks,
    run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)
  }.

start_tasks(WorkspaceDir, BuildSpec, CompleteTasks, RunCounts) ->
  lists:foreach(
    fun(Task) -> start_task(WorkspaceDir, Task, run_count(Task, RunCounts)) end,
    eligible_tasks(BuildSpec, CompleteTasks)).

run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

start_task(_WorkdspaceRoot, Task, RunCount) when RunCount >= ?RUN_LIMIT ->
  {err, {too_many_repetitions, Task, RunCount}};
start_task(WorkspaceRoot, Task, RunCount) ->
  [ RelExe | Args ] = Task,
  {ok, Io, FullExe} = task_executable([WorkspaceRoot], RelExe),
  file:close(Io),
  start_task(WorkspaceRoot, {Task, FullExe, Args}, RunCount, erdo_freshness:check(Task, WorkspaceRoot, [FullExe | erdo_graph:dependencies(Task)])).

build_completed(#state{waiters=Waiters,build_id=BuildId,requested_targets=Targets}) ->
  [exit(Waiter,{build_completed,BuildId,Targets}) || Waiter <- Waiters].

start_task(_WorkspaceRoot, {Task, _Exe, _Args}, _RunCount, hit) ->
  erdo_events:task_skipped({task, Task}),
  ok;
start_task(_WorkspaceRoot, TaskSpec, _RunCount, _Fresh) ->
  erdo_workspace:start_task(TaskSpec).

task_deps(Task) ->
  erdo_graphs:get_dependencies({task, Task}).

task_products(Task) ->
  erdo_graphs:get_products({task, Task}).

eligible_tasks(BuildSpec, CompleteTasks) ->
  lists:subtract(
    [ Task || { Task, Predecessors } <- BuildSpec,
      length(complete(Predecessors, CompleteTasks)) =:= length(Predecessors) ],
    CompleteTasks
  ).

complete(TaskList, CompleteTasks) ->
  [ Task || Task <- TaskList, CompleteTask <- CompleteTasks, Task =:= CompleteTask ].
