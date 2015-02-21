-module(ergo_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1, start_workspace/1]).

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
           supervised(tasks, ergo_tasks_soop, supervisor)
          ],
  {ok, {{one_for_one, 1, 5}, Procs}}.


start_workspace(Name) ->
  case supervisor:start_child(?MODULE,
                         {{proj_sup, Name},
                          {ergo_workspace_sup, start_link, [Name]},
                          permanent, 5, supervisor, [ergo_workspace_sup]}) of
    {ok, Pid} ->
      {ok, Pid};
    {error, {already_started, Pid}} ->
      {ok, Pid};
    Error = {error, _} ->
      Error;
    Any -> {error, Any}
  end.
