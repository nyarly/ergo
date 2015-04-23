-module(ergo).
-export_type([produced/0, task/0, taskname/0, productname/0, taskspec/0,
              build_spec/0, target/0, command_result/0, graph_item/0,
              workspace_name/0, build_id/0]).

-export([
         setup/1,
         attach_workspace/0,
         attach_workspace/1,
         find_workspace/0,
         find_workspace/1,
         watch/1,
         run_build/2
         ]).

-type taskname() :: [binary()]. % should change to _name
-type productname() :: file:name_all(). % here too

-type produced() :: {produced, productname()}.
-type task() :: {task, taskname()}.
-type target() :: produced() | task ().
-type taskspec() :: { taskname(), productname(), [binary()] }.
-type task_seq() :: {taskname(), [taskname()]}.
-type build_spec() :: [task_seq()].
-type build_id() :: integer().

-type command_result() :: {result, ok}.

-type graph_seq_item() :: {seq, taskname(), taskname()}.
-type graph_co_item() :: {co, taskname(), taskname()}.
-type graph_prod_item() :: {prod, taskname(), productname()}.
-type graph_dep_item() :: {dep, productname(), productname()}.
-type graph_item() :: graph_dep_item() | graph_prod_item() | graph_co_item() | graph_seq_item().

-type workspace_name() :: binary().

-type command_response() :: ok.
%-type query_response() :: ok.

setup(Dir) ->
  ergo_workspace:setup(Dir).

attach_workspace() ->
  attach_workspace(os:getenv("PWD")).

attach_workspace(Dir) ->
  WS = find_workspace(Dir),
  {ok, Ref} = ergo:watch(WS),
  {ok, WS, Ref}.

find_workspace() ->
  find_workspace(os:getenv("PWD")).

find_workspace(Dir) ->
  ergo_workspace:find_dir(Dir).

-spec(watch(workspace_name()) -> command_response()).
watch(Workspace) ->
  {ok, _Pid} = ergo_sup:start_workspace(Workspace),
  {ergo_workspace_watcher, Ref} = ergo_workspace_watcher:ensure_added(Workspace),
  {ok, Ref}.

-spec(run_build(workspace_name(), [target()]) -> command_response()).
run_build(Workspace, Targets) ->
  {ok, _Pid} = ergo_sup:start_workspace(Workspace),
  ergo_workspace:start_build(Workspace, Targets).

%%% Basic functions
%%%
