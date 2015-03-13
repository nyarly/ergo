-module(ergo_build).
-behavior(gen_event).

%% API
-export([start/3]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3, link_to/3, check_alive/2]).

-record(state, {requested_targets, build_spec, build_id, workspace_dir, config, complete_tasks, run_counts, waiters}).

-type taskspec() :: ergo:taskspec().
-type config() :: [term()].

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
  gen_event:notify(Events, {build_start, WorkspaceName, BuildId, Targets}).

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
  {ok, #state{
      requested_targets=Targets,
      complete_tasks=[],
      config=[],
      build_spec=BuildSpec,
      build_id=BuildId,
      workspace_dir=WorkspaceName,
      run_counts=dict:new(),
      waiters=[]
    }
  }.

handle_event({build_start, WorkspaceName, BuildId, _}, OldState=#state{build_id=BuildId,workspace_dir=WorkspaceName}) ->
  State = load_config(OldState),
  start_tasks(State),
  {ok, State};
handle_event({task_failed, Task, Reason, _Output}, State) ->
  task_failed(Task, Reason, State),
  {ok, State};
handle_event({task_changed_graph, Task}, State) ->
  {ok, task_changed_graph(Task, State)};
handle_event({task_completed, Task}, State) ->
  {ok, task_completed(Task, State)};
handle_event({task_skipped, Task}, State) ->
  {ok, task_completed(Task, State)};
handle_event({build_completed, BuildId, Success, _Message}, State=#state{build_id=BuildId}) ->
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

load_config(State=#state{workspace_dir=Workspace}) ->
  config_into_state(file:consult(config_path(Workspace)), State).

config_path(Workspace) ->
  filename:join([Workspace,<<".ergo">>,<<"config">>]).

default_config() ->
  [].

config_into_state({error, Error}, State=#state{build_id=BuildId, workspace_dir=Workspace}) ->
  ergo_events:build_warning(Workspace, BuildId, {error, Error, config_path(Workspace)}),
  State#state{config=default_config()};
config_into_state({ok, Config}, State) ->
  State#state{config=Config}.

task_failed(_Task, Reason, #state{build_id=BuildId, workspace_dir=WorkspaceDir}) ->
  ergo_events:build_completed(WorkspaceDir, BuildId, false, {task_failed, Reason}).

task_changed_graph({task, _Task}, State=#state{workspace_dir=Workspace, requested_targets=Targets}) ->
  BuildSpec=ergo_graphs:build_list(Workspace, Targets),
  NewState = State#state{complete_tasks=[],build_spec=BuildSpec},
  start_tasks(NewState),
  NewState.

task_completed({task, Task}, State = #state{run_counts= RunCounts, workspace_dir=WorkspaceDir, complete_tasks=PrevCompleteTasks}) ->
  CompleteTasks = [Task | PrevCompleteTasks],
  ok = ergo_freshness:store(WorkspaceDir, Task),
  NewState = State#state{
    complete_tasks=CompleteTasks,
    run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)
  },
  start_tasks(NewState),
  NewState.

-spec(start_tasks(#state{}) -> ok | {err, term()}).
start_tasks(#state{workspace_dir=WorkspaceDir, build_spec=[], build_id=BuildId}) ->
  ergo_events:build_completed(WorkspaceDir, BuildId, true, {});
start_tasks(State=#state{build_spec=BuildSpec, complete_tasks=CompleteTasks}) ->
  start_eligible_tasks(eligible_tasks(BuildSpec, CompleteTasks), State).

start_eligible_tasks([], #state{workspace_dir=WorkspaceDir, build_id=BuildId}) ->
  ergo_events:build_completed(WorkspaceDir, BuildId, true, {});
start_eligible_tasks(TaskList, #state{workspace_dir=WorkspaceDir, build_id=BuildId, config=Config, run_counts=RunCounts}) ->
  lists:foreach(
    fun(Task) -> start_task(WorkspaceDir, BuildId, Task, Config, RunCounts) end,
    TaskList).



run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

-record(task_config,
        {
         workspace,
         build_id,
         task,
         fullexe,
         args,
         taskconfig,
         runlimit=?RUN_LIMIT,
         runcounts,
         runcount,
         freshness
        }).

start_task(Workspace, BuildId, Task, Config, RunCounts) ->
  start_task(#task_config{workspace=Workspace, build_id=BuildId, task=Task, taskconfig=Config, runcount=run_count(Task,RunCounts)}).

start_task(#task_config{task=Task,workspace=Workspace,runcount=RC,runlimit=RL}) when RC >= RL ->
  Error={too_many_repetitions, Task, RC},
  ergo_events:task_failed(Workspace, {task, Task}, Error, []),
  {err, Error};
start_task(#task_config{fullexe={error,FileError}, task=Task, workspace=Workspace}) ->
  Error={couldnt_open, FileError, {task, Task}, {workspace, Workspace}},
  ergo_events:task_failed(Workspace, {task, Task}, Error, []),
  {err, Error};

start_task(TC=#task_config{fullexe=undefined,workspace=Workspace,task=[TaskCmd|Args]}) ->
  start_task(TC#task_config{fullexe=task_executable(Workspace, TaskCmd),args=Args});
start_task(TC=#task_config{freshness=undefined,fullexe=FullExe,workspace=Workspace,task=Task}) ->
  start_task(TC#task_config{
               freshness= ergo_freshness:check(Workspace, Task)});
start_task(#task_config{workspace=Workspace, task=Task, freshness=hit}) ->
  ergo_events:task_skipped(Workspace, {task, Task}),
  ok;
start_task(#task_config{workspace=Workspace, build_id=BuildId, task=Task, fullexe=FullExe, args=Args, taskconfig=Config, freshness=miss}) ->
  ergo_workspace:start_task(Workspace, BuildId, {Task, FullExe, Args}, Config).


-spec(task_executable([file:name_all()], binary()) -> file:name_all()).
task_executable(TaskPath, Taskname) ->
  handle_task_executable(file:path_open([TaskPath], Taskname, [read])).

handle_task_executable({ok, Io, FullPath})->
  ok = file:close(Io),
  FullPath;
handle_task_executable(Error) ->
  {error, Error}.


build_completed(#state{waiters=Waiters,build_id=BuildId,requested_targets=Targets}, _Succeeded) ->
  [exit(Waiter,{build_completed,BuildId,Targets}) || Waiter <- Waiters].

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
