-module (ergo_task_pool).

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behavior(gen_server).
%% API
-export([start_link/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3,
         register_build/2, start_task/4, scrub_build/1, task_concluded/2
        ]).
-define(SERVER, ?MODULE).

-define(VIA(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, Taskname}}).
%-define(VT(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, taskname_from_token(Taskname)}}).

-record(task, {
          workspace,
          build_id,
          task,
          config,
          graph_status,
          outcome,
          pid
         }).

-record(build, {
          pid,
          workspace,
          build_id
         }).

-record(state, {
          worker_limit = 8 :: integer(),
          waiting :: queue:queue(#task{}),
          running :: dict:dict(pid(), #task{}),
          builds :: dict:dict(reference(), #build{}),
          worker_monitors :: sets:set(reference()),
          build_monitors :: sets:set(reference())
         }).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

register_build(WS, Bid) ->
  gen_server:call(?SERVER, {register_build, WS, Bid}).

scrub_build(Bid) ->
  gen_server:call(?SERVER, {scrub_pending, Bid}).

start_task(WS, Bid, Task, Config) ->
  gen_server:call(?SERVER, {start_task, WS, Bid, Task, Config}).

-spec(task_concluded(ergo_graph:change_status(), ergo_task:outcome()) -> ok).
task_concluded(GraphChange, Outcome) ->
  gen_server:call(?SERVER, {task_concluded, GraphChange, Outcome}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
  {ok, #state{
          waiting=queue:new(),
          running=dict:new(),
          builds=dict:new(),
          worker_monitors=sets:new(),
          build_monitors=sets:new()
         }}.

handle_call({start_task, WS, Bid, Task, Config}, _From, State) ->
  {reply, ok, handle_start_task(new_task(WS, Bid, Task, Config), State)};
handle_call({register_build, WS, Bid}, {Pid, _}, State) ->
  NewState = register_build(WS, Bid, Pid, State),
  {reply, ok, NewState};
handle_call({scrub_pending, Bid}, _From, State) ->
  NewState = scrub_pending_for_build(Bid, State),
  {reply, ok, NewState};

handle_call({task_concluded, GraphChange, Outcome}, {Pid, _}, State) ->
  {reply, ok, record_task_conclusion(Pid, GraphChange, Outcome, State)};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({'DOWN', Ref, process, Who, Info} , State) ->
  {noreply, handle_down_monitor(Ref, Who, Info, State)};
handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%%%%%%%%%%%%%%%%%%%%
%  Traffic control  %
%%%%%%%%%%%%%%%%%%%%%

handle_start_task(Task, State) ->
  report_queued_task(Task),
  check_queue(queue_task(Task, State)).

check_queue(State) ->
  {RunList, NewState} = pop_runnable_jobs(State),
  lists:foldl(fun run/2, NewState, RunList).

run(Task, State) ->
  {Pid, Ref} = run_job(Task),
  report_running(Task),
  record_running(Pid, Ref, Task, State).

handle_down_monitor(Ref, Who, Info, State) ->
  monitored_process_exited(mon_type(Ref, State), Ref, Who, Info, State).

monitored_process_exited(worker, Ref, Who, Info, State) ->
  report_task_complete(Who, Info, State),
  check_queue(remove_worker(Who, Ref, State));
monitored_process_exited(build, Ref, Who, Info, State) ->
  report_build_exited(Who, Info, State),
  build_exited(Ref, State).

report_task_complete(Pid, _Info, State) ->
  Task = task_by_pid(Pid, State),
  notify_build(Task, State),
  report_task_conclusion(Task).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%  Functions with direct external calls  %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

report_queued_task(#task{workspace=WS, build_id=Bid, task=T}) ->
  ergo_events:task_init(WS, Bid, {task, T}).

report_running(#task{workspace=WS, build_id=Bid, task=T}) ->
  ergo_events:task_started(WS, Bid, {task, T}).

run_job(#task{workspace=WS, build_id=Bid, task=T, config=C}) ->
  {ok, Pid} = ergo_task:start(T, WS, Bid, C),
  {Pid, monitor(process, Pid)}.

register_build(WS, Bid, Proc, State) ->
  Ref = monitor(process, Proc),
  add_build_to_state(Ref, Proc, WS, Bid, State).

report_build_exited(Ref, Info, #state{builds=Bids}) ->
  #build{build_id=Bid,workspace=WS} = dict:fetch(Ref, Bids),
  ergo_events:build_exited(WS, Bid, Info).

notify_build(#task{workspace=WS, build_id=Bid, task=T, outcome=Outcome, graph_status=GraphChanged}, State) ->
  ergo_build:task_exited(WS, Bid, T, GraphChanged, Outcome, count_remaining(Bid, State)).

report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome=success, graph_status=changed}) ->
  ergo_events:task_changed_graph(WS, Bid, {task, T}),
  ergo_events:task_completed(WS, Bid, {task, T});
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome=success, graph_status=no_change}) ->
  ergo_events:task_completed(WS, Bid, {task, T});
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome={fail, Reason, Output}, graph_status=changed}) ->
  ergo_events:task_changed_graph(WS, Bid, {task, T}),
  ergo_events:task_failed(WS, Bid, {task, T}, Reason, Output);
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome={fail, Reason, Output}, graph_status=no_change}) ->
  ergo_events:task_failed(WS, Bid, {task, T}, Reason, Output);
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome=skipped}) ->
  ergo_events:task_skipped(WS, Bid, {task, T});
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T, outcome={invalid, Message}}) ->
  ergo_events:task_invalid(WS, Bid, T, Message);
report_task_conclusion(#task{workspace=WS, build_id=Bid, task=T}) ->
  ergo_events:task_failed(WS, Bid, {task, T}, {err, hard_crash}, []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%  Purely internal functions  %
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

new_task(WS, Bid, Task, Config) ->
  #task{workspace=WS, build_id=Bid, task=Task, config=Config}.

queue_task(Task, State=#state{waiting=W}) ->
  State#state{waiting = queue:in(Task, W)}.

task_by_pid(Pid, #state{running=Run}) ->
  dict:fetch(Pid, Run).

record_task_conclusion(Pid, GraphChange, Outcome, State=#state{running=Running}) ->
  Task = conclude_task(dict:fetch(Pid, Running), GraphChange, Outcome),
  State#state{running= dict:store(Pid, Task, Running)}.

conclude_task(Task, GraphChange, Outcome) ->
  Task#task{graph_status=GraphChange, outcome=Outcome}.

pop_runnable_jobs(State=#state{worker_limit=Limit, worker_monitors=Mons, waiting=Queue}) ->
  Num = min(queue:len(Queue), Limit - sets:size(Mons)),
  {Runnable, Waiting} = queue:split(Num, Queue),
  {queue:to_list(Runnable), State#state{waiting=Waiting}}.

mon_type(Ref, #state{build_monitors=Bs,worker_monitors=Ws}) ->
  case sets:is_element(Ref, Bs) of
    true -> build;
    false ->
      case sets:is_element(Ref, Ws) of
        true -> worker;
        false -> unknown_monitor
      end
  end.

count_remaining(Bid, State) ->
  count_waiting(Bid, State) + count_running(Bid, State).

count_waiting(Bid, #state{waiting=Q}) ->
  count_waiting(Bid, queue:peek(Q), catch queue:drop(Q), 0).

count_waiting(_, empty, _, Count) ->
  Count;
count_waiting(Bid, {value, #task{build_id=Bid}}, Q, Count) ->
  count_waiting(Bid, queue:peek(Q), catch queue:drop(Q), Count + 1);
count_waiting(Bid, _, Q, Count) ->
  count_waiting(Bid, queue:peek(Q), catch queue:drop(Q), Count).

count_running(Bid, #state{running=Rs}) ->
  dict:fold(fun(_, #task{build_id=TB}, Count) when TB =:= Bid -> Count + 1;
               (_, _, Count) -> Count
            end, 0, Rs).

record_running(Pid, Ref, Task, State=#state{worker_monitors=Ws, running=Run}) ->
  State#state{worker_monitors=sets:add_element(Ref,Ws), running=dict:store(Pid, Task#task{pid=Pid}, Run)}.

remove_worker(Pid, Ref, State=#state{worker_monitors=Ws, running=Run}) ->
  State#state{worker_monitors=sets:del_element(Ref, Ws), running=dict:erase(Pid, Run)}.

add_build_to_state(Ref, Proc, WS, Bid, State=#state{builds=Ids, build_monitors=Mons}) ->
  State#state{build_monitors=sets:add_element(Ref, Mons), builds=dict:store(Ref, #build{pid=Proc, workspace=WS, build_id=Bid}, Ids)}.

build_exited(Ref, State=#state{build_monitors=Bs}) ->
  scrub_dead_build(Ref, State#state{build_monitors=sets:del_element(Ref, Bs)}).

scrub_dead_build(Ref, State=#state{builds=Ids}) ->
  #build{build_id=DeadId} = dict:fetch(Ref, Ids),
  scrub_pending_for_build(DeadId, State).

scrub_pending_for_build(Bid, State=#state{waiting=Q}) ->
  State#state{waiting=scrub_build(Bid, Q)}.

scrub_build(Bid, Q) ->
  queue:filter(fun(#task{build_id=Id}) when Id =:= Bid -> false;
                  (_) -> true
               end, Q).



-ifdef(TEST).
module_test_() ->
  WS = "/some/directory/somewhere",
  Bid = 1,
  Taskname = [<<"build">>, <<"in.c">>],
  Config = {},
  ATask = new_task(WS, Bid, Taskname, Config),
  {
   foreach,
   fun() ->  %setup
       dbg:tracer(),
       dbg:p(all, c),
       {ok, State} = init([]),
       State
   end,
   fun(_State) -> %teardown
       dbg:ctp(), dbg:p(all, clear),
       ok
   end,
   [
    fun(State) ->
        {"Run new jobs when idle",
         ?_test(begin
                  {RunList, NewState} = pop_runnable_jobs(queue_task(ATask, State)),
                  ?assertMatch([ATask], RunList),
                  {EmptyList, _} = pop_runnable_jobs(NewState),
                  ?assertMatch([], EmptyList)
                end)
        }
    end,
    fun(State) ->
        {"Record task conclusion",
         ?_test(begin
                  TRef = make_ref(),
                  {RunList, NewState} = pop_runnable_jobs(queue_task(ATask, State)),
                  RunState = record_running(fake_pid, TRef, ATask, NewState),
                  ConcludeState = record_task_conclusion(fake_pid, changed, success, RunState),
                  DoneTask = task_by_pid(fake_pid, ConcludeState),
                  ?assertMatch(#task{outcome=success, graph_status=changed}, DoneTask),
                  ?assertEqual(1, count_remaining(Bid, ConcludeState)),
                  EndState = remove_worker(fake_pid, TRef, ConcludeState),
                  ?assertEqual(0, count_remaining(Bid, EndState))
                end)
        }
    end,
    fun(State) ->
        {"Queue new jobs when busy",
         ?_test(begin
                  BusyState = lists:foldl(fun(FakePid, NewState) ->
                                                 record_running(FakePid, make_ref(),
                                                                new_task(WS, Bid, [<<"pretend_to_be">>, FakePid], Config), NewState)
                                             end, State, lists:seq(1, State#state.worker_limit)),
                  QueuedState = queue_task(ATask, BusyState),
                  ?assertMatch({[], QueuedState}, pop_runnable_jobs(QueuedState)),
                  ?assertEqual(8, count_running(Bid, QueuedState)),
                  ?assertEqual(1, count_waiting(Bid, QueuedState)),
                  ?assertEqual(0, count_remaining(17, QueuedState)),
                  ?assertEqual(9, count_remaining(Bid, QueuedState))
                end)
        }
    end,
    fun(State) ->
        {"Should scrub the jobs of dead builds",
         ?_test(begin
                  BRef = make_ref(),
                  StateWithBuild = add_build_to_state(BRef, bogus_pid, WS, Bid, State),
                  QueuedState = queue_task(ATask, StateWithBuild),
                  NewState = build_exited(BRef, QueuedState),
                  {EmptyList, _} = pop_runnable_jobs(NewState),
                  ?assertMatch([], EmptyList)
                end)
        }
    end
   ]}.
-endif.
