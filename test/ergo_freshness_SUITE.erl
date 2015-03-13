-module(ergo_freshness_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(PRODUCT, "x.out").
-define(DEP, "x.in").
-define(TASKFILE, <<"compile">>).
-define(TASK, [?TASKFILE,  <<"x">>]).

suite() ->
  [{timetrap,{seconds,30}}].
init_per_suite(Config) ->
  Priv = ?config(priv_dir, Config),
  Data = ?config(data_dir, Config),
  lists:foreach(
    fun(Filename) ->
        {ok, _Count} = file:copy(filename:join([Data, Filename]), filename:join([Priv, Filename]))
    end,
    [?PRODUCT, ?DEP, ?TASKFILE]
  ),
  application:set_env(mnesia, dir, Priv),
  application:start(crypto),
  application:start(mnesia),
  application:start(ergo),
  ergo_sup:start_workspace(Priv),
  Config.

end_per_suite(_Config) ->
  dbg:p(all, clear),
  ok.

init_per_group(_GroupName, Config) ->
  Config.
end_per_group(_GroupName, _Config) ->
  ok.

init_per_testcase(_TestCase, Config) ->
  Priv = ?config(priv_dir, Config),
  ergo_graphs:task_batch(Priv, 0, ?TASK,
                         [
                          {req, ?TASK, ?DEP},
                          {prod, ?TASK, ?PRODUCT}
                         ],
                        true),
  ergo_freshness:store(Priv, ?TASK),
  Config.
end_per_testcase(_TestCase, _Config) ->
  ok.

groups() ->
  [].
all() ->
  [store_get_is_hit, change_dep_is_miss, change_prod_is_miss].

%test case info
store_get_is_hit() -> [].
%test case proper
store_get_is_hit(Config) ->
  Priv = ?config(priv_dir, Config),
  hit = ergo_freshness:check(Priv, ?TASK).

change_dep_is_miss() -> [].
change_dep_is_miss(Config) ->
  Priv = ?config(priv_dir, Config),
  file:write_file(filename:join([Priv, ?DEP]), "xxx"),
  miss = ergo_freshness:check(Priv, ?TASK).

change_prod_is_miss() -> [].
change_prod_is_miss(Config) ->
  Priv = ?config(priv_dir, Config),
  file:write_file(filename:join([Priv, ?PRODUCT]), "xxx"),
  miss = ergo_freshness:check(Priv, ?TASK).
