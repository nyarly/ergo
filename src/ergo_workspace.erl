-module(ergo_workspace).
-behavior(gen_server).

-include_lib("kernel/include/file.hrl").
%% API
-export([start_link/1, start_task/2, start_build/2, current/0, setup/0]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).

-define(ERGO_DIR, ".ergo").
-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, server, only}}).
-record(state, {workspace_dir, task_limit}).
start_link(WorkspaceDir) ->
  gen_server:start_link(?VIA(WorkspaceDir), ?MODULE, [WorkspaceDir], []).


%% @spec:	start_task(TaskName::string()) -> ok.
%% @end

-spec(start_task(ergo:workspace_name(), ergo:taskspec()) -> ok).
start_task(Workspace, RunSpec) ->
  gen_server:call(?VIA(Workspace), {start_task, RunSpec}).

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
    {ok, Pwd} ->
      ErgoDir =filename:join(Pwd, ?ERGO_DIR),
      case file:make_dir(ErgoDir) of
        ok -> ok;
        {error, eexist} ->
          case file:read_file_info(ErgoDir) of
            {ok, #file_info{type=directory}} ->
              ok;
            _ ->
              {error, {path_not_a_dir, ErgoDir}}
          end
      end;
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
  {ok, #state{workspace_dir=WorkspaceDir, task_limit=5}}.


handle_call({start_build, {Targets}}, _From, State) ->
  Reply = ergo_build:add_sup_to(events, {State#state.workspace_dir, Targets}),
  {reply, Reply, State};
handle_call({start_task, RunSpec}, _From, State) ->
  Reply = ergo_task_soop:start_task(State#state.task_limit, RunSpec, State#state.workspace_dir),
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
