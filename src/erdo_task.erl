-module(erdo_task).
-behavior(gen_server).
%% API
-export([start_link/2, task_name/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
-define(SERVER, ?MODULE).
-record(state, {name, runspec, cmdport}).
start_link(Name, RunSpec) ->
  gen_server:start_link(?MODULE, [Name, RunSpec], []).

task_name(TaskServer) ->
  gen_server:call(TaskServer, task_name).

%%% gen_server callbacks

init([Name, RunSpec]) ->
  [Command | Args] = RunSpec,
  CmdPort = open_port(
    {spawn_executable, Command},
    [
      {args, Args},
      {env, task_env()},
      exit_status,
      use_stdio,
      stderr_to_stdout
    ]
  ),
  erdo_events:task_started({task, Name}),
  {ok, #state{name=Name, runspec=RunSpec, cmdport=CmdPort}}.

handle_call(task_name, _From, State) ->
  {reply, State#state.name, State};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort,name=Name}) ->
  received_data(Data,Name),
  {noreply, State};
handle_info({CmdPort, {exit_status, Status}}, State=#state{cmdport=CmdPort,name=Name}) ->
  exit_status(Status,Name),
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

exit_status(0,Name) ->
  erdo_events:task_completed({task, Name});
exit_status(_Status,Name) ->
  erdo_events:task_failed({task, Name}).
