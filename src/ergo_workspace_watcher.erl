-module(ergo_workspace_watcher).
-behavior(gen_event).

%% API
-export([add_to_sup/1, add_to_sup/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {}).

%%%===================================================================
%%% Module API
%%%===================================================================
add_to_sup(Workspace) ->
  add_to_sup(Workspace, []).

add_to_sup(Workspace, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler({via, ergo_workspace_registry, {Workspace, events, only}},
                            Handler, Args),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([]) ->
  {ok, #state{}}.

handle_event(Event, State) ->
  io:format("~p", Event),
  {ok, State}.

handle_call(_Request, State) ->
  Reply = ok,
  {ok, Reply, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
