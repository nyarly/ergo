-module(erdo_task).
-behavior(gen_server).
%% API
-export([start_link/2, task_name/1, add_dep/3, add_prod/3, add_co/3, add_seq/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {name, runspec, cmdport, graphitems}).
start_link(RunSpec={Taskname, _Cmd, _Arg}, WorkspaceDir) ->
  gen_server:start_link(task_atom(Taskname), ?MODULE, {RunSpec, WorkspaceDir}, []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

task_atom(Taskname) ->
  task_atom(<<>>, Taskname).

task_atom(Binary, []) ->
  erlang:binary_to_atom(Binary);
task_atom(Binary, [Head|Tail]) ->
  task_atom(<<Binary/bitstring," \"",Head/bitstring,"\"">>, Tail).


-spec(add_dep(erdo:task_name(), erdo:product_name(), erdo:product_name()) -> ok).
add_dep(Taskname, From, To) ->
  gen_server:call(task_atom(Taskname), {add_dep, From, To}).

-spec(add_prod(erdo:task_name(), erdo:task_name(), erdo:product_name()) -> ok).
add_prod(Taskname, From, To) ->
  gen_server:call(task_atom(Taskname), {add_prod, From, To}).

-spec(add_co(erdo:task_name(), erdo:task_name(), erdo:task_name()) -> ok).
add_co(Taskname, From, To) ->
  gen_server:call(task_atom(Taskname), {add_co, From, To}).

-spec(add_seq(erdo:task_name(), erdo:task_name(), erdo:task_name()) -> ok).
add_seq(Taskname, From, To) ->
  gen_server:call(task_atom(Taskname), {add_seq, From, To}).


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
      {ok, #state{name=TaskName, runspec=TaskSpec, cmdport=CmdPort, graphitems=[]}}
  end.

task_running(Name) ->
  lists:member(Name, erdo_task_soop:running_tasks()).

handle_call(task_name, _From, State) ->
  {reply, State#state.name, State};
handle_call({add_dep, From, To}, _From, State) ->
  {reply, ok, State#state{graphitems=[{dep, From, To}|State#state.graphitems]}};
handle_call({add_prod, Task, Prod}, _From, State) ->
  {reply, ok, State#state{graphitems=[{prod, Task, Prod}|State#state.graphitems]}};
handle_call({add_co, From, To}, _From, State) ->
  {reply, ok, State#state{graphitems=[{cotask, From, To}|State#state.graphitems]}};
handle_call({add_seq, From, To}, _From, State) ->
  {reply, ok, State#state{graphitems=[{seq, From, To}|State#state.graphitems]}};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort,name=Name}) ->
  received_data(Data,Name),
  {noreply, State};
handle_info({CmdPort, {exit_status, Status}}, State=#state{cmdport=CmdPort,name=Name,graphitems=GraphItems}) ->
  exit_status(Status,Name,GraphItems),
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

task_env() ->
  {}.

received_data(_Data,_Name) ->
  ok.
exited(_Reason,_Name) ->
  ok.

exit_status(0,Name,Graph) ->
  erdo_graphs:task_batch(Name, Graph),
  erdo_events:task_completed({task, Name});
exit_status(_Status,Name,_Graph) ->
  erdo_events:task_failed({task, Name}).
