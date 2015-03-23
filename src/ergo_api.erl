-module(ergo_api).

-export([wait_on_build/2, add_product/4, add_required/4, add_file_dep/4,
         add_cotask/4, add_task_seq/4, skip/2 ]).

-spec(add_product(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ergo:command_response()).
add_product(Workspace, Reporter, Task, Product) ->
  ergo_task:add_prod(Workspace, Reporter, Task, Product).

-spec(add_required(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:productname()) -> ergo:command_response()).
add_required(Workspace, Reporter, Task, Product) ->
  ergo_task:add_req(Workspace, Reporter, Task, Product).

-spec(add_file_dep(ergo:workspace_name(), ergo:taskname(), ergo:productname(), ergo:productname()) -> ergo:command_response()).
add_file_dep(Workspace, Reporter, From, To) ->
  ergo_task:add_dep(Workspace, Reporter, From, To).

-spec(add_cotask(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ergo:command_response()).
add_cotask(Workspace, Reporter, Task, Also) ->
  ergo_task:add_co(Workspace, Reporter, Task, Also).

-spec(add_task_seq(ergo:workspace_name(), ergo:taskname(), ergo:taskname(), ergo:taskname()) -> ergo:command_response()).
add_task_seq(Workspace, Reporter, First, Second) ->
  ergo_task:add_seq(Workspace, Reporter, First, Second).

-spec(wait_on_build(ergo:workspace_name(), ergo:build_id()) -> ergo:command_response()).
wait_on_build(Workspace, Id) ->
  ergo_build_waiter:wait_on(Workspace, Id).

skip(Workspace, Task) ->
  ergo_task:skip(Workspace, Task).
