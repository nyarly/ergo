-module(ergo_workspace_watcher).
-behavior(gen_event).


-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).

%% API
-export([ensure_added/1, ensure_added/2, add_to_sup/1, add_to_sup/2, remove/2]).
%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
          tag,
          graph_changed        = silent,
          build_start          = report,
          build_completed      = report,
          task_init            = silent,
          task_started         = report,
          task_completed       = report,
          task_skipped         = report,
          task_changed_graph   = report,
          task_produced_output = report,
          task_failed          = report,
          unknown_event        = report
         }).

%%%===================================================================
%%% Module API
%%%===================================================================

ensure_added(Workspace) ->
  ensure_added(Workspace, [none]).

ensure_added(Workspace, Args) ->
  Leader = group_leader(),
  Existant = [Exists || Exists={?MODULE,_} <- gen_event:which_handlers(?VIA(Workspace)),
                        gen_event:call(?VIA(Workspace), Exists, group_leader) =:= Leader
             ],
  case Existant of
    [] -> add_to_sup(Workspace, Args);
    [This | _] -> update_args(Workspace,This,Args)
  end.

update_args(WS, Handler, Args) ->
  gen_event:call(?VIA(WS), Handler, {update, Args}).

add_to_sup(Workspace) ->
  add_to_sup(Workspace, [none]).

add_to_sup(Workspace, Args) ->
  Handler = {?MODULE, make_ref()},
  gen_event:add_sup_handler(?VIA(Workspace), Handler, Args),
  Handler.

remove(Workspace, Handler) ->
  gen_event:delete_hander(?VIA(Workspace), Handler).


%%%===================================================================
%%% gen_event callbacks
%%%===================================================================
init(Args) ->
  {ok, state_from_args(Args)}.

handle_event(Event, State) ->
  format_event(State, Event),
  {ok, State}.

handle_call(group_leader, State) ->
  {ok, group_leader(), State};
handle_call({update, NewArgs}, _) ->
  {ok, ok, state_from_args(NewArgs)};
handle_call(_Request, State) ->
  {ok, ok, State}.

handle_info(_Info, State) ->
  {ok, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.



state_from_args([Tag]) ->
  #state{tag=Tag}.



format_event(State=#state{tag=none}, Event) ->
  tagged_event("", Event, State);
format_event(State=#state{tag=Tag},  Event) ->
  tagged_event(["[",Tag,"] "], Event, State).


tagged_event(_, Event, #state{graph_changed=silent})        when element(1, Event) =:= graph_changed        -> ok;
tagged_event(_, Event, #state{build_start=silent})          when element(1, Event) =:= build_start          -> ok;
tagged_event(_, Event, #state{build_completed=silent})      when element(1, Event) =:= build_completed      -> ok;
tagged_event(_, Event, #state{task_init=silent})            when element(1, Event) =:= task_init            -> ok;
tagged_event(_, Event, #state{task_started=silent})         when element(1, Event) =:= task_started         -> ok;
tagged_event(_, Event, #state{task_completed=silent})       when element(1, Event) =:= task_completed       -> ok;
tagged_event(_, Event, #state{task_skipped=silent})         when element(1, Event) =:= task_skipped         -> ok;
tagged_event(_, Event, #state{task_completed=silent})       when element(1, Event) =:= task_completed       -> ok;
tagged_event(_, Event, #state{task_changed_graph=silent})   when element(1, Event) =:= task_changed_graph   -> ok;
tagged_event(_, Event, #state{task_produced_output=silent}) when element(1, Event) =:= task_produced_output -> ok;
tagged_event(_, Event, #state{task_failed=silent})          when element(1, Event) =:= task_failed          -> ok;

tagged_event(TagString, {graph_changed}, #state{graph_changed=report}) ->
  io:format("~n~s(ergo): graph changed", [TagString]);

tagged_event(TagString, {build_start, Workspace, BuildId, Targets}, #state{build_start=report}) ->
  io:format("~n~s(ergo): build (ergo:~p) targets: ~p starting in:~n   ~s ~n", [TagString, BuildId, Targets, Workspace]);

tagged_event(TagString, {build_completed, BuildId, true, _Msg}, #state{build_completed=report}) ->
  io:format("~s(ergo:~p): completed successfully.~n", [TagString, BuildId]);

tagged_event(TagString, {build_completed, BuildId, false, Msg}, #state{build_completed=report}) ->
  io:format("~s(ergo:~p): exited with a failure.~n  More info: ~p~n", [TagString, BuildId, Msg]);

tagged_event(TagString, {task_init, Bid, {task, TaskName}}, #state{task_init=report}) ->
  io:format("~s(ergo:~p): init:  ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_started, Bid, {task, TaskName}}, #state{task_started=report}) ->
  io:format("~s(ergo:~p): start: ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_completed, Bid, {task, TaskName}}, #state{task_completed=report}) ->
  io:format("~s(ergo:~p): done: ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_skipped, Bid, {task, TaskName}}, #state{task_skipped=report}) ->
  io:format("~s(ergo:~p):   skipped: ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_changed_graph, Bid, {task, TaskName}}, #state{task_changed_graph=report}) ->
  io:format("~s(ergo:~p): done: ~s: changed dependency graph - recomputing build... ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(_TagString, {task_produced_output, _Bid, {task, _TaskName}, Outlist}, #state{task_produced_output=report}) ->
  io:format("~s", [Outlist]);

tagged_event(TagString, {task_failed, Bid, {task, TaskName}, Exit, {output, OutString}}, #state{task_failed=report}) ->
  io:format("~s(ergo:~p): ~s failed ~p~nOutput:~n~s~n", [TagString, Bid, [[Part, " "] || Part <- TaskName], Exit, OutString]);

tagged_event(TagString, Event, #state{unknown_event=report}) ->
  io:format("~s(ergo:?): ~p~n", [TagString, Event]);

tagged_event(_, _, _) ->
  ok.



%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
