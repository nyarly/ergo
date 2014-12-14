%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Sun Oct 19 20:26:27 2014 by Judson Lester
%%%-------------------------------------------------------------------
-module(erdo_builds_soop).
-behavior(supervisor).
%% API
-export([start_link/1, start_build/2, running_builds/1]).
%% Supervisor callbacks
-export([init/1]).
-define(SERVER, ?MODULE).

-define(VIA(WorkspaceName), {via, erdo_workspace_registry, {WorkspaceName, builds, only}}).

%%% API functions
start_link([WorkspaceName]) ->
  supervisor:start_link(?VIA(WorkspaceName), ?MODULE, WorkspaceName).
start_build(WorkspaceName, Args) ->
  supervisor:start_child(?VIA(WorkspaceName), Args).
running_builds(WorkspaceName) ->
  [TaskPid || {_Id, TaskPid, _Type, _Mods} <- supervisor:which_children(?VIA(WorkspaceName)), is_pid(TaskPid)].

%%% Supervisor callbacks
init(WorkspaceName) ->
  RestartStrategy = simple_one_for_one,
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 3600,
  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
  Restart = permanent,
  Shutdown = 2000,
  Type = worker,
  AChild = {ignored, {erdo_build, start_link, [WorkspaceName]},
    Restart, Shutdown, Type, [erdo_build]},
  {ok, {SupFlags, [AChild]}}.
