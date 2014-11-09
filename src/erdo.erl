-module(erdo).
-export_type([produced/0, task/0, build_spec/0, target/0, command_result/0]).

-type produced() :: {produced, string()}.
-type task() :: {task, taskname()}.
-type taskname() :: [binary()].
-type build_spec() :: task().
-type target() :: produced() | task ().
-type command_result() :: {result, ok}.
