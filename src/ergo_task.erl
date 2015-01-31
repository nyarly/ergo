-module(ergo_task).
-behavior(gen_server).
%% API
-export([current/0, start_link/2, task_name/1, add_dep/4, add_prod/4, add_co/4, add_seq/4, skip/2, not_elidable/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(VIA(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, Taskname}}).
-define(ERGO_TASK_ENV, "ERGO_TASK_ID").

-record(state, {workspace, name, runspec, cmdport, graphitems, elidable}).
start_link(RunSpec={Taskname, _Cmd, _Arg}, WorkspaceDir) ->
  gen_server:start_link(?VIA(WorkspaceDir, Taskname), ?MODULE, {RunSpec, WorkspaceDir}, []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

-spec(current() -> ergo:taskname() | no_task).
current() -> registration_from_taskenv(os:getenv(?ERGO_TASK_ENV)).

registration_from_taskenv(false) -> no_task;
registration_from_taskenv(TaskId) ->
  taskname_from_registration(ergo_workspace_registry:name_from_id(TaskId)).

taskname_from_registration({_Workspace, task, TaskName}) -> TaskName;
taskname_from_registration(_) -> no_task.


-spec(add_dep(ergo:workspace_name(), ergo:taskname(), ergo:productname(), ergo:productname()) -> ok).
add_dep(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_dep, From, To}).

-spec(add_prod(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ok).
add_prod(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_prod, From, To}).

-spec(add_req(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ok).
add_req(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_req, From, To}).

-spec(add_co(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ok).
add_co(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_co, From, To}).

-spec(add_seq(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ok).
add_seq(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_seq, From, To}).

-spec(not_elidable(ergo:workspace_name(), ergo:taskname()) -> ok).
not_elidable(Workspace, Taskname) ->
  gen_server:call(?VIA(Workspace, Taskname), {elidable}).

-spec(skip(ergo:workspace_name(), ergo:taskname()) -> ok).
skip(Workspace, Taskname) ->
  gen_server:call(?VIA(Workspace, Taskname), {skip}).


%%% gen_server callbacks

init({TaskSpec, WorkspaceDir}) ->
  {TaskName, Command, Args} = TaskSpec,
  ergo_events:task_init(WorkspaceDir, {task, TaskName}),
  process_flag(trap_exit, true),
  CmdPort = launch_task(Command, Args, WorkspaceDir),
  process_launch_result(CmdPort, WorkspaceDir, TaskName, TaskSpec).

process_launch_result({'EXIT', Reason}, WorkspaceDir, TaskName, _TS) ->
  ergo_events:task_failed(WorkspaceDir, {task, TaskName}, Reason),
  {stop, Reason};
process_launch_result(CmdPort, WorkspaceDir, TaskName, TaskSpec) ->
  ct:pal("port opened for ~p:~p~n",[TaskName,CmdPort]),
  ergo_events:task_started(WorkspaceDir, {task, TaskName}),
  {ok, #state{workspace=WorkspaceDir, name=TaskName, runspec=TaskSpec, cmdport=CmdPort, graphitems=[], elidable=true}}.


launch_task(Command, Args, Dir) ->
  catch open_port(
          {spawn_executable, Command},
          [
           {args, Args},
           {env, task_env()},
           {cd, Dir},
           exit_status,
           use_stdio,
           stderr_to_stdout
          ]
         ).


task_running(Name) ->
  lists:member(Name, ergo_tasks_soop:running_tasks()).

handle_call(task_name, _From, State) ->
  {reply, State#state.name, State};
handle_call({add_dep, From, To}, _From, State) ->
  {reply, ok, add_item(State, {dep, From, To})};
handle_call({add_prod, Task, Prod}, _From, State) ->
  {reply, ok, add_item(State, {prod, Task, Prod})};
handle_call({add_req, Task, Prod}, _From, State) ->
  {reply, ok, add_item(State, {req, Task, Prod})};
handle_call({add_co, From, To}, _From, State) ->
  {reply, ok, add_item(State, {cotask, From, To})};
handle_call({add_seq, From, To}, _From, State) ->
  {reply, ok, add_item(State, {seq, From, To})};
handle_call({skip}, _From, State) ->
  NewState = skipped(State),
  {reply, ok, NewState};
handle_call({not_elidable}, _From, State) ->
  {reply, ok, make_not_elidable(State)};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort,name=Name}) ->
  received_data(Data,Name),
  {noreply, State};
handle_info({CmdPort, {exit_status, Status}}, State=#state{workspace=Workspace,cmdport=CmdPort,name=Name,graphitems=GraphItems,elidable=Elides}) ->
  exit_status(Workspace,Status,Name,GraphItems,Elides),
  {noreply, State};
handle_info({'EXIT', CmdPort, ExitReason}, State=#state{cmdport=CmdPort,name=Name}) ->
  ct:pal("~p~p~p~n", [Name, CmdPort, ExitReason]),
  exited(ExitReason,Name),
  {stop, task_completed, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% Internal functions

add_item(State=#state{graphitems=GraphItems}, Item) ->
  State#state{graphitems=[Item | GraphItems]}.

make_not_elidable(State) ->
  State#state{elidable=false}.

skipped(State=#state{workspace=Workspace,name=Name, cmdport=CmdPort}) ->
  ergo_events:task_skipped(Workspace, {task, Name}),
  port_close(CmdPort),
  State#state{graphitems=[]}.

task_env() ->
  [].

received_data(_Data,_Name) ->
  ok.
exited(_Reason,_Name) ->
  ok.

exit_status(Workspace,0,Name,Graph,Elides) ->
  ergo_graphs:task_batch(Workspace, Name, Graph),
  ergo_freshness:elidability(Workspace, Name, Elides),
  ergo_events:task_completed(Workspace,{task, Name});
exit_status(Workspace,Status,Name,_Graph,_Elides) ->
  ergo_events:task_failed(Workspace, {task, Name}, {exit_status, Status}).
