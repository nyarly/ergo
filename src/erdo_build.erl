-module(erdo_build).
-behavior(gen_event).

%% API
-export([add_to/1, add_to/2, add_to_sup/1, add_to_sup/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {requested_targets, build_spec, complete_tasks, run_counts}).
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
init(Targets) ->
  BuildSpec=erdo_graphs:build_spec(Targets),
  start_tasks(BuildSpec, [], dict:new()),
  {ok, #state{
      requested_targets=Targets,
      complete_tasks=[],
      build_spec=BuildSpec,
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

task_completed(Task, State = #state{build_spec=BuildSpec, complete_tasks=PrevCompleteTasks}) ->
  RunCounts = State#state.run_counts,
  CompleteTasks = [Task | PrevCompleteTasks],
  start_tasks(BuildSpec, CompleteTasks, RunCounts),
  State#state{complete_tasks=CompleteTasks,
    run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)}.

start_tasks(BuildSpec, CompleteTasks, RunCounts) ->
  lists:foreach(
    fun(Task) -> start_task(Task, run_count(Task, RunCounts)) end,
    eligible_tasks(BuildSpec, CompleteTasks)).

run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

start_task(Task, RunCount) when RunCount < ?RUN_LIMIT ->
  erdo_project:start_task(Task);
start_task(Task, RunCount) when RunCount >= ?RUN_LIMIT ->
  {err, {too_many_repetitions, Task, RunCount}}.

eligible_tasks(BuildSpec, CompleteTasks) ->
  lists:subtract(
    [ Task || { Task, Predecessors } <- BuildSpec,
      length(complete(Predecessors, CompleteTasks)) =:= length(Predecessors) ],
    CompleteTasks
  ).

complete(TaskList, CompleteTasks) ->
  [ Task || Task <- TaskList, CompleteTask <- CompleteTasks, Task =:= CompleteTask ].
