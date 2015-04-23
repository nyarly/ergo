%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2015 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Fri Jan 09 09:15:20 2015 by Judson Lester
%%%-------------------------------------------------------------------

-module(ergo_build_waiter).
-behavior(gen_event).

%% API
-export([wait_on/2]).

%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2,
  handle_info/2, terminate/2, code_change/3]).

-record(state, {pid,build}).

-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).
%%%===================================================================
%%% Module API
%%%===================================================================
wait_on(Workspace, BuildId) ->
  Ref = {?MODULE, make_ref()},
  add_listener(Workspace, BuildId, Ref),
  block_until_dead(ergo_build:check_alive(Workspace,BuildId), Workspace, BuildId, Ref),
  ok.

block_until_dead(alive, Workspace, BuildId, Ref) ->
  receive
    build_complete -> ok;
    {gen_event_EXIT, Ref, normal} -> ok;
    {gen_event_EXIT, _DifferentRef, normal} -> block_until_dead(alive, Workspace, BuildId, Ref);
    OtherThing -> ct:pal("Waiter ~p: Don't recognize: ~p~n", [Ref, OtherThing])
  end;
block_until_dead(_, _, _, _) ->
  ok.

add_listener(Workspace, BuildId, Handler) ->
  gen_event:add_sup_handler(?VIA(Workspace), Handler, [self(),BuildId]),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([Pid,BuildId]) ->
  process_flag(trap_exit, true),
  {ok, #state{pid=Pid,build=BuildId}}.

handle_event({build_completed, BuildId, _Success, _Message}, #state{pid=Pid,build=BuildId}) ->
  Pid ! build_complete,
  remove_handler;
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
