-module(ergo_build).
-behavior(gen_server).

%% API
-export([start/3]).

%% gen_event callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3,
         link_to/3, check_alive/2, task_exited/6]).

-record(state, {
          requested_targets :: [ergo:target()],
          build_spec,
          build_id          :: ergo:build_id(),
          workspace_dir     :: ergo:workspace_name(),
          config            :: config(),
          complete_tasks,
          run_counts
         }).

-type config() :: [term()].

-define(VIA(Workspace, Id), {via, ergo_workspace_registry, ?VIA_TUPLE(Workspace, Id)}).
-define(VIA_TUPLE(Workspace, Id), {Workspace, build, Id}).
-define(ID(Workspace, Id), {?MODULE, {ergo_workspace_registry:normalize_name(Workspace), Id}}).
-define(RUN_LIMIT,20).

%%%===================================================================
%%% Module API
%%%===================================================================

-spec start(ergo:workspace_name(), integer(), [ergo:target()]) -> ok.
start(Workspace, BuildId, Targets) ->
  gen_server:start(?VIA(Workspace, BuildId), ?MODULE, {Workspace, BuildId, Targets}),
  gen_server:call(?VIA(Workspace, BuildId), {build_start, Workspace, BuildId, something}).


task_exited(Workspace, BuildId, Task, GraphChanged, Outcome, Remaining) ->
  gen_server:call(?VIA(Workspace, BuildId), {task_exit, Task, GraphChanged, Outcome, Remaining}).


link_to(Workspace, Id, _) ->
  link_to(Workspace, Id).

link_to(Workspace, Id) ->
  ergo_workspace_registry:link_to(?VIA_TUPLE(Workspace, Id)).

check_alive(Workspace, Id) ->
  case ergo_workspace_registry:whereis_name(?VIA_TUPLE(Workspace, Id)) of
    undefined -> dead;
    _ -> alive
  end.

%%%%%%%%%%%%%%%%%%%
%  Notes to self  %
%%%%%%%%%%%%%%%%%%%

build_completed(Workspace, BuildId, Success, Message) ->
  ergo_events:build_completed(Workspace, BuildId, Success, Message),
  gen_server:call(?VIA(Workspace, BuildId), {build_completed}).

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
      run_counts=dict:new()
    }
  }.

handle_call({build_start, WorkspaceName, BuildId, _}, _From, OldState=#state{build_id=BuildId,workspace_dir=WorkspaceName}) ->
  State = load_config(OldState),
  {reply, ok, start_tasks(0, State)};
handle_call({task_exit, Task, GraphChange, Outcome, Remaining}, _From, State) ->
  NewState = handle_task_exited( Task, Outcome, Remaining,
                                 handle_graph_changes(GraphChange, State)),
  {reply, ok, NewState};


%XXX needs to be a cast?
handle_call({build_completed}, _From, State) ->
  {stop, complete, ok, State};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Request, State) ->
  {noreply, State}.

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
  ergo_events:build_warning(Workspace, BuildId, {configfile, Error, config_path(Workspace)}),
  State#state{config=default_config()};
config_into_state({ok, Config}, State) ->
  State#state{config=Config}.

handle_graph_changes(changed, State=#state{build_id=Bid}) ->
  ergo_task_pool:scrub_pending(Bid),
  State#state{build_spec=out_of_date};
handle_graph_changes(no_change, State) ->
  State.

handle_task_exited(_Task, {failed, Reason, _Output}, _, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_failed, Reason}),
  State;
handle_task_exited(_Task, {invalid, Message}, _R, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_invalid, Message}),
  State;
handle_task_exited(Task, _, Remaining, State) ->
  task_completed(Task, Remaining, State).

task_completed(Task, Waiting, State = #state{run_counts= RunCounts, complete_tasks=CompleteTasks}) ->
  start_tasks(Waiting, State#state{
               complete_tasks=[Task | CompleteTasks],
               run_counts=dict:store(Task, run_count(Task, RunCounts) + 1, RunCounts)
  }).

-spec(start_tasks(integer(), #state{}) -> ok | {err, term()}).
start_tasks(0, State=#state{workspace_dir=WorkspaceDir, build_spec=[], build_id=BuildId}) ->
  build_completed(WorkspaceDir, BuildId, true, {}),
  State;
start_tasks(_, State=#state{build_spec=[]}) ->
  State;
start_tasks(0, State=#state{build_spec=out_of_date, workspace_dir=Workspace, requested_targets=Targets}) ->
  BuildSpec=ergo_graphs:build_list(Workspace, Targets),
  NewState = State#state{complete_tasks=[],build_spec=BuildSpec},
  start_tasks(0, NewState);
start_tasks(_, State=#state{build_spec=out_of_date}) ->
  State;

start_tasks(_, State=#state{build_spec=BuildSpec, complete_tasks=CompleteTasks}) ->
  Eligible = eligible_tasks(BuildSpec, CompleteTasks),
  start_eligible_tasks(Eligible, State),
  State.

start_eligible_tasks([], _) ->
  ok;
start_eligible_tasks(TaskList, #state{workspace_dir=WorkspaceDir, build_id=BuildId, config=Config, run_counts=RunCounts}) ->
  ergo_events:task_generation(WorkspaceDir, BuildId, TaskList),
  [ start_task(WorkspaceDir, BuildId, Task, Config, RunCounts) || Task <- TaskList ].


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
         taskconfig,
         runlimit=?RUN_LIMIT,
         runcounts,
         runcount
        }).

start_task(Workspace, BuildId, Task, Config, RunCounts) ->
  start_task(#task_config{workspace=Workspace, build_id=BuildId, task=Task, taskconfig=Config, runcount=run_count(Task,RunCounts)}).

start_task(#task_config{task=Task,workspace=Workspace,build_id=BuildId,runcount=RC,runlimit=RL}) when RC >= RL ->
  Error={too_many_repetitions, Task, RC},
  ergo_events:task_failed(Workspace, BuildId, {task, Task}, Error, []),
  {err, Error};
start_task(#task_config{workspace=Workspace, build_id=BuildId, task=Task, taskconfig=Config}) ->
  ergo_task_pool:start_task(Workspace, BuildId, Task, Config).

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
