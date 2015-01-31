-module(ergo_workspace_sup).
-behavior(supervisor).

-export([start_link/1]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link(WorkspaceName) ->
  supervisor:start_link({via, ergo_workspace_registry, {WorkspaceName, supervisor, only}}, ?MODULE, WorkspaceName).

supervised(Workspace, Module) ->
  supervised(Workspace, Module, Module).

supervised(Workspace, Name, Module) ->
  supervised(Workspace, Name, Module, worker).

supervised(Workspace, Name, Module, Type) ->
  { Name, { Module, start_link, [Workspace] }, permanent, 5, Type, [Module]}.

init(Workspace) ->
  WorkspaceName = ergo_workspace_registry:normalize_name(Workspace),
  Procs = [
           supervised(WorkspaceName, ergo_workspace),
           supervised(WorkspaceName, ergo_graphs),
           { events, { gen_event, start_link,
                       [{via, ergo_workspace_registry, {WorkspaceName, events, only}}]
                     },
             permanent, 5, worker, dynamic}
          ],
  {ok, {{one_for_one, 1, 5}, Procs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
