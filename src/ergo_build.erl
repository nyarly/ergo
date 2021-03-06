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
  {ok, _} = gen_server:start(?VIA(Workspace, BuildId), ?MODULE, {Workspace, BuildId, Targets}, []),
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
  {stop, {shutdown, complete}, State};
handle_cast({task_exit, Task, GraphChange, Outcome, Remaining}, State) ->
  {noreply,
   handle_task_exited( Task, Outcome, Remaining,
                       handle_graph_changes(GraphChange, State)) };
handle_cast(_Request, State) ->
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.


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

handle_task_exited(Task,  {failed, _Reason, _Output}, Remaining, State=#state{build_spec=out_of_date}) ->
  task_completed(Task, Remaining, State);
handle_task_exited(_Task, {failed, Reason, _Output}, _, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_failed, Reason}),
  State;
handle_task_exited(_Task, {invalid, Message}, _, State=#state{workspace_dir=WS, build_id=Bid}) ->
  build_completed(WS, Bid, false, {task_invalid, Message}),
  State;
handle_task_exited(Task,  _, Remaining, State) ->
  task_completed(Task, Remaining, State).

task_completed(Task, Waiting, State = #state{build_spec=BSpec, complete_tasks=CompleteTasks}) ->
  start_tasks(Waiting, State#state{
                         build_spec=reduce_build_spec(Task, BSpec),
                         complete_tasks=[Task | CompleteTasks]
                        }).

-spec(start_tasks(integer(), #state{}) -> ok | {err, term()}).
start_tasks(0, State=#state{build_spec=[], workspace_dir=WorkspaceDir, build_id=BuildId}) ->
  build_completed(WorkspaceDir, BuildId, true, {}),
  State;
start_tasks(_, State=#state{build_spec=[]}) ->
  State;

start_tasks(0, State=#state{build_spec=out_of_date, workspace_dir=Workspace, requested_targets=Targets}) ->
  BuildSpec=ergo_graphs:build_list(Workspace, Targets),
  start_tasks(0, State#state{complete_tasks=[],build_spec=BuildSpec});
start_tasks(_, State=#state{build_spec=out_of_date}) ->
  State;

start_tasks(_, State) ->
  begin_task_generation(State).


begin_task_generation(State=#state{build_spec=[]}) ->
  State;
begin_task_generation(State=#state{workspace_dir=WS, build_id=Bid, build_spec=BuildSpec}) ->
  {Eligible, NewSpec} = ergo_runspec:eligible_batch(BuildSpec),
  ergo_events:task_generation(WS, Bid, Eligible),
  start_eligible_tasks(Eligible, State#state{build_spec=NewSpec}).

start_eligible_tasks(TL, State=#state{workspace_dir=WS, build_spec=RunSpec}) ->
  {Elided, Runnable} = lists:partition(fun(Task) -> elidible_task(WS, Task) end, TL),
  maybe_report_elided(Elided, State),
  start_unelided_tasks(Runnable, State#state{build_spec=reduce_elided(Elided, RunSpec)}).

start_unelided_tasks([], State) ->
  begin_task_generation(State);
start_unelided_tasks(TL, State) ->
  {MaxCount, NewState} = lists:foldl(fun update_runcount/2, {0, State}, TL),
  start_ready_tasks(MaxCount, TL, NewState).

start_ready_tasks(MaxCount, _, State=#state{workspace_dir=WS, build_id=Bid}) when MaxCount >= ?RUN_LIMIT ->
  build_completed(WS, Bid, false, {err, too_many_repetitions}), State;
start_ready_tasks(_, TL, State=#state{workspace_dir=WS, build_id=Bid, config=Cfg}) ->
  lists:foreach(fun(Task) -> start_task(WS, Bid, Task, Cfg) end, TL),
  State.

start_task(Workspace, BuildId, Task, Config) ->
  ergo_task_pool:start_task(Workspace, BuildId, Task, Config).

elidible_task(WS, Task) ->
  case ergo_freshness:check(WS, Task) of
    hit -> true;
    _ -> false
  end.

maybe_report_elided([], _) ->
  ok;
maybe_report_elided(Elided, #state{workspace_dir=WS, build_id=Bid}) ->
  ergo_events:tasks_elided(WS, Bid, Elided).

reduce_elided(Tasks, Spec) ->
  lists:foldl(fun reduce_build_spec/2, Spec, Tasks).

update_runcount(Task, {Max, State=#state{run_counts=RCs}}) ->
  Count = case dict:find(Task, RCs) of
            {ok, Val} -> Val;
            error -> 0
          end,
  maybe_report_repetitions(Count, Task, State),
  {maxof(Max, Count), State#state{run_counts=dict:store(Task, Count + 1, RCs)}}.

maybe_report_repetitions(Count, Task, #state{workspace_dir=WS, build_id=Bid}) when Count > ?RUN_LIMIT ->
  ergo_events:task_failed(WS, Bid, {task, Task}, {too_many_repetitions, Task, Count, ?RUN_LIMIT}, []);
maybe_report_repetitions(_, _, _) ->
  ok.

maxof(X, Y) when X > Y ->
  X;
maxof(_, Y) ->
  Y.

reduce_build_spec(_, out_of_date) ->
  out_of_date;
reduce_build_spec(Task, Spec) ->
  ergo_runspec:reduce(Task, Spec).

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
                 ?assertMatch( [{done_task, []}, {other_task, []}, {last_task, [other_task]}], Reduced )
               end)
       }
   end
  ]}.
-endif.
