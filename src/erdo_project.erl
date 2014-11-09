-module(erdo_project).
-behavior(gen_server).
%% API
-export([start_link/1, start_task/2, start_build/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
-define(SERVER, ?MODULE).
-record(state, {project_dir, task_limit}).
start_link(ProjectDir) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [ProjectDir], []).

%% @spec:	start_task(TaskName::string()) -> ok.
%% @end

-spec(start_task(string(), [string()]) -> ok).
start_task(TaskName, Args) ->
  gen_server:call({start_task, {TaskName, Args}}).

%% @spec:	start_build() -> ok.
%% @end

-spec(start_build([erdo:target()]) -> ok).
start_build(Targets) ->
  gen_server:call({start_build, {Targets}}).
%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([ProjectDir]) ->
  {ok, #state{project_dir=ProjectDir, task_limit=5}}.

handle_call({start_build, {Targets}}, _From, State) ->
  Reply = erdo_build:add_sup_to(events, Targets),
  {reply, Reply, State};
handle_call({start_task, {TaskName, Args}}, _From, State) ->
  Reply = erdo_task_soop:start_task(State#state.task_limit, TaskName, Args),
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
