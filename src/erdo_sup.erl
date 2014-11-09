-module(erdo_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
  supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
  Procs = [
    { server, { erdo_server, start_link, [] }, permanent, 5, worker, [erdo_server]},
    { events, { gen_event, start_link, [{local,erdo_events}] }, permanent, 5, worker, dynamic},
    { builds, { erdo_build_soop, start_link, []}, permanent, 5, supervisor, [erdo_build_soop]},
    { tasks, { erdo_task_soop, start_link, []}, permanent, 5, supervisor, [erdo_task_soop]},
    { graphs, { erdo_graphs, start_link, []}, permanent, 5, worker, [erdo_graphs]},
    { freshness, { erdo_freshness, start_link, []}, permanent, 5, worker, [erdo_freshness]}
  ],
  {ok, {{one_for_one, 1, 5}, Procs}}.

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
