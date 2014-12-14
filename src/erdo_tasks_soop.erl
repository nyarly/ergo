%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Sun Oct 19 20:26:27 2014 by Judson Lester
%%%-------------------------------------------------------------------
-module(erdo_tasks_soop).
-behavior(supervisor).
%% API
-export([start_link/0, start_task/3, running_tasks/0]).
%% Supervisor callbacks
-export([init/1]).
-define(SERVER, ?MODULE).

%%% API functions
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_task(Limit, RunSpec, WorkspaceDir) ->
  start_task(task_count(), Limit, RunSpec, WorkspaceDir).

start_task(Count, Limit, _RunSpec, _ProjDir) when Count >= Limit ->
  {err, {too_many_running_tasks, Count}};
start_task(_Count, _Limit, RunSpec, WorkspaceDir) ->
  supervisor:start_child(?SERVER, [RunSpec, WorkspaceDir]).

task_count() ->
  proplists:get_value(active, supervisor:count_children(?SERVER)).

running_tasks() ->
  [erdo_task:task_name(TaskPid) || {_Id, TaskPid, _Type, _Mods} <-
                                   supervisor:which_children(?SERVER), is_pid(TaskPid)].

%%% Supervisor callbacks
init([]) ->
  RestartStrategy = simple_one_for_one,
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 3600,
  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
  Restart = permanent,
  Shutdown = 2000,
  Type = worker,
  AChild = {ignored, {erdo_task, start_link, []}, Restart, Shutdown, Type, [erdo_task]},
  {ok, {SupFlags, [AChild]}}.
