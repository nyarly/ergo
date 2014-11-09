%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2014 Judson Lester. All Rights Reserved.
%%% @end
%%% Created :  Sun Oct 19 20:26:27 2014 by Judson Lester
%%%-------------------------------------------------------------------
-module(erdo_builds_soop).
-behavior(supervisor).
%% API
-export([start_link/0, start_build/1, running_builds/0]).
%% Supervisor callbacks
-export([init/1]).
-define(SERVER, ?MODULE).

%%% API functions
start_link() ->
  supervisor:start_link({local, ?SERVER}, ?MODULE, []).
start_build(Args) ->
  supervisor:start_child(?SERVER, Args).
running_builds() ->
  [TaskPid || {_Id, TaskPid, _Type, _Mods} <- supervisor:which_children(?SERVER), is_pid(TaskPid)].

%%% Supervisor callbacks
init([]) ->
  RestartStrategy = simple_one_for_one,
  MaxRestarts = 10,
  MaxSecondsBetweenRestarts = 3600,
  SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},
  Restart = permanent,
  Shutdown = 2000,
  Type = worker,
  AChild = {ignored, {erdo_build, start_link, []},
    Restart, Shutdown, Type, [erdo_build]},
  {ok, {SupFlags, [AChild]}}.
