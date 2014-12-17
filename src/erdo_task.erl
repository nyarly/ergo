-module(erdo_task).
-behavior(gen_server).
%% API
-export([current/0, start_link/2, task_name/1, add_dep/4, add_prod/4, add_co/4, add_seq/4, skip/2, not_elidable/2]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(VIA(Workspace, Taskname), {via, erdo_workspace_registry, {Workspace, task, Taskname}}).

-record(state, {name, runspec, cmdport, graphitems, elidable}).
start_link(RunSpec={Taskname, _Cmd, _Arg}, WorkspaceDir) ->
  gen_server:start_link(?VIA(WorkspaceDir, Taskname), ?MODULE, {RunSpec, WorkspaceDir}, []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

-spec(current() -> erdo:task_name() | no_task).
current() ->
  no_task.


-spec(add_dep(erdo:workspace_name(), erdo:task_name(), erdo:product_name(), erdo:product_name()) -> ok).
add_dep(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_dep, From, To}).

-spec(add_prod(erdo:workspace_name(), erdo:task_name(), erdo:task_name(), erdo:product_name()) -> ok).
add_prod(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_prod, From, To}).

-spec(add_co(erdo:workspace_name(), erdo:task_name(), erdo:task_name(), erdo:task_name()) -> ok).
add_co(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_co, From, To}).

-spec(add_seq(erdo:workspace_name(), erdo:task_name(), erdo:task_name(), erdo:task_name()) -> ok).
add_seq(Workspace, Taskname, From, To) ->
  gen_server:call(?VIA(Workspace, Taskname), {add_seq, From, To}).

-spec(not_elidable(erdo:workspace_name(), erdo:task_name()) -> ok).
not_elidable(Workspace, Taskname) ->
  gen_server:call(?VIA(Workspace, Taskname), {elidable}).

-spec(skip(erdo:workspace_name(), erdo:task_name()) -> ok).
skip(Workspace, Taskname) ->
  gen_server:call(?VIA(Workspace, Taskname), {skip}).


%%% gen_server callbacks

init({TaskSpec, WorkspaceDir}) ->
  {TaskName, Command, Args} = TaskSpec,
  case task_running(TaskName) of
    true -> {stop, {task_already_running, TaskName}};
    _ ->
      CmdPort = open_port(
        {spawn_executable, Command},
        [
          {args, Args},
          {env, task_env()},
          {cd, WorkspaceDir},
          exit_status,
          use_stdio,
          stderr_to_stdout
        ]
      ),
      erdo_events:task_started({task, TaskName}),
      {ok, #state{name=TaskName, runspec=TaskSpec, cmdport=CmdPort, graphitems=[], elidable=true}}
  end.

task_running(Name) ->
  lists:member(Name, erdo_task_soop:running_tasks()).

handle_call(task_name, _From, State) ->
  {reply, State#state.name, State};
handle_call({add_dep, From, To}, _From, State) ->
  {reply, ok, add_item(State, {dep, From, To})};
handle_call({add_prod, Task, Prod}, _From, State) ->
  {reply, ok, add_item(State, {prod, Task, Prod})};
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
handle_info({CmdPort, {exit_status, Status}}, State=#state{cmdport=CmdPort,name=Name,graphitems=GraphItems,elidable=Elides}) ->
  exit_status(Status,Name,GraphItems,Elides),
  {noreply, State};
handle_info({'EXIT', CmdPort, ExitReason}, State=#state{cmdport=CmdPort,name=Name}) ->
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

skipped(State=#state{name=Name, cmdport=CmdPort}) ->
  erdo_events:task_skipped({task, Name}),
  port_close(CmdPort),
  State#state{graphitems=[]}.

task_env() ->
  {}.

received_data(_Data,_Name) ->
  ok.
exited(_Reason,_Name) ->
  ok.

exit_status(0,Name,Graph,Elides) ->
  erdo_graphs:task_batch(Name, Graph),
  erdo_graphs:elidability(Name, Elides),
  erdo_events:task_completed({task, Name});
exit_status(_Status,Name,_Graph) ->
  erdo_events:task_failed({task, Name}).
