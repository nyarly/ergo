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

-type liveness() :: alive | dead.
-type build_ref() :: {?MODULE, reference()}.

-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).
%%%===================================================================
%%% Module API
%%%===================================================================

-spec(wait_on(ergo:workspace_name(), ergo:build_id()) -> ergo:result()).
wait_on(Workspace, BuildId) ->
  Ref = {?MODULE, make_ref()},
  Ref = add_listener(Workspace, BuildId, Ref),
  block_until_dead(ergo_build:check_alive(Workspace,BuildId), Workspace, BuildId, Ref).

-spec(block_until_dead(liveness(), Workspace::ergo:workspace_name(), BuildId::ergo:build_id(), build_ref()) -> ergo:result()).
block_until_dead(alive, Workspace, BuildId, Ref) ->
  receive
    {build_complete, Success, Message}      -> {ok, {Success, Message}};
    {gen_event_EXIT, Ref, normal}           -> {ok, {unknown, events_exited}};
    {gen_event_EXIT, _DifferentRef, normal} -> block_until_dead(alive, Workspace, BuildId, Ref);
    OtherThing                              -> io:format("Waiter ~p: Don't recognize: ~p~n", [Ref, OtherThing]),
                                               {error, {unknown, {Ref, OtherThing}}}
  end;
block_until_dead(_, _, _, _) ->
  {ok, finished}.

add_listener(Workspace, BuildId, Handler) ->
  gen_event:add_sup_handler(?VIA(Workspace), Handler, [self(),BuildId]),
  Handler.

%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init([Pid,BuildId]) ->
  process_flag(trap_exit, true),
  {ok, #state{pid=Pid,build=BuildId}}.

handle_event({build_completed, BuildId, Success, Message}, #state{pid=Pid,build=BuildId}) ->
  Pid ! {build_complete, Success, Message},
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
