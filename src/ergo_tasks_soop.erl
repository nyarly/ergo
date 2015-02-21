%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Sun Oct 19 20:26:27 2014 by Judson Lester
%%%-------------------------------------------------------------------
-module(ergo_tasks_soop).
-behavior(supervisor).
%% API
-export([start_link/0, start_task/4, running_tasks/0]).
%% Supervisor callbacks
-export([init/1]).
-define(SERVER, ?MODULE).

%%% API functions
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_task(Limit, RunSpec, WorkspaceDir, Config) ->
  start_task(task_count(), Limit, RunSpec, WorkspaceDir, Config).

start_task(Count, Limit, _RunSpec, _ProjDir, _Config) when Count >= Limit ->
  {err, {too_many_running_tasks, Count}};
start_task(_Count, _Limit, RunSpec, WorkspaceDir, Config) ->
  supervisor:start_child(?SERVER, [RunSpec, WorkspaceDir, Config]).

task_count() ->
  proplists:get_value(active, supervisor:count_children(?SERVER)).

running_tasks() ->
  [ergo_task:task_name(TaskPid) || {_Id, TaskPid, _Type, _Mods} <-
                                   supervisor:which_children(?SERVER), is_pid(TaskPid)].

%%% Supervisor callbacks
init([]) ->
  RestartStrategy = simple_one_for_one,
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 3600,
  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
  Restart = temporary,
  Shutdown = 2000,
  Type = worker,
  AChild = {ignored, {ergo_task, start_link, []}, Restart, Shutdown, Type, [ergo_task]},
  {ok, {SupFlags, [AChild]}}.
