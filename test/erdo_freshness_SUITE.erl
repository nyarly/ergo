-module(erdo_freshness_SUITE).
-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(PRODUCT, "x.out").
-define(DEP, "x.in").
-define(TASK, [<<"compile">>,  <<"x">>]).

suite() ->
  [{timetrap,{seconds,30}}].
init_per_suite(Config) ->
  Priv = ?config(priv_dir, Config),
  Data = ?config(data_dir, Config),
  lists:foreach(
    fun(Filename) ->
        {ok, _Count} = file:copy(filename:join([Data, Filename]), filename:join([Priv, Filename]))
    end,
    [?PRODUCT, ?DEP]
  ),
  application:set_env(mnesia, dir, Priv),
  erdo_freshness:start(),
  %application:start(erdo),
  Config.

end_per_suite(_Config) ->
  ok.

init_per_group(_GroupName, Config) ->
  Config.
end_per_group(_GroupName, _Config) ->
  ok.

init_per_testcase(_TestCase, Config) ->
  Priv = ?config(priv_dir, Config),
  erdo_freshness:store(?TASK, Priv, [?DEP], [?PRODUCT]),
  Config.
end_per_testcase(_TestCase, _Config) ->
  ok.

groups() ->
  [].
all() ->
  [store_get_is_hit, change_dep_is_miss, change_prod_is_miss].

%test case info
store_get_is_hit() ->
  [].
%test case proper
store_get_is_hit(Config) ->
  Priv = ?config(priv_dir, Config),
  hit = erdo_freshness:check(?TASK, Priv, [?DEP]).

change_dep_is_miss() -> [].
change_dep_is_miss(Config) ->
  Priv = ?config(priv_dir, Config),
  file:write_file(filename:join([Priv, ?DEP]), "xxx"),
  miss = erdo_freshness:check(?TASK, Priv, [?DEP]).

change_prod_is_miss() -> [].
change_prod_is_miss(Config) ->
  Priv = ?config(priv_dir, Config),
  file:write_file(filename:join([Priv, ?PRODUCT]), "xxx"),
  miss = erdo_freshness:check(?TASK, Priv, [?DEP]).
