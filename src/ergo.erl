-module(ergo).
-export_type([produced/0, task/0, taskname/0, productname/0, taskspec/0, build_spec/0, target/0, command_result/0, graph_item/0, workspace_name/0]).

-export([watch/0, watch/1, wait_on_build/1, wait_on_build/2, run_build/1, run_build/2, quiet_run_build/2,
         add_product/1, add_product/2, add_product/4, add_required/1, add_required/2, add_required/4, add_file_dep/2, add_cotask/2, add_cotask/4,
         add_task_seq/2, add_task_seq/4, dont_elide/0, skip/0, setup/0]).

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

-spec(watch() -> command_response()).
watch() ->
  watch(ergo_workspace:current()),
  ok.

setup() ->
  ergo_workspace:setup().

-spec(wait_on_build(build_id()) -> command_response()).
wait_on_build(Id) ->
  wait_on_build(ergo_workspace:current(), Id).

-spec(run_build([target()]) -> command_response()).
run_build(Targets) ->
  run_build(ergo_workspace:current(), Targets).

-spec(add_product(productname()) -> command_response()).
add_product(Product) ->
  add_product(ergo_task:current(), Product).

-spec(add_product(taskname(), productname()) -> command_response()).
add_product(Task, Product) ->
  add_product(ergo_workspace:current(), ergo_task:current(), Task, Product).

-spec(add_required(productname()) -> command_response()).
add_required(Product) ->
  add_required(ergo_task:current(), Product).

-spec(add_required(taskname(), productname()) -> command_response()).
add_required(Task, Product) ->
  add_required(ergo_workspace:current(), ergo_task:current(), Task, Product).

-spec(add_file_dep(productname(), productname()) -> command_response()).
add_file_dep(From, To) ->
  add_file_dep(ergo_workspace:current(), ergo_task:current(), From, To).

-spec(add_cotask(taskname(), taskname()) -> command_response()).
add_cotask(Task, Also) ->
  add_cotask(ergo_workspace:current(), ergo_task:current(), Task, Also).

-spec(add_task_seq(taskname(), taskname()) -> command_response()).
add_task_seq(First, Second) ->
  add_task_seq(ergo_workspace:current(), ergo_task:current(), First, Second).

-spec(dont_elide() -> ok).
dont_elide() ->
  dont_elide(ergo_task:current()).

-spec(dont_elide(taskname()) -> ok).
dont_elide(Task) ->
  dont_elide(ergo_workspace:current(), Task).

-spec(skip() -> ok).
skip() ->
  skip(ergo_task:current()).

-spec(skip(taskname()) -> ok).
skip(Task) ->
  skip(ergo_workspace:current(), Task).


%%% Basic functions
%%%

-spec(watch(workspace_name()) -> command_response()).
watch(Workspace) ->
  {ergo_workspace_watcher, _Ref} = ergo_workspace_watcher:add_to_sup(Workspace),
  ok.

-spec(run_build(workspace_name(), [target()]) -> command_response()).
run_build(Workspace, Targets) ->
  {ok, _Pid} = ergo_sup:start_workspace(Workspace),
  watch(Workspace),
  ergo_workspace:start_build(Workspace, Targets).

-spec(quiet_run_build(workspace_name(), [target()]) -> command_response()).
quiet_run_build(Workspace, Targets) ->
  {ok, _Pid} = ergo_sup:start_workspace(Workspace),
  ergo_workspace:start_build(Workspace, Targets).

-spec(add_product(workspace_name(), taskname(), taskname(), productname()) -> command_response()).
add_product(Workspace, Reporter, Task, Product) ->
  ergo_task:add_prod(Workspace, Reporter, Task, Product).

-spec(add_required(workspace_name(), taskname(), taskname(), productname()) -> command_response()).
add_required(Workspace, Reporter, Task, Product) ->
  ergo_task:add_req(Workspace, Reporter, Task, Product).

-spec(add_file_dep(workspace_name(), taskname(), productname(), productname()) -> command_response()).
add_file_dep(Workspace, Reporter, From, To) ->
  ergo_task:add_dep(Workspace, Reporter, From, To).

-spec(add_cotask(workspace_name(), taskname(), taskname(), taskname()) -> command_response()).
add_cotask(Workspace, Reporter, Task, Also) ->
  ergo_task:add_co(Workspace, Reporter, Task, Also).

-spec(add_task_seq(workspace_name(), taskname(), taskname(), taskname()) -> command_response()).
add_task_seq(Workspace, Reporter, First, Second) ->
  ergo_task:add_seq(Workspace, Reporter, First, Second).

-spec(wait_on_build(workspace_name(), build_id()) -> command_response()).
wait_on_build(Workspace, Id) ->
  ergo_build_waiter:wait_on(Workspace, Id).

-spec(dont_elide(workspace_name(), taskname()) -> command_response()).
dont_elide(Workspace, Task) ->
  ergo_task:not_elidable(Workspace, Task).

-spec(skip(workspace_name(), taskname()) -> command_response()).
skip(Workspace, Task) ->
  ergo_task:skip(Workspace, Task).
