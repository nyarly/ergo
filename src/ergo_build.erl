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

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%%===================================================================
%%% Module API
%%%===================================================================

-spec start(ergo:workspace_name(), integer(), [ergo:target()]) -> ok.
start(Workspace, BuildId, Targets) ->
  gen_server:start(?VIA(Workspace, BuildId), ?MODULE, {Workspace, BuildId, Targets}, []),
  gen_server:call(?VIA(Workspace, BuildId), {build_start, Workspace, BuildId, something}).


task_exited(Workspace, BuildId, Task, GraphChanged, Outcome, Remaining) ->
  gen_server:cast(?VIA(Workspace, BuildId), {task_exit, Task, GraphChanged, Outcome, Remaining}).


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
  gen_server:cast(?VIA(Workspace, BuildId), {build_completed}).

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


%XXX needs to be a cast?
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast({build_completed}, State) ->
  {stop, complete, State};
handle_cast({task_exit, Task, GraphChange, Outcome, Remaining}, State) ->
  {noreply,
   handle_task_exited( Task, GraphChange, Outcome, Remaining,
                       handle_graph_changes(GraphChange, State)) };
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

handle_graph_changes(changed, State) ->
  ergo_task_pool:scrub_build(),
  State#state{build_spec=out_of_date};
handle_graph_changes(no_change, State) ->
  State.

handle_task_exited(_Task, no_change, {failed, Reason, _Output}, _, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_failed, Reason}),
  State;
handle_task_exited(_Task, _, {invalid, Message}, _, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_invalid, Message}),
  State;
handle_task_exited(Task, _, _, Remaining, State) ->
  task_completed(Task, Remaining, State).

task_completed(Task, Waiting, State = #state{build_spec=BSpec, run_counts= RunCounts, complete_tasks=CompleteTasks}) ->
  start_tasks(Waiting, State#state{
                         build_spec=reduce_build_spec(Task, BSpec),
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

start_tasks(_, State=#state{build_spec=BuildSpec}) ->
  Eligible = eligible_tasks(BuildSpec),
  start_eligible_tasks(Eligible, State).

start_eligible_tasks([], State=#state{build_spec=[]}) ->
  State;
start_eligible_tasks([], State) ->
  State;
start_eligible_tasks(TaskList, State=#state{workspace_dir=WorkspaceDir, build_id=BuildId, config=Config, run_counts=RunCounts}) ->
  ergo_events:task_generation(WorkspaceDir, BuildId, TaskList),
  lists:foldl(fun(Task, St) ->
                  process_start_result(
                    start_task(WorkspaceDir, BuildId, Task, Config, run_count(Task, RunCounts)),
                    Task, St)
              end, State, TaskList).

process_start_result(ok, Task, State=#state{build_spec=Spec}) ->
  State#state{build_spec=remove_started_task(Task, Spec)};
process_start_result(_, _, State) ->
  State.



run_count(Task, RunCounts) ->
  case dict:find(Task, RunCounts) of
    {ok, Count} -> Count;
    error -> 0
  end.

start_task(Workspace, BuildId, Task, _, RunCounts) when RunCounts >= ?RUN_LIMIT ->
  Error={too_many_repetitions, Task, RunCounts, ?RUN_LIMIT},
  ergo_events:task_failed(Workspace, BuildId, {task, Task}, Error, []),
  {err, Error};
start_task(Workspace, BuildId, Task, Config, _) ->
  ergo_task_pool:start_task(Workspace, BuildId, Task, Config).

eligible_tasks(BuildSpec) ->
  [Task || {Task, []} <- BuildSpec].

remove_started_task(_, out_of_date) ->
  out_of_date;
remove_started_task(Task, Spec) ->
  [{TN, Deps} || {TN, Deps} <- Spec, TN =/=Task].

reduce_build_spec(_, out_of_date) ->
  out_of_date;
reduce_build_spec(Task, Spec) ->
  [ {TN, Deps -- [Task]} || {TN, Deps} <- Spec, TN =/= Task].

-ifdef(TEST).
module_test_() ->
  % convenience variables
  {
    foreach,
    fun() ->  %setup
      dbg:tracer(),
      dbg:p(all, c),
      ok
    end,
    fun(_State) -> %teardown
      dbg:ctp(), dbg:p(all, clear),
      ok
  end,
  [
   fun(_) ->
     {"Eligible tasks",
     ?_test(begin
              ?assertEqual([ready], eligible_tasks([{ready, []}, {not_ready, [ready]}, {also_not, [other]}]))
       end)
     }
   end,
   fun(State) ->
     {"Remove started tasks",
     ?_test(begin
       ?assertEqual(remove_started_task(started, [{started, []}, {not_ready, [started]}]),
                    [{not_ready, [started]}])
       end)
     }
   end,


   fun(_) ->
     {"Spec reduction should handle out_of_date spec",
     ?_test(begin
              ?assertEqual(out_of_date, reduce_build_spec(any_task, out_of_date))
       end)
     }
   end,
   fun(_) ->
       {"Spec reduction should remove a completed task",
        ?_test(begin
                 Reduced = reduce_build_spec(done_task, [{done_task, []}, {other_task, [done_task]}, {last_task, [other_task, done_task]}]),
                 ?assertMatch( Reduced, [{other_task, []}, {last_task, [other_task]}])
               end)
       }
   end
  ]}.
-endif.
