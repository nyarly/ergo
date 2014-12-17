-module(erdo_sup).
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
           supervised(server, erdo_server),
           supervised(registry, erdo_workspace_registry),
           supervised(tasks, erdo_task_soop, supervisor),
           supervised(freshness, erdo_freshness)
          ],
  {ok, {{one_for_one, 1, 5}, Procs}}.


start_workspace(Name) ->
  case supervisor:start_child(?MODULE,
                         {{proj_sup, Name},
                          {erdo_workspace_sup, start_link, Name},
                          permanent, 5, supervisor, [erdo_workspace_sup]}) of
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
%   erdo_commands: the API module for external commands
%   erdo_server: the overall management process
%   erdo_graphs: serves and persists graphs
%   erdo_seq_graph: the sequence graph server
%   erdo_also_graph: the co-task graph server
%   erdo_dep_graph: the dependency graph server
%   erdo_freshness: determines the freshness of external products
%   erdo_build_soop: supervisor of builds
%   erdo_task_soop: supervisor of tasks
%   erdo_build_master: the leader of of a build
%   erdo_build_task: runs a build-task port
