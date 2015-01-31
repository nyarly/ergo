-module(ergo_build).
-behavior(gen_event).

%% API
-export([start/3]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3, link_to/3, check_alive/2]).

-record(state, {requested_targets, build_spec, build_id, workspace_dir, complete_tasks, run_counts, waiters}).

-type taskspec() :: ergo:taskspec().

-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).
-define(ID(Workspace, Id), {?MODULE, {ergo_workspace_registry:normalize_name(Workspace), Id}}).
-define(RUN_LIMIT,20).

%%%===================================================================
%%% Module API
%%%===================================================================

-spec start(ergo:workspace_name(), integer(), [ergo:target()]) -> ok.
start(Workspace, BuildId, Targets) ->
  WorkspaceName = ergo_workspace_registry:normalize_name(Workspace),
  Events = ?VIA(WorkspaceName),
  gen_event:add_handler(Events, ?ID(WorkspaceName, BuildId), {WorkspaceName, BuildId, Targets}),
  gen_event:notify(Events, {build_start, WorkspaceName, BuildId}).

link_to(Workspace, Id, Pid) ->
  gen_event:call(?VIA(Workspace), ?ID(Workspace, Id), {exit_when_done, Pid}).

check_alive(Workspace, Id) ->
  case gen_event:call(?VIA(Workspace), ?ID(Workspace, Id), {check_alive}) of
    alive -> alive;
    Other -> ct:pal("~p", [Other]), dead
  end.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init({WorkspaceName, BuildId, Targets}) ->
  BuildSpec=ergo_graphs:build_list(WorkspaceName, Targets),
  ct:pal("Build triggered with ~p,~p~n~p -> ~p", [WorkspaceName, BuildId, Targets, BuildSpec]),
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

handle_event({build_start, WorkspaceName, BuildId}, State=#state{build_id=BuildId,workspace_dir=WorkspaceName}) ->
  start_tasks(State),
  {ok, State};
handle_event({task_failed, Task, _Reason}, State) ->
  task_failed(Task, State),
  {ok, State};
handle_event({task_completed, Task}, State) ->
  ct:pal("build got {task_completed, ~p}", [Task]),
  {ok, task_completed(Task, State)};
handle_event({build_completed, BuildId, Success}, State=#state{build_id=BuildId}) ->
  build_completed(State, Success),
  remove_handler;
handle_event(_Event, State) ->
  {ok, State}.

handle_call({exit_when_done, Pid}, State=#state{waiters=Waiters}) ->
  {ok, ok, State#state{waiters=[Pid|Waiters]}};
handle_call({check_alive}, State) ->
  {ok, alive, State};
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
  {ok, Io, FullExe} = file:path_open([TaskPath], Taskname, [read]),
  ok = file:close(Io),
  FullExe.

task_failed(_Task, #state{build_id=BuildId, workspace_dir=WorkspaceDir}) ->
  ergo_events:build_completed(WorkspaceDir, BuildId, false).

task_completed({task, Task}, State = #state{run_counts= RunCounts, workspace_dir=WorkspaceDir, complete_tasks=PrevCompleteTasks}) ->
  CompleteTasks = [Task | PrevCompleteTasks],
  ok = ergo_freshness:store(Task, WorkspaceDir, task_deps(WorkspaceDir, Task), task_products(WorkspaceDir, Task)),
  ct:pal("stored freshness"),
  NewState = State#state{
    complete_tasks=CompleteTasks,
    run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)
  },
  start_tasks(NewState),
  ct:pal("started next tasks"),
  NewState.

-spec(start_tasks(#state{}) -> ok | {err, term()}).
start_tasks(#state{workspace_dir=WorkspaceDir, build_spec=[], build_id=BuildId}) ->
  ct:pal("Start with empty build - quitting ~p", [WorkspaceDir]),
  ergo_events:build_completed(WorkspaceDir, BuildId, true);
start_tasks(State=#state{build_spec=BuildSpec, complete_tasks=CompleteTasks}) ->
  ct:pal("Starting for ~p | ~p",[BuildSpec, CompleteTasks]),
  start_eligible_tasks(eligible_tasks(BuildSpec, CompleteTasks), State).

start_eligible_tasks([], #state{workspace_dir=WorkspaceDir, build_id=BuildId}) ->
  ct:pal("No remaining eligible tasks"),
  ergo_events:build_completed(WorkspaceDir, BuildId, true);
start_eligible_tasks(TaskList, #state{workspace_dir=WorkspaceDir, run_counts=RunCounts}) ->
  lists:foreach(
    fun(Task) -> start_task(WorkspaceDir, Task, run_count(Task, RunCounts)) end,
    TaskList).



run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

-spec(start_task(ergo:workspace_name(), ergo:taskname(), integer()) -> ok | {err, term()}).
start_task(_WorkspaceRoot, Task, RunCount) when RunCount >= ?RUN_LIMIT ->
  {err, {too_many_repetitions, Task, RunCount}};
start_task(WorkspaceRoot, Task, RunCount) ->
  ct:pal("~p~p~p~n", [WorkspaceRoot, Task, RunCount]),
  [ RelExe | Args ] = Task,
  FullExe = task_executable(WorkspaceRoot, RelExe),
  start_task(WorkspaceRoot, {Task, FullExe, Args}, RunCount,
             ergo_freshness:check(Task, WorkspaceRoot, [FullExe | ergo_graphs:get_dependencies(WorkspaceRoot, {task, Task})])).

-spec(start_task(ergo:workspace_name(), taskspec(), integer(), hit | miss) -> ok | {err, term()}).
start_task(WorkspaceRoot, {Task, _Exe, _Args}, _RunCount, hit) ->
  ergo_events:task_skipped(WorkspaceRoot, {task, Task}),
  ok;
start_task(WorkspaceRoot, TaskSpec, _RunCount, _Fresh) ->
  ergo_workspace:start_task(WorkspaceRoot, TaskSpec).

build_completed(#state{waiters=Waiters,build_id=BuildId,requested_targets=Targets}, _Succeeded) ->
  [exit(Waiter,{build_completed,BuildId,Targets}) || Waiter <- Waiters].

task_deps(Workspace, Task) ->
  ergo_graphs:get_dependencies(Workspace, {task, Task}).

task_products(Workspace, Task) ->
  ergo_graphs:get_products(Workspace, {task, Task}).

eligible_tasks(BuildSpec, CompleteTasks) ->
  lists:subtract(
    [ Task || { Task, Predecessors } <- BuildSpec,
      length(complete(Predecessors, CompleteTasks)) =:= length(Predecessors) ],
    CompleteTasks
  ).

complete(_TaskList, []) ->
  [];
complete(TaskList, CompleteTasks) ->
  [ Task || Task <- TaskList, CompleteTask <- CompleteTasks, Task =:= CompleteTask ].
