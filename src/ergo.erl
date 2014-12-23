-module(ergo).
-export_type([produced/0, task/0, taskname/0, taskspec/0, build_spec/0, target/0, command_result/0, graph_item/0]).

-export([watch/0, watch/1, wait_on_build/1, wait_on_build/2, run_build/1,
         run_build/2, add_product/2, add_file_dep/2, add_cotask/2,
         add_task_seq/2, this_task_preceeds/1, this_task_follows/1, also_run/1,
         run_whenever/1, dont_elide/0, skip/0, setup/0]).

-type produced() :: {produced, productname()}.
-type task() :: {task, taskname()}.
-type taskname() :: [binary()].
-type productname() :: file:name_all().
-type taskspec() :: { taskname(), productname(), [binary()] }.
-type build_spec() :: task().
-type build_id() :: integer().
-type target() :: produced() | task ().
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
  watch(ergo_workspace:current()).

setup() ->
  ergo_workspace:setup().

-spec(wait_on_build(build_id()) -> command_response()).
wait_on_build(Id) ->
  wait_on_build(ergo_workspace:current(), Id).

-spec(run_build([target()]) -> command_response()).
run_build(Targets) ->
  run_build(ergo_workspace:current(), Targets).

-spec(add_product(task(), product()) -> command_response()).
add_product(Task, Product) ->
  add_product(ergo_workspace:current(), ergo_task:current(), Task, Product).

-spec(add_file_dep(product(), product()) -> command_response()).
add_file_dep(From, To) ->
  add_file_dep(ergo_workspace:current(), ergo_task:current(), From, To).

-spec(add_cotask(task(), task()) -> command_response()).
add_cotask(Task, Also) ->
  add_cotask(ergo_workspace:current(), ergo_task:current(), Task, Also).

-spec(add_task_seq(task(), task()) -> command_response()).
add_task_seq(First, Second) ->
  add_task_seq(ergo_workspace:current(), ergo_task:current(), First, Second).

-spec(this_task_preceeds(task()) -> command_response()).
this_task_preceeds(Other) ->
  add_task_seq(ergo_task:current(), Other).

-spec(this_task_follows(task()) -> command_response()).
this_task_follows(Other) ->
  add_task_seq(Other, ergo_task:current()).

-spec(also_run(task()) -> command_response()).
also_run(Other) ->
  add_cotask(ergo_task:current(), Other).

-spec(run_whenever(task) -> command_response()).
run_whenever(Other) ->
  add_cotask(Other, ergo_task:current()).

-spec(dont_elide() -> ok).
dont_elide() ->
  dont_elide(ergo_task:current()).

-spec(dont_elide(task()) -> ok).
dont_elide(Task) ->
  dont_elide(ergo_workspace:current(), Task).

-spec(skip() -> ok).
skip() ->
  skip(ergo_task:current()).

-spec(skip(task()) -> ok).
skip(Task) ->
  skip(ergo_workspace:current(), Task).


%%% Basic functions
%%%

-spec(watch(workspace_name()) -> command_response()).
watch(Workspace) ->
  ergo_workspace_watcher:add_to_sup(Workspace).

-spec(run_build(workspace_name(), [target()]) -> command_response()).
run_build(Workspace, Targets) ->
  ergo_workspace:start_build(Workspace, Targets).

-spec(add_product(workspace_name(), task(), task(), product()) -> command_response()).
add_product(Workspace, Reporter, Task, Product) ->
  ergo_task:add_prod(Workspace, Reporter, Task, Product).

-spec(add_file_dep(workspace_name(), task(), product(), product()) -> command_response()).
add_file_dep(Workspace, Reporter, From, To) ->
  ergo_task:add_dep(Workspace, Reporter, From, To).

-spec(add_cotask(workspace_name(), task(), task(), task()) -> command_response()).
add_cotask(Workspace, Reporter, Task, Also) ->
  ergo_task:add_cotask(Workspace, Reporter, Task, Also).

-spec(add_task_seq(workspace_name(), task(), task(), task()) -> command_response()).
add_task_seq(Workspace, Reporter, First, Second) ->
  ergo_task:add_seq(Workspace, Reporter, First, Second).

-spec(wait_on_build(workspace_name(), build_id()) -> command_response()).
wait_on_build(Workspace, Id) ->
  ergo_build:link_to(Workspace, Id).

-spec(dont_elide(workspace_name(), task()) -> command_response()).
dont_elide(Workspace, Task) ->
  ergo_task:not_elidable(Workspace, Task).

-spec(skip(workspace_name(), task()) -> command_response()).
skip(Workspace, Task) ->
  ergo_task:skip(Workspace, Task).
