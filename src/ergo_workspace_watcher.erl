-module(ergo_workspace_watcher).
-behavior(gen_event).


-define(VIA(Workspace), {via, ergo_workspace_registry, {Workspace, events, only}}).

%% API
-export([ensure_added/1, ensure_added/2, add_to_sup/1, add_to_sup/2, remove/2]).
%% gen_event callbacks
-export([init/1, handle_event/2, handle_call/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {
          tag,
           graph_changed         = silent,
          build_warning          = report,
          build_start            = report,
          build_completed        = report,
          build_task_done        = report,
          task_generation        = report,
           task_init             = silent,
           task_started          = silent,
          task_running           = report,
           task_completed        = report,
          task_skipped           = report,
          task_invalid           = report,
          task_changed_graph     = report,
           task_produced_output  = silent,
          task_failed            = report,
          invalid_provenence     = report,
           disclaimed_production = silent,
           graph_contradiction   = report,
          unknown_event          = report
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
  gen_event:delete_handler(?VIA(Workspace), Handler, []).


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

-define(pf(Stuff), io_lib:format("~p", [Stuff])).
-define(tn(Taskname), format_task(Taskname)).

format_event(State=#state{tag=none}, Event) ->
  tagged_event("", Event, State);
format_event(State=#state{tag=Tag},  Event) ->
  tagged_event(["[",Tag,"] "], Event, State).

tagged_event(_, Event, #state{graph_changed=silent})         when element(1, Event) =:= graph_changed         -> ok;
tagged_event(_, Event, #state{build_warning=silent})         when element(1, Event) =:= build_warning         -> ok;
tagged_event(_, Event, #state{build_task_done=silent})       when element(1, Event) =:= build_task_done       -> ok;
tagged_event(_, Event, #state{build_start=silent})           when element(1, Event) =:= build_start           -> ok;
tagged_event(_, Event, #state{build_completed=silent})       when element(1, Event) =:= build_completed       -> ok;
tagged_event(_, Event, #state{task_init=silent})             when element(1, Event) =:= task_init             -> ok;
tagged_event(_, Event, #state{task_generation=silent})       when element(1, Event) =:= task_generation       -> ok;
tagged_event(_, Event, #state{task_started=silent})          when element(1, Event) =:= task_started          -> ok;
tagged_event(_, Event, #state{task_running=silent})          when element(1, Event) =:= task_running          -> ok;
tagged_event(_, Event, #state{task_completed=silent})        when element(1, Event) =:= task_completed        -> ok;
tagged_event(_, Event, #state{task_skipped=silent})          when element(1, Event) =:= task_skipped          -> ok;
tagged_event(_, Event, #state{task_invalid=silent})          when element(1, Event) =:= task_invalid          -> ok;
tagged_event(_, Event, #state{task_completed=silent})        when element(1, Event) =:= task_completed        -> ok;
tagged_event(_, Event, #state{task_changed_graph=silent})    when element(1, Event) =:= task_changed_graph    -> ok;
tagged_event(_, Event, #state{task_produced_output=silent})  when element(1, Event) =:= task_produced_output  -> ok;
tagged_event(_, Event, #state{task_failed=silent})           when element(1, Event) =:= task_failed           -> ok;
tagged_event(_, Event, #state{invalid_provenence=silent})    when element(1, Event) =:= invalid_provenence    -> ok;
tagged_event(_, Event, #state{disclaimed_production=silent}) when element(1, Event) =:= disclaimed_production -> ok;
tagged_event(_, Event, #state{graph_contradiction=silent})   when element(1, Event) =:= graph_contradiction   -> ok;

tagged_event(TagString, {graph_changed}, #state{graph_changed=report}) ->
  io:format("~n~s(ergo): graph changed", [TagString]);

tagged_event(TagString, {build_warning, BuildId, {configfile, Error, Path}}, #state{build_warning=report}) ->
  io:format("~n~s(ergo:~p) WARN: Couldn't open config file at '~s' because <~p>.~n", [TagString, BuildId, Path, Error]);
tagged_event(TagString, {build_warning, BuildId, Warning}, #state{build_warning=report}) ->
  io:format("~n~s(ergo:~p) WARN: ~p~n", [TagString, BuildId, Warning]);


tagged_event(TagString, {build_task_done, BuildId, Taskname, Started, Completed}, #state{build_task_done=report}) ->
  io:write([TagString,build_tag(BuildId),<<"Task ">>,?tn(Taskname),<<" marked done. ">>,?pf(Started - Completed),<<" tasks outstanding (">>,?pf(Started),<<"/">>,?pf(Completed),<<")\n">>]);

tagged_event(TagString, {build_start, Workspace, BuildId, Targets}, #state{build_start=report}) ->
  io:format([TagString,<<"(ergo): build ">>,build_tag(BuildId),<<" targets: ">>,?pf(Targets),<<" starting in:\n  ">>,Workspace,<<"\n">>]);

tagged_event(TagString, {build_completed, BuildId, true, _Msg}, #state{build_completed=report}) ->
  io:format("~sBuild (ergo:~p): completed successfully.~n", [TagString, BuildId]);

tagged_event(TagString, {build_completed, BuildId, false, Msg}, #state{build_completed=report}) ->
  io:format("~sBuild (ergo:~p): exited with a failure.~n  More info: ~p~n", [TagString, BuildId, Msg]);

tagged_event(TagString, {task_init, Bid, {task, TaskName}}, #state{task_init=report}) ->
  io:format("~s(ergo:~p): init:  ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_generation, Bid, Tasklist}, #state{task_generation=report}) ->
  io:format("~s(ergo:~p): new task generation: ~s ~n", [TagString, Bid, join_iolist([join_iolist(Task," ") || Task <- Tasklist],", ")]);

tagged_event(TagString, {task_started, Bid, {task, TaskName}}, #state{task_started=report}) ->
  build_tagged_message(TagString, Bid, [<<"start: ">>, ?tn(TaskName)]);

tagged_event(TagString, {task_running, Bid, TaskName}, #state{task_running=report}) ->
  build_tagged_message(TagString, Bid, [<<"running: ">>, ?tn(TaskName)]);

tagged_event(TagString, {task_completed, Bid, {task, TaskName}}, #state{task_completed=report}) ->
  io:format("~s(ergo:~p): done: ~s ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(TagString, {task_skipped, Bid, {task, TaskName}}, #state{task_skipped=report}) ->
  io:format("~s(ergo:~p):   skipped: ~s ~n", [TagString, Bid, format_task(TaskName)]);

tagged_event(TagString, {task_invalid, Bid, TaskName, Message}, #state{task_invalid=report}) ->
  io:write([TagString, "(ergo:",pfmt(Bid),"):   invalid: ",format_task(TaskName)," because: ",?pf(Message),"\n"]);

tagged_event(TagString, {task_changed_graph, Bid, {task, TaskName}}, #state{task_changed_graph=report}) ->
  io:format("~s(ergo:~p): done: ~s: changed dependency graph - recomputing build... ~n", [TagString, Bid, [[Part, " "] || Part <- TaskName]]);

tagged_event(_TagString, {task_produced_output, _Bid, {task, TaskName}, Outlist}, #state{task_produced_output=report}) ->
  io:format("~p: ~s", [TaskName, Outlist]);

tagged_event(TagString, {task_failed, Bid, {task, TaskName}, Exit, OutString}, #state{task_failed=report}) ->
  build_tagged_message(TagString, Bid,
                       [?tn(TaskName), <<" failed ">>, format_error(Exit), <<"\nOutput: \n">>, OutString]);




%{disclaimed_production,
%              {0,
%               [<<"tasks/app">>],
%               [{disclaim,
%                    {prod,[<<"tasks/app">>],"ebin/.app"},
%                    [[<<"tasks/tests-ct">>,<<"ergo_freshness">>],
%                     [<<"tasks/tests-ct">>,<<"integration">>],
%                     [<<"tasks/all-ct">>]]}]}}
tagged_event(TagString, {disclaimed_production, Bid, _Task, DisclaimerList}, #state{disclaimed_production=report}) ->
  lists:foreach(
    fun(Disclaimer) ->
        build_tagged_message(TagString, Bid, disclaimer_message(Disclaimer))
    end, DisclaimerList);


%{graph_contradiction,0,
%    [<<"child/tasks/two">>],
%    {single_producer,"child/b.txt",
%        [{[<<"child/tasks/bootstrap">>],
%          {prod,[<<"child/tasks/two">>],"child/b.txt"}},
%         {[<<"child/tasks/two">>],
%          {prod,[<<"child/child/tasks/two">>],"child/b.txt"}}]}}
tagged_event(TagString, {graph_contradiction, Bid, _Task, Contradiction}, #state{graph_contradiction=report}) ->
  build_tagged_message(TagString, Bid, contradiction_message(Contradiction));



tagged_event(TagString, {invalid_provenence, Bid, About, Asserter, Stmt}, #state{invalid_provenence=report}) ->
  build_tagged_message(TagString, Bid,
                       [<<"Invalid task ">>,format_task(About),<<" drawn into graph by statement: <<">>,
                        format_statement(Stmt),<<">> by ">>,format_task(Asserter)]);

tagged_event(TagString, Event, #state{unknown_event=report}) ->
  io:format("~s(ergo:?): ~p~n", [TagString, Event]);

tagged_event(_, _, _) ->
  ok.


format_error({record_error, {disclaimed_production, DisclaimerList}}) ->
  [ disclaimer_message(Disclaimer) || Disclaimer <- DisclaimerList ];
format_error(Error) ->
  ?pf(Error).

contradiction_message({ single_producer, Product, Claims }) ->
  [<<"Every product can have at most one producing task, but ">>, ?pf(Product),<<" has multiple candidates:">>,
   [ [<<"\n  ">>,?tn(Claimer),<<" claims that ">>,?tn(Claimed),<<" produces ">>,?pf(Product)] ||
     { Claimer, { prod, Claimed, _ }} <- Claims ],
   <<"\n">>];
contradiction_message(Event = { unique_fresh_taskmeta, _Product, _Claims }) ->
  pfmt(Event);
contradiction_message(Event = { unique_fresh_filemeta, _Product, _Claims }) ->
  pfmt(Event).

disclaimer_message({disclaim, {prod, About, Product}, Mistaken}) ->
  [<<"Task ">>,?tn(About),<<" doesn't report producing ">>, ?pf(Product),
   <<" although other tasks claim that it does: ">>, [ [<<"\n    ">>, ?tn(Oops)] || Oops <- Mistaken ]].

build_tagged_message(TagString, Bid, IoList) ->
  io:format("~s", [[TagString, build_tag(Bid), IoList, <<"\n">>]]).

pfmt(Term) ->
  io_lib:format("~p", [Term]).

format_task(Taskname) ->
  [<<"'">>, join_iolist(Taskname," "), <<"'">>].

build_tag(BuildId) ->
  [<<"(ergo:">>, pfmt(BuildId), <<"): ">>].

format_statement({co, Task, Other}) ->
  [format_task(Task), <<" whenever ">>, format_task(Other)];
format_statement({seq, Task, Other}) ->
  [format_task(Task), <<" precedes ">>, format_task(Other)];
format_statement({dep, Task, Product}) ->
  [format_task(Task), <<" requires ">>, Product];
format_statement({prod, Task, Product}) ->
  [format_task(Task), <<" produces ">>, Product].

join_iolist([], _) -> [];
join_iolist([Head | Tail], Sep) ->
  [Head | [[Sep, El] || El <- Tail]].


%format_status(normal, [PDict, State]) ->
%	Status;
%format_status(terminate, [PDict, State]) ->
%	Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
