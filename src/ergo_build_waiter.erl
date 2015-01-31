%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2015 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Fri Jan 09 09:15:20 2015 by Judson Lester
%%%-------------------------------------------------------------------

-module(ergo_build_waiter).
-behavior(gen_event).

%% API
-export([wait_on/2, add_listener/2, block_until_dead/1]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {pid,build}).

-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).
%%%===================================================================
%%% Module API
%%%===================================================================
wait_on(Workspace, BuildId) ->
  add_listener(Workspace, BuildId),
  block_until_dead(ergo_build:check_alive(Workspace,BuildId)),
  ok.

block_until_dead(alive) ->
  ct:pal("Build is alive..."),
  receive
    build_complete -> ok;
    OtherThing -> ct:pal("Don't recognize: ~p~n", [OtherThing])
  end;
block_until_dead(_) ->
  ok.

add_listener(Workspace, BuildId) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler(?VIA(Workspace), Handler, [self(),BuildId]),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([Pid,BuildId]) ->
  {ok, #state{pid=Pid,build=BuildId}}.

handle_event({build_completed, BuildId, _Success}, #state{pid=Pid,build=BuildId}) ->
  Pid ! build_complete,
  remove_handler;
handle_event(Event, State) ->
   ct:pal("Waiting - saw ~p~n", [Event]),
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
