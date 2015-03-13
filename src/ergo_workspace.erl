-module(ergo_workspace).
-behavior(gen_server).

-include_lib("kernel/include/file.hrl").
%% API
-export([start_link/1, start_task/4, start_build/2, current/0, setup/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(ERGO_DIR, ".ergo").
-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, server, only}}).
-record(state, {workspace_dir, build_count, task_limit}).
start_link(WorkspaceDir) ->
  gen_server:start_link(?VIA(WorkspaceDir), ?MODULE, [WorkspaceDir], []).


%% @spec:	start_task(TaskName::string()) -> ok.
%% @end

-spec(start_task(ergo:workspace_name(), ergo:build_id(), ergo:taskspec(), term()) -> ok).
start_task(Workspace, BuildId, RunSpec, Config) ->
  gen_server:call(?VIA(Workspace), {start_task, BuildId, RunSpec, Config}).

-spec(start_build(ergo:workspace_name(), [ergo:target()]) -> ok).
start_build(Workspace, Targets) ->
  gen_server:call(?VIA(Workspace), {start_build, {Targets}}).

-spec(current() -> ergo:workspace_name() | no_workspace | {error, term()}).
current() ->
  case file:get_cwd() of
    {ok, Pwd} ->
      case find_dir(Pwd) of
        none -> no_workspace;
        Path -> Path
      end;
    Error -> Error
  end.

-spec(setup() -> ok | {error, term()}).
setup() ->
  case file:get_cwd() of
    {ok, Pwd} -> setup_ergo_in(Pwd);
    Error -> {error, {cant_get_pwd, Error}}
  end.


%% @spec:	start_build() -> ok.
%% @end

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

find_dir(Path="/") ->
  case ergo_dir(Path) of
    no -> none;
    _ -> Path
  end;
find_dir(Path) ->
  case ergo_dir(Path) of
    no -> find_dir(filename:dirname(Path));
    _ -> Path
  end.

ergo_dir(Path) ->
  case ErgoDir=file:read_file_info(filename:join(Path, ?ERGO_DIR)) of
    {ok, #file_info{type=directory}} ->
      ErgoDir;
    _ ->
      no
  end.

init([WorkspaceDir]) ->
  {ok, build_state(WorkspaceDir)}.

build_state(WorkspaceDir) ->
  #state{workspace_dir=WorkspaceDir,build_count=0,task_limit=5}.

handle_call({start_build, {Targets}}, _From, State=#state{workspace_dir=Workspace,build_count=BuildCount}) ->
  ergo_build:start(Workspace, BuildCount, Targets),
  {reply, BuildCount, State#state{build_count=BuildCount+1}};
handle_call({start_task, BuildId, RunSpec, Config}, _From, State=#state{task_limit=TaskLimit, workspace_dir=Workspace}) ->
  Reply = ergo_tasks_soop:start_task(TaskLimit, RunSpec, Workspace, BuildId, Config),
  {reply, Reply, State};
handle_call(_Request, _From, State) ->
  Reply = ok,
  {reply, Reply, State}.

handle_cast(_Msg, State) ->
  {noreply, State}.
handle_info(_Info, State) ->
  {noreply, State}.
terminate(_Reason, _State) ->
  ok.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
%%%===================================================================
%%% Internal functions
%%%===================================================================

setup_ergo_in(Pwd) ->
  ErgoDir = filename:join(Pwd, ?ERGO_DIR),
  ok = make_ergo_dir(ErgoDir),
  ok = ensure_project_id(ErgoDir),
  ok = ensure_env_config(ErgoDir),
  ok.

make_ergo_dir(ErgoDir) ->
  case file:make_dir(ErgoDir) of
    ok -> ok;
    {error, eexist} ->
      case file:read_file_info(ErgoDir) of
        {ok, #file_info{type=directory}} ->
          ok;
        _ ->
          {error, {path_not_a_dir, ErgoDir}}
      end
  end.

ensure_project_id(Dir) ->
  PridFile = filename:join(Dir, "project_id"),
  PridBytes = uuid:to_string(uuid:v4()),

  case file:write_file(PridFile, PridBytes, [write, exclusive]) of
    {error, eexist} -> ok;
    ok -> ok
  end.

ensure_env_config(Dir) ->
  ok.
