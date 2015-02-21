%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @doc
%%%
%%% @end
%%% Created :  Thu Oct 16 16:19:20 2014 by Judson Lester
%%%-------------------------------------------------------------------

-module(ergo_events).

-export([build_requested/2, build_completed/4, build_warning/3, requirement_noted/3, production_noted/3,
         graph_changed/1, task_init/2, task_started/2, task_produced_output/3, task_failed/4, task_completed/2,
         task_changed_graph/2, task_skipped/2, tasks_joint/3, tasks_ordered/3]).

%% @spec:	build_requested(targets::target_list()) -> ok.
%% @doc:	Emits a build_requested event
%% @end
-spec(build_requested(ergo:workspace_name(), [ergo:target()]) -> ok).
build_requested(Workspace, Targets) ->
  send_event(Workspace, {build_requested, Targets}).


-spec(build_completed(ergo:workspace_name(), integer(), boolean(), term()) -> ok).
build_completed(Workspace, BuildId, Succeeded, Message) ->
  send_event(Workspace, {build_completed, BuildId, Succeeded, Message}).

-spec(build_warning(ergo:workspace_name(), integer(), boolean()) -> ok).
build_warning(Workspace, BuildId, Warning) ->
  send_event(Workspace, {build_warning, BuildId, Warning}).


%% @spec:	requirement_noted(product::ergo:produced(), dependency::ergo:produced()) -> ok.
%% @end
-spec(requirement_noted(ergo:workspace_name(), ergo:produced(), ergo:produced()) -> ok).
requirement_noted(Workspace, Product, Dependency) ->
  send_event(Workspace, {requirement_noted, {Product, Dependency}}).

%% @spec:	production_noted(product::ergo:produced()) -> ok.
%% @end
-spec(production_noted(ergo:workspace_name(), ergo:task(), ergo:produced()) -> ok).
production_noted(Workspace, Task, Product) ->
  send_event(Workspace, {production_noted, {Task, Product}}).

%% @spec:	graph_changed() -> ok.
%% @doc:	The build graph has changed - the build should be re-evaluated
%% @end
-spec(graph_changed(ergo:workspace_name()) -> ok).
graph_changed(Workspace) ->
  send_event(Workspace, {graph_changed}).

%% @spec:	task_started(task::ergo:task()) -> ok.
%% @end
-spec(task_init(ergo:workspace_name(), ergo:task()) -> ok).
task_init(Workspace, Task) ->
  send_event(Workspace, {task_init, Task}).

%% @spec:	task_started(task::ergo:task()) -> ok.
%% @end
-spec(task_started(ergo:workspace_name(), ergo:task()) -> ok).
task_started(Workspace, Task) ->
  send_event(Workspace, {task_started, Task}).

%% @spec:	task_produced_output(task::ergo:task()) -> ok.
%% @end
-spec(task_produced_output(ergo:workspace_name(), ergo:task(), string()) -> ok).
task_produced_output(Workspace, Task, Output) ->
  send_event(Workspace, {task_produced_output, Task, Output}).

%% @spec:	task_failed(Task::ergo:task()) -> ok.
%% @end
-spec(task_failed(ergo:workspace_name(), ergo:task(), term(), [string()]) -> ok).
task_failed(Workspace, Task, Reason,Output) ->
  send_event(Workspace, {task_failed, Task, Reason, Output}).

%% @spec:	task_changed_graph(task::ergo:task()) -> ok.
%% @end
-spec(task_changed_graph(ergo:workspace_name(), ergo:task()) -> ok).
task_changed_graph(Workspace, Task) ->
  send_event(Workspace, {task_changed_graph, Task}).

%% @spec:	task_skipped(task::ergo:task()) -> ok.
%% @end
-spec(task_skipped(ergo:workspace_name(), ergo:task()) -> ok).
task_skipped(Workspace, Task) ->
  send_event(Workspace, {task_skipped, Task}).

%% @spec:	task_completed(task::ergo:task()) -> ok.
%% @end

-spec(task_completed(ergo:workspace_name(), ergo:task()) -> ok).
task_completed(Workspace, Task) ->
  send_event(Workspace, {task_completed, Task}).

%% @spec:	tasks_joint(first::ergo:task(), second::ergo:task()) -> ok.
%% @end
-spec(tasks_joint(ergo:workspace_name(), ergo:task(), ergo:task()) -> ok).
tasks_joint(Workspace, First, Second) ->
  send_event(Workspace, {tasks_joint, {First, Second}}).

%% @spec:	tasks_ordered(first::ergo:task(), second::ergo:task()) -> ok.
%% @end
-spec(tasks_ordered(ergo:workspace_name(), ergo:task(), ergo:task()) -> ok).
tasks_ordered(Workspace, First, Second) ->
  send_event(Workspace, {tasks_ordered, {First, Second}}).


-spec(send_event(ergo:workspace_name(), term()) -> ok).
send_event(Workspace, Event) ->
  gen_event:notify({via, ergo_workspace_registry, {Workspace, events, only}}, Event).
