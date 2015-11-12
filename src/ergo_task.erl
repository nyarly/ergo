-module(ergo_task).

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behavior(gen_server).
%% API
-export([current/0, taskname_from_token/1, start/4, start_link/4, task_name/1,
         add_dep/4, add_req/4, add_prod/4, add_co/4, add_seq/4, skip/2, invalid/3]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(VIA(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, Taskname}}).
-define(VT(Workspace, Taskname), {via, ergo_workspace_registry, {Workspace, task, taskname_from_token(Taskname)}}).

-define(ERGO_TASK_ENV, "ERGO_TASK_ID").

-type outcome() :: success | skipped | {invalid, term()} | {failed, term(), string()}.

-record(state, {
          workspace,
          build_workspace,
          build_id,
          name,
          build_name,
          config,
          cmdport,
          output=[],
          graphitems=[],
          skipped=false,
          invalid=false
         }).

start_link(Taskname, WorkspaceDir, BuildId, Config) ->
  gen_server:start_link(?VIA(WorkspaceDir, Taskname), ?MODULE, {Taskname, WorkspaceDir, BuildId, Config}, []).

start(Taskname, WorkspaceDir, BuildId, Config) ->
  gen_server:start(?VIA(WorkspaceDir, Taskname), ?MODULE, {Taskname, WorkspaceDir, BuildId, Config}, []).

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

begin_task(Workspace, Taskname) ->
  gen_server:cast(?VIA(Workspace, Taskname), begin_task).

%%% gen_server callbacks

init({BaseTaskName, BuildWorkspaceDir, BuildId, Config}) ->
  {WorkspaceDir, TaskName} = reparent_task(BaseTaskName, BuildWorkspaceDir),
  begin_task(BuildWorkspaceDir, BaseTaskName),
  {ok, #state{build_workspace=BuildWorkspaceDir, workspace=WorkspaceDir, build_id=BuildId, build_name=BaseTaskName, name=TaskName, config=Config}}.


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



handle_cast(begin_task, State) ->
  process_launch_result(handle_begin_task(State));
handle_cast(kill, State=#state{cmdport=CmdPort}) ->
  port_close(CmdPort),
  {noreply, State};
handle_cast(_Msg, State) ->
  {noreply, State}.



handle_info({CmdPort, {data, Data}}, State=#state{cmdport=CmdPort}) ->
  {noreply, received_data(State, Data)};
handle_info({_CmdPort, {exit_status, Status}}, State) ->
  exit_status(Status, State),
  {stop, normal, State};
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

-spec(task_executable([file:name_all()], binary()) -> file:name_all()).
task_executable(TaskPath, Taskname) ->
  handle_task_executable(file:path_open([TaskPath], Taskname, [read])).

handle_task_executable({ok, Io, FullPath})->
  ok = file:close(Io),
  FullPath;
handle_task_executable(Error) ->
  {error, Error}.


-record(launch, {
          fullexe,
          relname,
          args,
          fresh
         }).

handle_begin_task(State) ->
  handle_begin_task(#launch{}, State).

handle_begin_task(#launch{fullexe={error, Error}}, State) ->
  report_invalid(Error, State),
  {no_such_task, Error};
handle_begin_task(#launch{fresh=hit}, _State) ->
  ergo_task_pool:task_concluded(no_change, skipped),
  skipped;

handle_begin_task(Launch=#launch{fresh=undefined}, State=#state{build_workspace=WS, build_name=Task}) ->
  handle_begin_task(
    Launch#launch{ fresh=ergo_freshness:check(WS, Task) }, State
   );
handle_begin_task(Launch=#launch{relname=undefined}, State=#state{name=[RelName | Args]}) ->
  handle_begin_task(
    Launch#launch{ relname=RelName,args=Args }, State
   );
handle_begin_task(Launch=#launch{fullexe=undefined,relname=RelName}, State=#state{workspace=WS}) ->
  handle_begin_task(
    Launch#launch{ fullexe=task_executable(WS, RelName)}, State
   );

handle_begin_task(#launch{fullexe=Command, args=Args, fresh=miss},
                  State=#state{build_workspace=BWS, workspace=Dir, build_name=BuildName, name=TaskName, config=Config, cmdport=undefined}) ->
  PortConfig= [
           {arg0, hd(TaskName)},
           {args, Args},
           {env, task_env(BWS, BuildName, Config)},
           {cd, Dir},
           exit_status,
           use_stdio,
           stderr_to_stdout
          ],
  State#state{cmdport=(catch open_port( {spawn_executable, Command}, PortConfig))}.

-spec(process_launch_result(#state{} | skipped | {no_such_task, term()}) -> {stop, atom | term(), #state{}} | {noreply, #state{}}).
process_launch_result(State=#state{cmdport={'EXIT', Reason}}) ->
  ergo_task_pool:task_concluded(no_change, {failed, Reason, []}),
  {stop, Reason, State};
process_launch_result(State=#state{build_workspace=WS, build_id=Bid, build_name=Name}) ->
  ergo_events:task_running(WS, Bid, Name),
  {noreply, State};
process_launch_result(skipped) ->
  {stop, normal, #state{}};
process_launch_result(Reason) ->
  {stop, Reason, #state{}}.



add_item(State=#state{graphitems=GraphItems}, Item) ->
  State#state{graphitems=[Item | GraphItems]}.

kill_self(#state{build_workspace=WS,name=T}) ->
  gen_server:cast(?VT(WS, T), kill).

skipped(State) ->
  ergo_task_pool:task_concluded(no_change, skipped),
  kill_self(State),
  State#state{skipped=true}.

report_invalid(Message, State=#state{build_workspace=WS, build_id=B, name=Task}) ->
  ergo_task_pool:task_concluded(no_change, {invalid, Message}),
  ergo_graphs:task_invalid(WS, B, Task),
  State.


become_invalid(Message, State) ->
  _ = report_invalid(Message, State),
  kill_self(State),
  State#state{invalid=true}.

-spec(task_env(ergo:workspace_name(), ergo:taskname(), [{atom(), term()}]) -> [{string(), string()}]).
task_env(BuildWS, TaskName, Config) ->
  [
   {"ERL_CALL", filename:join(code:lib_dir(erl_interface, bin),"erl_call")},
   {"ERGO_NODE", atom_to_list(node())},
   {"ERGO_WORKSPACE", BuildWS},
   {"PATH", task_path(Config)},
   {?ERGO_TASK_ENV, binary_to_list(ergo_workspace_registry:id_from_name({BuildWS, task, TaskName}))}
  ].

task_path(Config) ->
  string:join(
    [filename:join([code:priv_dir(ergo),"scripts"])|
     proplists:get_value(path,Config,[])],
    ":").

received_data(State=#state{build_workspace=Workspace,build_id=BuildId, build_name=Name,output=Output}, Data) ->
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

report_concluded({err, RecordError}, _TaskResult) ->
  ergo_task_pool:task_concluded(no_change, {failed, {record_error, RecordError}, []});
report_concluded({ok, Changed}, TaskResult) ->
  ergo_task_pool:task_concluded(Changed, TaskResult).

reparent_task([BaseTaskScript|TaskArgs], BuildWorkspaceDir) ->
  % TODO this a larger issue, but need to make sure we're handling unicode properly
  AbsTaskName = filename:join(BuildWorkspaceDir, BaseTaskScript),
  WorkspaceDir = ergo_workspace:find_dir(filename:dirname(AbsTaskName)),
  RelTaskScript = relative_path(WorkspaceDir, AbsTaskName),
  TaskName = [RelTaskScript|TaskArgs],
  {binary:bin_to_list(WorkspaceDir), TaskName}.

reparent_items(WS, WS, Taskname, Items) ->
  [ unself_item(Taskname, Item) || Item <- Items];
reparent_items(BuildWS, TaskWS, Taskname, Items) ->
  RelDir = relative_path(BuildWS, TaskWS),
  [ unself_item(Taskname, reparent_item(RelDir, Item)) || Item <- Items ].

reparent_item(Dir, {dep, First, Second})  -> {dep,  reparent_filename(Dir, First), reparent_filename(Dir, Second)};
reparent_item(Dir, {prod, First, Second}) -> {prod, reparent_taskname(Dir, First), reparent_filename(Dir, Second)};
reparent_item(Dir, {req, First, Second})  -> {req,  reparent_taskname(Dir, First), reparent_filename(Dir, Second)};
reparent_item(Dir, {co, First, Second})   -> {co,   reparent_taskname(Dir, First), reparent_taskname(Dir, Second)};
reparent_item(Dir, {seq, First, Second})  -> {seq,  reparent_taskname(Dir, First), reparent_taskname(Dir, Second)}.

unself_item(Taskname, {prod, self, Second}) -> {prod, Taskname, Second};
unself_item(Taskname, {req, self, Second} ) -> {req, Taskname, Second} ;
unself_item(Taskname, {co, self, Second}  ) -> unself_item(Taskname,{co, Taskname, Second})  ;
unself_item(Taskname, {co, First, self}  )  -> {co, First, Taskname}  ;
unself_item(Taskname, {seq, self, Second} ) -> unself_item(Taskname,{seq, Taskname, Second}) ;
unself_item(Taskname, {seq, First, self} )  -> {seq, First, Taskname} ;
unself_item(_, Item)                        -> Item.

reparent_filename(Dir, Name) ->
  filename:join(Dir, Name).

reparent_taskname(_Dir, self) ->
  self;
reparent_taskname(Dir, [Script | Args]) ->
  [filename:join(Dir, Script) | Args].

relative_path(Dir, Dir) ->
  <<"">>;
relative_path(From, To) ->
  {ok, Path} = relpath(filename:split(From), filename:split(To)),
  Path.

relpath([], To) ->
  {ok, filename:join(To)};
relpath(From, []) ->
  {err, {not_under, From, []}};
relpath([Part | FromR], [Part | ToR]) ->
  relpath(FromR, ToR);
relpath(From, To) ->
  {err, {not_under, From, To}}.


-spec(record_batch(ok | term(), #state{}) -> outcome()).
record_batch(_, #state{invalid=true}) ->
  ok;
record_batch(_, #state{skipped=true}) ->
  ergo_task_pool:task_concluded(no_change, skipped);
record_batch(ok, #state{build_workspace=BWS, workspace=WS, build_id=Bid, build_name=BName, graphitems=Graph}) ->
  ergo_freshness:store(BWS, BName),
  report_concluded(
    ergo_graphs:task_batch(BWS, Bid, BName, reparent_items(BWS, WS, BName, Graph), true),
    success
   );
record_batch(Error, #state{build_workspace=BWS, workspace=Workspace, build_id=BuildId, build_name=BName, graphitems=Graph, output=Output}) ->
  report_concluded(
    ergo_graphs:task_batch(BWS, BuildId, BName, reparent_items(BWS, Workspace, BName, Graph), false),
    {failed, Error, lists:flatten(lists:reverse(Output))}
   ).

-ifdef(TEST).
task_test_() ->
  BuildWS = "/from/the/root",
  ChildWS = "/from/the/root/a/child",
  TaskA = [<<"tasks/a">>,<<"one">>],
  TaskB = [<<"tasks/b">>,<<"two">>],
  FileA = "a.txt",
  FileB = "b.txt",
  Items = [
           {dep, FileA, FileB},
           {prod, TaskA, FileA},
           {req, TaskA, FileA},
           {co, TaskA, TaskB},
           {seq, TaskA, TaskB}
          ],
  {
   foreach,
   fun() -> %setup
       dbg:tracer(),
       dbg:p(all,c),
       {}
   end,
   fun(_) -> %teardown
       dbg:ctp(),
       dbg:p(all, clear)
   end,
   [
    fun(_) ->
        {
         "No change if task and build are in same workspace",
         ?_test(begin
                  Reparented = reparent_items(BuildWS, BuildWS, TaskA, Items),
                  lists:foreach(fun({{_, NewA, NewB}, {_, OldA, OldB}}) ->
                                    NewA = OldA, NewB = OldB
                                end, lists:zip(Reparented, Items))
                end)
        }
    end,
    fun(_) ->
        {
         "Rewrite paths if the task is under the build workspace",
         ?_test(begin
                  Reparented = reparent_items(BuildWS, ChildWS, TaskA, Items),
                  FixedFileA = "a/child/a.txt",
                  FixedFileB = "a/child/b.txt",
                  FixedTaskA = [<<"a/child/tasks/a">>,<<"one">>],
                  FixedTaskB = [<<"a/child/tasks/b">>,<<"two">>],
                  FixedItems = [
                                {dep, FixedFileA, FixedFileB},
                                {prod, TaskA, FixedFileA},
                                {req, TaskA, FixedFileA},
                                {co, TaskA, FixedTaskB},
                                {seq, TaskA, FixedTaskB}
                               ],
                  lists:foreach(fun({{_, NewA, NewB}, {_, OldA, OldB}}) ->
                                    ?assertEqual(NewA,OldA), ?assertEqual(NewB, OldB)
                                end, lists:zip(FixedItems, Reparented))
                end)
        }
    end
   ]
  }.
-endif.
