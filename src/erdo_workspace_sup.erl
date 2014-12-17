-module(erdo_workspace_sup).
-behavior(supervisor).

-export([start_link/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link(WorkspaceName) ->
  supervisor:start_link({via, erdo_workspace_registry, {WorkspaceName, supervisor, only}}, ?MODULE, WorkspaceName).

supervised(Workspace, Name, Module) ->
  supervised(Workspace, Name, Module, worker).

supervised(Workspace, Name, Module, Type) ->
  { Name, { Module, start_link, [Workspace] }, permanent, 5, Type, [Module]}.

init(WorkspaceName) ->
  Procs = [
           supervised(WorkspaceName, builds, erdo_builds_soop, supervisor),
           supervised(WorkspaceName, graphs, erdo_graphs),
           { events, { gen_event, start_link,
                       [{via, erdo_workspace_registry, {WorkspaceName, events, only}}]
                     },
             permanent, 5, worker, dynamic}
          ],
  {ok, {{one_for_one, 1, 5}, Procs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
