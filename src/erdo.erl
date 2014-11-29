-module(erdo).
-export_type([produced/0, task/0, taskname/0, taskspec/0, build_spec/0, target/0, command_result/0, graph_item/0]).

-type produced() :: {produced, productname()}.
-type task() :: {task, taskname()}.
-type taskname() :: [binary()].
-type productname() :: file:name_all().
-type taskspec() :: { taskname(), productname(), [binary()] }.
-type build_spec() :: task().
-type target() :: produced() | task ().
-type command_result() :: {result, ok}.
-type graph_seq_item() :: {seq, taskname(), taskname()}.
-type graph_co_item() :: {co, taskname(), taskname()}.
-type graph_prod_item() :: {prod, taskname(), productname()}.
-type graph_dep_item() :: {dep, productname(), productname()}.
-type graph_item() :: graph_dep_item() | graph_prod_item() | graph_co_item() | graph_seq_item().
