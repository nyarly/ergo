-module(ergo_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1, start_workspace/1, find_workspace/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

supervised(Name, Module) ->
  supervised(Name, Module, worker).

supervised(Name, Module, Type) ->
  { Name, { Module, start_link, [] }, permanent, 5, Type, [Module]}.


init([]) ->
  Procs = [
           supervised(server, ergo_server),
           supervised(registry, ergo_workspace_registry),
           supervised(tasks, ergo_tasks_soop, supervisor),
           supervised(freshness, ergo_freshness)
          ],
  {ok, {{one_for_one, 1, 5}, Procs}}.


start_workspace(Name) ->
  case supervisor:start_child(?MODULE,
                         {{proj_sup, Name},
                          {ergo_workspace_sup, start_link, Name},
                          permanent, 5, supervisor, [ergo_workspace_sup]}) of
    {ok, Pid} -> Pid;
    {error, {already_started, Pid}} -> Pid;
    Error = {error, _} -> Error;
    Any -> {error, Any}
  end.


find_workspace(Name) ->
  case [Child || {Id, Child, _Type, _Modules} <- supervisor:which_children(?MODULE),
                 {proj_sup, Name} =:= Id] of
    [] -> unknown;
    List -> hd(List)
  end.

% Major components:
%   ergo_commands: the API module for external commands
%   ergo_server: the overall management process
%   ergo_graphs: serves and persists graphs
%   ergo_seq_graph: the sequence graph server
%   ergo_also_graph: the co-task graph server
%   ergo_dep_graph: the dependency graph server
%   ergo_freshness: determines the freshness of external products
%   ergo_build_soop: supervisor of builds
%   ergo_task_soop: supervisor of tasks
%   ergo_build_master: the leader of of a build
%   ergo_build_task: runs a build-task port
