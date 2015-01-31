-module(ergo_workspace_watcher).
-behavior(gen_event).

%% API
-export([add_to_sup/1, add_to_sup/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {tag}).

%%%===================================================================
%%% Module API
%%%===================================================================
add_to_sup(Workspace) ->
  add_to_sup(Workspace, [none]).

add_to_sup(Workspace, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler({via, ergo_workspace_registry, {Workspace, events, only}},
                            Handler, Args),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([Tag]) ->
  {ok, #state{tag=Tag}}.

handle_event(Event, State=#state{tag=Tag}) ->
  format_event(Tag, Event),
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

format_event(none, Event) ->
  io:format("Workspace Event: ~p~n", [Event]);
format_event(Tag, Event) ->
  io:format("[~p] Workspace Event: ~p~n", [Tag, Event]).

%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
