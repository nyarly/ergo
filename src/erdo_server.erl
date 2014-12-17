-module(erdo_server).
-behavior(gen_server).
%% API
-export([start_link/0]).
-export([get_workspace/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
  terminate/2, code_change/3]).
-define(SERVER, ?MODULE).
-record(state, {}).

start_link() ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec(get_workspace(erdo:workspace_name()) -> pid()).
get_workspace(Workspace) ->
  get_server:call(?SERVER, {get_workspace, Workspace}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
%%%
init([]) ->
  {ok, #state{}}.

handle_call({get_workspace, Name}, _From, State) ->
  {reply, handle_get_workspace(Name), State};
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

handle_get_workspace(Workspace) ->
  case erdo_sup:find_workspace(Workspace) of
    unknown -> erdo_sup:start_workspace(Workspace);
    Pid -> Pid
  end.
