%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @doc
%%%
%%% @end
%%% Created :  Thu Oct 16 16:19:20 2014 by Judson Lester
%%%-------------------------------------------------------------------

-module(ergo_events).

-export([build_requested/2, requirement_noted/3, production_noted/3, graph_changed/3, task_started/2, task_failed/2, task_completed/2, task_skipped/2, tasks_joint/3, tasks_ordered/3]).

%% @spec:	build_requested(targets::target_list()) -> ok.
%% @doc:	Emits a build_requested event
%% @end
-spec(build_requested(ergo:workspace_name(), [erdo:target()]) -> ok).
build_requested(Workspace, Targets) ->
  send_event(Workspace, {build_requested, Targets}).

%% @spec:	requirement_noted(product::ergo:produced(), dependency::erdo:produced()) -> ok.
%% @end
-spec(requirement_noted(ergo:workspace_name(), erdo:produced(), erdo:produced()) -> ok).
requirement_noted(Workspace, Product, Dependency) ->
  send_event(Workspace, {requirement_noted, {Product, Dependency}}).

%% @spec:	production_noted(product::ergo:produced()) -> ok.
%% @end
-spec(production_noted(ergo:workspace_name(), erdo:task(), erdo:produced()) -> ok).
production_noted(Workspace, Task, Product) ->
  send_event(Workspace, {production_noted, {Task, Product}}).

%% @spec:	graph_changed() -> ok.
%% @doc:	The build graph has changed - the build should be re-evaluated
%% @end
-spec(graph_changed(ergo:workspace_name(), boolean(), boolean()) -> ok).
graph_changed(Workspace, Added, Removed) ->
  send_event(Workspace, {graph_changed, Added, Removed}).

%% @spec:	task_started(task::ergo:task()) -> ok.
%% @end
-spec(task_started(ergo:workspace_name(), erdo:task()) -> ok).
task_started(Workspace, Task) ->
  send_event(Workspace, {task_started, Task}).

%% @spec:	task_failed(Task::ergo:task()) -> ok.
%% @end
-spec(task_failed(ergo:workspace_name(), erdo:task()) -> ok).
task_failed(Workspace, Task) ->
  send_event(Workspace, {task_failed, Task}).

%% @spec:	task_skipped(task::ergo:task()) -> ok.
%% @end
-spec(task_skipped(ergo:workspace_name(), erdo:task()) -> ok).
task_skipped(Workspace, Task) ->
  send_event(Workspace, {task_skipped, Task}).

%% @spec:	task_completed(task::ergo:task()) -> ok.
%% @end

-spec(task_completed(ergo:workspace_name(), erdo:task()) -> ok).
task_completed(Workspace, Task) ->
  send_event(Workspace, {task_completed, Task}).

%% @spec:	tasks_joint(first::ergo:task(), second::erdo:task()) -> ok.
%% @end
-spec(tasks_joint(ergo:workspace_name(), erdo:task(), erdo:task()) -> ok).
tasks_joint(Workspace, First, Second) ->
  send_event(Workspace, {tasks_joint, {First, Second}}).

%% @spec:	tasks_ordered(first::ergo:task(), second::erdo:task()) -> ok.
%% @end
-spec(tasks_ordered(ergo:workspace_name(), erdo:task(), erdo:task()) -> ok).
tasks_ordered(Workspace, First, Second) ->
  send_event(Workspace, {tasks_ordered, {First, Second}}).


-spec(send_event(ergo:workspace_name(), term()) -> ok).
send_event(Workspace, Event) ->
  gen_event:notify({via, ergo_workspace_registry, {Workspace, events, only}}, Event).
