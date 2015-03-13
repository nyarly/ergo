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
  tagged_event("", Event);
format_event(Tag, Event) ->
  tagged_event(["[",Tag,"] "], Event).


tagged_event(TagString, {graph_changed}) ->
  ok;
tagged_event(TagString, {build_start, Workspace, BuildId, Targets}) ->
  io:format("~n~s(ergo): build (id ~p) targets: ~p starting in:~n   ~s ~n", [TagString, BuildId, Targets, Workspace]);
tagged_event(TagString, {build_completed, BuildId, true, _Msg}) ->
  io:format("~s(ergo): build id ~p completed successfully.~n", [TagString, BuildId]);
tagged_event(TagString, {build_completed, BuildId, false, Msg}) ->
  io:format("~s(ergo): build id ~p exited with a failure.~n  More info: ~p~n", [TagString, BuildId, Msg]);
tagged_event(TagString, {task_init, {task, TaskName}}) ->
  %io:format("~s(ergo): init:  ~s ~n", [TagString, [[Part, " "] || Part <- TaskName]]);
  ok;
tagged_event(TagString, {task_started, {task, TaskName}}) ->
  io:format("~s(ergo): start: ~s ~n", [TagString, [[Part, " "] || Part <- TaskName]]);
tagged_event(TagString, {task_completed, {task, TaskName}}) ->
  io:format("~s(ergo): done: ~s ~n", [TagString, [[Part, " "] || Part <- TaskName]]);
tagged_event(TagString, {task_skipped, {task, TaskName}}) ->
  io:format("~s(ergo):   skipped: ~s ~n", [TagString, [[Part, " "] || Part <- TaskName]]);
tagged_event(TagString, {task_changed_graph, {task, TaskName}}) ->
  io:format("~s(ergo): done: ~s: changed dependency graph - recomputing build... ~n", [TagString, [[Part, " "] || Part <- TaskName]]);
tagged_event(_TagString, {task_produced_output, {task, _TaskName}, Outlist}) ->
  %io:format("~s", [Outlist]);
  ok;
tagged_event(TagString, {task_failed, {task, TaskName}, Exit, {output, OutString}}) ->
  io:format("~s(ergo): ~s failed ~p~nOutput:~n~s~n", [TagString, [[Part, " "] || Part <- TaskName], Exit, OutString]);
tagged_event(TagString, Event) ->
  io:format("~s(ergo): ~p~n", [TagString, Event]).


%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
