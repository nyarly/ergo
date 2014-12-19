%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @doc
%%%   Listens for events related to the graph
%%% @end
%%% Created :  Fri Oct 17 15:08:47 2014 by Judson Lester
%%%-------------------------------------------------------------------

-module(ergo_graph_events).
-behavior(gen_event).

%% API
-export([add_to/1, add_to/2, add_to_sup/1, add_to_sup/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {graphs}).

%%%===================================================================
%%% Module API
%%%===================================================================
add_to(Server) ->
  add_to(Server, []).

add_to(Server, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_handler(Server, ?MODULE, Args),
  Handler.

add_to_sup(Server) ->
  add_to_sup(Server, []).

add_to_sup(Server, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler(Server, ?MODULE, Args),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([GraphRef]) ->
  {ok, #state{graphs=GraphRef}}.

handle_event({requirement_noted, {First, Second}}, State) ->
  ergo_graphs:requires(State#state.graphs, First, Second);
handle_event({production_noted, {First, Second}}, State) ->
  ergo_graphs:produces(State#state.graphs, First, Second);
handle_event({tasks_joint, {First, Second}}, State) ->
  ergo_graphs:joint_tasks(State#state.graphs, First, Second);
handle_event({tasks_ordered, {First, Second}}, State) ->
  ergo_graphs:order_tasks(State#state.graphs, First, Second);
handle_event(_Event, State) ->
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
