-module(ergo_task).
-behavior(gen_server).
%% API
-export([current/0, taskname_from_token/1, start_link/3, task_name/1,
         add_dep/4, add_req/4, add_prod/4, add_co/4, add_seq/4, skip/2, not_elidable/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(VIA(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, Taskname}}).
-define(VT(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, taskname_from_token(Taskname)}}).

-define(ERGO_TASK_ENV, "ERGO_TASK_ID").

-record(state, {workspace, name, runspec, cmdport, output, graphitems, elidable}).
start_link(RunSpec={Taskname, _Cmd, _Arg}, WorkspaceDir, Config) ->
  gen_server:start_link(?VIA(WorkspaceDir, Taskname), ?MODULE, {RunSpec, WorkspaceDir, Config}, []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

-spec(current() -> ergo:taskname() | no_task).
current() -> taskname_from_token(os:getenv(?ERGO_TASK_ENV)).

taskname_from_token(false) -> no_task;
taskname_from_token(TaskString) when is_list(TaskString) ->
  taskname_from_token(iolist_to_binary(TaskString));
taskname_from_token(TaskId) ->
  taskname_from_registration(ergo_workspace_registry:name_from_id(TaskId)).

taskname_from_registration({_Workspace, task, TaskName}) -> TaskName;
taskname_from_registration(_) -> no_task.

-spec(add_dep(ergo:workspace_name(), ergo:taskname(), ergo:productname(), ergo:productname()) -> ok).
add_dep(Workspace, Taskname, From, To) ->
  gen_server:call(?VT(Workspace, Taskname), {add_dep, From, To}).

-spec(add_prod(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ok).
add_prod(Workspace, Taskname, From, To) ->
  gen_server:call(?VT(Workspace, Taskname), {add_prod, From, To}).

-spec(add_req(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ok).
add_req(Workspace, Taskname, From, To) ->
  gen_server:call(?VT(Workspace, Taskname), {add_req, From, To}).

-spec(add_co(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ok).
add_co(Workspace, Taskname, From, To) ->
  gen_server:call(?VT(Workspace, Taskname), {add_co, From, To}).

-spec(add_seq(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ok).
add_seq(Workspace, Taskname, From, To) ->
  gen_server:call(?VT(Workspace, Taskname), {add_seq, From, To}).

-spec(not_elidable(ergo:workspace_name(), ergo:taskname()) -> ok).
not_elidable(Workspace, Taskname) ->
  gen_server:call(?VT(Workspace, Taskname), {elidable}).

-spec(skip(ergo:workspace_name(), ergo:taskname()) -> ok).
skip(Workspace, Taskname) ->
  gen_server:call(?VT(Workspace, Taskname), {skip}).


%%% gen_server callbacks

init({TaskSpec, WorkspaceDir, Config}) ->
  {TaskName, Command, Args} = TaskSpec,
  ergo_events:task_init(WorkspaceDir, {task, TaskName}),
  process_flag(trap_exit, true),
  CmdPort = launch_task(Command, TaskName, Args, WorkspaceDir, Config),
  process_launch_result(CmdPort, WorkspaceDir, TaskName, TaskSpec).

handle_call(task_name, _From, State) ->
  {reply, State#state.name, State};
handle_call({add_dep, From, To}, _From, State) ->
  {reply, ok, add_item(State, {dep, From, To})};
handle_call({add_prod, Task, Prod}, _From, State) ->
  {reply, ok, add_item(State, {prod, Task, Prod})};
handle_call({add_req, Task, Prod}, _From, State) ->
  {reply, ok, add_item(State, {req, Task, Prod})};
handle_call({add_co, From, To}, _From, State) ->
  {reply, ok, add_item(State, {co, From, To})};
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

handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort}) ->
  {noreply, received_data(State, Data)};
handle_info({CmdPort, {exit_status, Status}}, State=#state{workspace=Workspace,cmdport=CmdPort,name=Name,output=Output,graphitems=GraphItems,elidable=Elides}) ->
  exit_status(Workspace,Status,Name,Output,GraphItems,Elides),
  {noreply, State};
handle_info({'EXIT', CmdPort, ExitReason}, State=#state{cmdport=CmdPort,name=Name}) ->
  exited(ExitReason,Name),
  {stop, normal, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% Internal functions

process_launch_result({'EXIT', Reason}, WorkspaceDir, TaskName, _TS) ->
  ergo_events:task_failed(WorkspaceDir, {task, TaskName}, Reason, []),
  {stop, Reason};
process_launch_result(CmdPort, WorkspaceDir, TaskName, TaskSpec) ->
  ergo_events:task_started(WorkspaceDir, {task, TaskName}),
  {ok, #state{workspace=WorkspaceDir, name=TaskName, runspec=TaskSpec, cmdport=CmdPort, output=[], graphitems=[], elidable=true}}.


launch_task(Command, TaskName, Args, Dir, Config) ->
  PortConfig= [
           {arg0, hd(TaskName)},
           {args, Args},
           {env, task_env(Dir, TaskName, Config)},
           {cd, Dir},
           exit_status,
           use_stdio,
           stderr_to_stdout
          ],
  catch open_port( {spawn_executable, Command}, PortConfig).


task_running(Name) ->
  lists:member(Name, ergo_tasks_soop:running_tasks()).

add_item(State=#state{graphitems=GraphItems}, Item) ->
  State#state{graphitems=[Item | GraphItems]}.

make_not_elidable(State) ->
  State#state{elidable=false}.

skipped(State=#state{workspace=Workspace,name=Name, cmdport=CmdPort}) ->
  ergo_events:task_skipped(Workspace, {task, Name}),
  port_close(CmdPort),
  State#state{graphitems=[]}.

task_env(Workspace, TaskName, Config) ->
  [
   {"ERL_CALL", filename:join(code:lib_dir(erl_interface, bin),"erl_call")},
   {"ERGO_NODE", atom_to_list(node())},
   {"ERGO_WORKSPACE", Workspace},
   {"PATH", task_path(Config)},
   {?ERGO_TASK_ENV, binary_to_list(ergo_workspace_registry:id_from_name({Workspace, task, TaskName}))}
  ].

task_path(Config) ->
  string:join(
    [filename:join([code:priv_dir(ergo),"scripts"])|
     proplists:get_value(path,Config,[])],
    ":").

received_data(State=#state{workspace=Workspace,name=Name,output=Output}, Data) ->
  ergo_events:task_produced_output(Workspace,{task, Name}, Data),
  State#state{output=[Data|Output]}.
exited(_Reason,_Name) ->
  ok.

exit_status(Workspace,Status,Name, OutputList, Graph, Elides) ->
  {ok, Changed} = ergo_graphs:task_batch(Workspace, Name, Graph, false),
  record_and_report(Status, Changed, Workspace, Name, Elides, OutputList).

record_and_report(0, changed, Workspace, Name, Elides, _OutputList) ->
  ergo_freshness:elidability(Workspace, Name, Elides),
  ergo_events:task_changed_graph(Workspace,{task, Name});
record_and_report(0, no_change, Workspace, Name, Elides, _OutputList) ->
  ergo_freshness:elidability(Workspace, Name, Elides),
  ergo_events:task_completed(Workspace,{task, Name});
record_and_report(_Status, changed, Workspace, Name, _Elides, _OutputList) ->
  ergo_events:task_changed_graph(Workspace,{task, Name});
record_and_report(Status, no_change, Workspace, Name, _Elides, OutputList) ->
  ergo_events:task_failed(Workspace, {task, Name}, {exit_status, Status}, {output,lists:flatten(lists:reverse(OutputList))}).
