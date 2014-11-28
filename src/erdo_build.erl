-module(erdo_build).
-behavior(gen_event).

%% API
-export([add_to/1, add_to/2, add_to_sup/1, add_to_sup/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {requested_targets, build_spec, project_dir, complete_tasks, run_counts}).
-define(RUN_LIMIT,20).

%%%===================================================================
%%% Module API
%%%===================================================================
add_to(Server) ->
  add_to(Server, []).

add_to(Server, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_handler(Server, ?MODULE, Args),
  Handler.

add_to_sup(Server) ->
  add_to_sup(Server, []).

add_to_sup(Server, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler(Server, ?MODULE, Args),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init({Targets, ProjectDir}) ->
  BuildSpec=erdo_graphs:build_spec(Targets),
  start_tasks(ProjectDir, BuildSpec, [], dict:new()),
  {ok, #state{
      requested_targets=Targets,
      complete_tasks=[],
      build_spec=BuildSpec,
      project_dir=ProjectDir,
      run_counts=dict:new()
    }
  }.

handle_event({task_completed, Task}, State) ->
  {ok, task_completed(Task, State)};
handle_event(_Event, State) ->
  {ok, State}.

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

task_completed(Task, State = #state{build_spec=BuildSpec, project_dir=ProjectDir, complete_tasks=PrevCompleteTasks}) ->
  RunCounts = State#state.run_counts,
  CompleteTasks = [Task | PrevCompleteTasks],
  erdo_freshness:store(Task, ProjectDir, task_deps(Task), task_products(Task)),
  start_tasks(ProjectDir, BuildSpec, CompleteTasks, RunCounts),
  State#state{
    complete_tasks=CompleteTasks,
    run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)
  }.

start_tasks(ProjectDir, BuildSpec, CompleteTasks, RunCounts) ->
  lists:foreach(
    fun(Task) -> start_task(ProjectDir, Task, run_count(Task, RunCounts)) end,
    eligible_tasks(BuildSpec, CompleteTasks)).

run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

start_task(_ProjectRoot, Task, RunCount) when RunCount >= ?RUN_LIMIT ->
  {err, {too_many_repetitions, Task, RunCount}};
start_task(ProjectRoot, Task, RunCount) ->
  [ RelExe | Args ] = Task,
  {ok, Io, FullExe} = task_executable([ProjectRoot], RelExe),
  file:close(Io),
  start_task(ProjectRoot, {Task, FullExe, Args}, RunCount, erdo_freshness:check(Task, ProjectRoot, [FullExe | erdo_graph:dependencies(Task)])).

start_task(_ProjectRoot, {Task, _Exe, _Args}, _RunCount, hit) ->
  erdo_events:task_skipped({task, Task}),
  ok;
start_task(_ProjectRoot, TaskSpec, _RunCount, _Fresh) ->
  erdo_project:start_task(TaskSpec).

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
