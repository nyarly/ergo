%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @doc
%%%
%%% @end
%%% Created :  Thu Oct 16 16:19:20 2014 by Judson Lester
%%%-------------------------------------------------------------------

-module(erdo_events).

-export([build_requested/1, requirement_noted/2, production_noted/2, graph_changed/2, task_started/1, task_failed/1, task_completed/1, task_skipped/1, tasks_joint/2, tasks_ordered/2]).

%% @spec:	build_requested(targets::target_list()) -> ok.
%% @doc:	Emits a build_requested event
%% @end
-spec(build_requested([erdo:target()]) -> ok).
build_requested(Targets) ->
  send_event({build_requested, Targets}).

%% @spec:	requirement_noted(product::erdo:produced(), dependency::erdo:produced()) -> ok.
%% @end
-spec(requirement_noted(erdo:produced(), erdo:produced()) -> ok).
requirement_noted(Product,Dependency) ->
  send_event({requirement_noted, {Product, Dependency}}).

%% @spec:	production_noted(product::erdo:produced()) -> ok.
%% @end
-spec(production_noted(erdo:task(), erdo:produced()) -> ok).
production_noted(Task, Product) ->
  send_event({production_noted, {Task, Product}}).

%% @spec:	graph_changed() -> ok.
%% @doc:	The build graph has changed - the build should be re-evaluated
%% @end
-spec(graph_changed(boolean(), boolean()) -> ok).
graph_changed(Added, Removed) ->
  send_event({graph_changed, Added, Removed}).

%% @spec:	task_started(task::erdo:task()) -> ok.
%% @end
-spec(task_started(erdo:task()) -> ok).
task_started(Task) ->
  send_event({task_started, Task}).

%% @spec:	task_failed(Task::erdo:task()) -> ok.
%% @end
-spec(task_failed(erdo:task()) -> ok).
task_failed(Task) ->
  send_event({task_failed, Task}).

%% @spec:	task_skipped(task::erdo:task()) -> ok.
%% @end
-spec(task_skipped(erdo:task()) -> ok).
task_skipped(Task) ->
  send_event({task_skipped, Task}).

%% @spec:	task_completed(task::erdo:task()) -> ok.
%% @end

-spec(task_completed(erdo:task()) -> ok).
task_completed(Task) ->
  send_event({task_completed, Task}).

%% @spec:	tasks_joint(first::erdo:task(), second::erdo:task()) -> ok.
%% @end
-spec(tasks_joint(erdo:task(), erdo:task()) -> ok).
tasks_joint(First, Second) ->
  send_event({tasks_joint, {First, Second}}).

%% @spec:	tasks_ordered(first::erdo:task(), second::erdo:task()) -> ok.
%% @end
-spec(tasks_ordered(erdo:task(), erdo:task()) -> ok).
tasks_ordered(First, Second) ->
  send_event({tasks_ordered, {First, Second}}).


-spec(send_event(term()) -> ok).
send_event(Event) ->
  gen_event:notify({local, erdo_events}, Event).
