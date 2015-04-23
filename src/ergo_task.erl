-module(ergo_task).
-behavior(gen_server).
%% API
-export([current/0, taskname_from_token/1, start_link/4, task_name/1,
         add_dep/4, add_req/4, add_prod/4, add_co/4, add_seq/4, skip/2, invalid/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(VIA(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, Taskname}}).
-define(VT(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, taskname_from_token(Taskname)}}).

-define(ERGO_TASK_ENV, "ERGO_TASK_ID").

-record(state, {
          workspace,
          build_id,
          name,
          runspec,
          cmdport,
          output=[],
          graphitems=[],
          skipped=false,
          invalid=false
         }).

start_link(RunSpec={Taskname, _Cmd, _Arg}, WorkspaceDir, BuildId, Config) ->
  gen_server:start_link(?VIA(WorkspaceDir, Taskname), ?MODULE, {RunSpec, WorkspaceDir, BuildId, Config}, []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

-spec(current() -> ergo:taskname() | no_task).
current() -> taskname_from_token(os:getenv(?ERGO_TASK_ENV)).

taskname_from_token(false) -> no_task_id_in_env;
taskname_from_token(TaskString) when is_list(TaskString) ->
  taskname_from_token(iolist_to_binary(TaskString));
taskname_from_token(TaskId) ->
  taskname_from_registration(ergo_workspace_registry:name_from_id(TaskId)).

taskname_from_registration({_Workspace, task, TaskName}) -> TaskName;
taskname_from_registration(Err) -> {no_task, Err}.

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

-spec(skip(ergo:workspace_name(), ergo:taskname()) -> ok).
skip(Workspace, Taskname) ->
  gen_server:call(?VT(Workspace, Taskname), {skip}).

-spec(invalid(ergo:workspace_name(), ergo:taskname(), string()) -> ok).
invalid(Workspace, Taskname, Message) ->
  gen_server:call(?VT(Workspace, Taskname), {invalid, Message}).


%%% gen_server callbacks

init({TaskSpec, WorkspaceDir, BuildId, Config}) ->
  {TaskName, Command, Args} = TaskSpec,
  ergo_events:task_init(WorkspaceDir, BuildId, {task, TaskName}),
  process_flag(trap_exit, true),
  CmdPort = (catch launch_task(Command, TaskName, Args, WorkspaceDir, Config)),
  process_launch_result(CmdPort, WorkspaceDir, BuildId, TaskName, TaskSpec).

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
handle_call({invalid, Message}, _, State) ->
  {reply, ok, become_invalid(Message, State)};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(kill, State=#state{cmdport=CmdPort}) ->
  port_close(CmdPort),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort}) ->
  {noreply, received_data(State, Data)};
handle_info({_CmdPort, {exit_status, Status}}, State) ->
  exit_status(Status, State),
  {noreply, State};
handle_info({'EXIT', CmdPort, ExitReason}, State=#state{cmdport=CmdPort}) ->
  exited(ExitReason, State),
  {stop, normal, State};

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% Internal functions

process_launch_result({'EXIT', Reason}, WorkspaceDir, BuildId, TaskName, _TS) ->
  ergo_events:task_failed(WorkspaceDir, BuildId, {task, TaskName}, Reason, []),
  {stop, Reason};
process_launch_result(CmdPort, WorkspaceDir, BuildId, TaskName, TaskSpec) ->
  ergo_events:task_started(WorkspaceDir, BuildId, {task, TaskName}),
  {ok, #state{workspace=WorkspaceDir, build_id=BuildId, name=TaskName, runspec=TaskSpec, cmdport=CmdPort}}.


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
  open_port( {spawn_executable, Command}, PortConfig).

add_item(State=#state{graphitems=GraphItems}, Item) ->
  State#state{graphitems=[Item | GraphItems]}.

kill_self(#state{workspace=WS,name=T}) ->
  gen_server:cast(?VT(WS, T), kill).

skipped(State=#state{workspace=Workspace,build_id=BuildId, name=Name}) ->
  ergo_events:task_skipped(Workspace, BuildId, {task, Name}),
  kill_self(State),
  State#state{skipped=true}.

become_invalid(Message, State=#state{workspace=Workspace, build_id=BuildId, name=Name}) ->
  ergo_events:task_invalid(Workspace, BuildId, Name, Message),
  kill_self(State),
  State#state{invalid=true}.

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

received_data(State=#state{workspace=Workspace,build_id=BuildId, name=Name,output=Output}, Data) ->
  ergo_events:task_produced_output(Workspace, BuildId, {task, Name}, Data),
  State#state{output=[Data|Output]}.

exited(normal, State) ->
  record_batch(ok, State);
exited(Reason, State) ->
  record_batch({err, {exit_reason, Reason}}, State).

exit_status(0, State) ->
  record_batch(ok, State);
exit_status(Status, State) ->
  record_batch({err, {exit_status, Status}}, State).


record_batch(_, State=#state{invalid=true, workspace=Workspace, build_id=BuildId, name=Name}) ->
  ergo_graphs:task_invalid(Workspace, BuildId, Name),
  record_and_report({err, invalid}, State);
record_batch(_, State=#state{skipped=true}) ->
  record_and_report({ok, no_change}, State#state{graphitems=[]});
record_batch(ok, State=#state{workspace=Workspace, build_id=BuildId, name=Name, graphitems=Graph}) ->
  Changed = ergo_graphs:task_batch(Workspace, BuildId, Name, Graph, true),
  record_and_report(Changed, State);
record_batch(Error, State=#state{workspace=Workspace, build_id=BuildId, name=Name, graphitems=Graph}) ->
  case ergo_graphs:task_batch(Workspace, BuildId, Name, Graph, false) of
    {ok, changed} -> record_and_report({ok, changed}, State);
    _ -> record_and_report(Error, State)
  end.


record_and_report({err, Error}, #state{output=Output, build_id=BuildId, name=Name, workspace=Workspace}) ->
  ergo_events:task_failed(Workspace, BuildId, {task, Name}, Error, {output,lists:flatten(lists:reverse(Output))});
record_and_report({ok, changed}, #state{workspace=Workspace, build_id=BuildId, name=Name}) ->
  ergo_events:task_changed_graph(Workspace, BuildId, {task, Name});
record_and_report({ok, no_change }, #state{workspace=Workspace, build_id=BuildId, name=Name}) ->
  ergo_events:task_completed(Workspace, BuildId, {task, Name}).
