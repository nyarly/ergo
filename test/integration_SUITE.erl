%%%-------------------------------------------------------------------
%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2015 Judson Lester. All Rights Reserved.
%%% Created :  Sun Jan 04 14:58:25 2015 by Judson Lester
%%%-------------------------------------------------------------------
-module(integration_SUITE).
%% Note: This directive should only be used in test suites.
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
%%--------------------------------------------------------------------
%% COMMON TEST CALLBACK FUNCTIONS
%%--------------------------------------------------------------------
suite() ->
  [
   {timetrap,{seconds,30}},
   {create_priv_dir, auto_per_tc}
  ].
init_per_suite(Config) ->
  dbg:tracer(),

  %{ok, _} = dbg:tpl(ergo_cli, taskfile, []),
  %{ok, _} = dbg:tp(ergo_api, []),
  %{ok, _} = dbg:tpl(ergo_task, []), %[{'_',[],[{return_trace}]}]),
  %{ok, _} = dbg:tpl(ergo_task, reparent_item, [{'_',[],[{return_trace}]}]),
  %{ok, _} = dbg:tpl(ergo_task, reparent_task, [{'_',[],[{return_trace}]}]),
  %{ok, _} = dbg:tpl(ergo_freshness, check, [{'_',[],[{return_trace}]}]),

  {ok, _} = dbg:tpl(ergo_task_pool, []),
  %{ok, _} = dbg:tpl(ergo_task, []),
  %{ok, _} = dbg:tpl(ergo_build, []),
  %{ok, _} = dbg:tpl(ergo_build,handle_event, [{['$1','$2'], [{'=/=', {'element', 1, '$1'}, task_produced_output}], []}]),
  %{ok, _} = dbg:tpl(ergo_build,start_tasks, []),
  %{ok, _} = dbg:tpl(ergo_graphs,build_list, [{'_',[],[{return_trace}]}]),
  %{ok, _} = dbg:tpl(ergo_build,start_task, 5, []),
%  {ok, _} = dbg:tpl(ergo_build,task_changed_graph, []),
%  {ok, _} = dbg:tpl(ergo_build,task_completed, []),
  %{ok, _} = dbg:tpl(ergo_freshness,[]),
  %{ok, _} = dbg:tpl(ergo_freshness,digest_list, [{'_',[],[{return_trace}]}]),
  %{ok,_} = dbg:tpl(ergo_graphs,task_batch,[]),
  dbg:p(all,c),
  process_flag(trap_exit,true),
  DataDir = proplists:get_value(data_dir, Config),
  PrivDir = proplists:get_value(priv_dir, Config),
  copy_dir(DataDir, PrivDir),
  Config.

end_per_suite(_Config) ->
  dbg:ctp(),
  dbg:p(all,clear),
  ok.

init_per_group(_GroupName, Config) ->
  Config.

end_per_group(_GroupName, _Config) ->
  ok.

init_per_testcase(TestCase, Config) ->
  ct:pal("BEGIN: ~p", [TestCase]),
  process_flag(trap_exit,true),
  WS = [proplists:get_value(priv_dir, Config), TestCase, "project"],
  CfgDir = [proplists:get_value(priv_dir, Config), TestCase, "config"],
  ResDir = [proplists:get_value(priv_dir, Config), TestCase, "result"],
  ok = application:set_env(ergo, config_dir, CfgDir, [{persistent, true}]),
  application:start(crypto),
  application:start(ergo),
  [{result, ResDir}, {config, CfgDir}, {workspace, WS} | Config].

end_per_testcase(TestCase, _Config) ->
  ct:pal("END: ~p", [TestCase]),
  application:stop(ergo),
  application:stop(mnesia),
  application:stop(crypto),
  flush_messages(),
  ok.

groups() ->
  [].

all() ->
  [root_task, two_tasks, child_project, invalid_task, missing_script, disclaimed_production].

%%--
%% HELPERS
%%
%%

flush_messages() ->
  receive
    Msg -> ct:pal("Flush message: ~p", [Msg])
  after
    0 -> ct:pal("No more messages",[])
  end.

copy_test_project(Config, TestSub) ->
  copy_test_project(Config, TestSub, "project", "config", "result").

copy_test_project(Config, TestSub, Proj, Conf, Res) ->
  DataDir = proplists:get_value(data_dir, Config),
  PrivDir = proplists:get_value(priv_dir, Config),
  application:set_env(ergo, mnesia_dir, filename:flatten([PrivDir, Conf, "/storage"]), [{persistent, true}]),
  [copy_dir([DataDir, TestSub, '/', SubDir], [PrivDir, TestSub, '/', SubDir]) || SubDir <- [Proj, Conf, Res]].


-include_lib("kernel/include/file.hrl").
copy_dir(Source, Destination) ->
  mkdir(Destination),
  dir_recurse(Source,
              fun(directory, Path) ->
                  mkdir([Destination,Path]) ;
                 (_Type, Path) -> copy_file([Source,Path], [Destination,Path])
              end).

mkdir(Destination) ->
  case file:make_dir(Destination) of
    ok -> ok;
    {error, eexist} -> ok;
    Error -> throw({error, Error, [Destination]})
  end.

copy_file(Source, Dest) ->
  file:copy(Source, Dest),
  {ok, FileInfo} = file:read_file_info(Source),
  file:write_file_info(Dest, FileInfo).


match_dir(Reference, Test) ->
  ct:pal("Comparing ~p to ~p", [filename:flatten(Path) || Path <- [Reference, Test]]),
  dir_recurse(Reference,
              fun(directory, _Path) -> ok;
                 (_Type, Path) -> match_file(Reference, Test, Path)
              end).

match_file(Reference, Test, Path) ->
  ct:pal("Checking: ~p", [filename:flatten(['.'|Path])]),
  RefHash = digest([Reference, Path]),
  case digest([Test, Path]) of
    RefHash -> ok;
    _ -> throw({fail, {nomatch, Path}})
  end.


digest(Path) ->
  {ok, Io} = file:open(Path, [read, raw, binary]),
  HashContext = crypto:hash_init(sha),
  hash_file(Io, HashContext).

hash_file(Io, Context) ->
  case file:read(Io, 4096) of
    {ok, Chunk} -> hash_file(Io, crypto:hash_update(Context, Chunk));
    eof -> crypto:hash_final(Context)
  end.


dir_recurse(Dir, Fun) ->
  dir_recurse(Dir, [], Fun).

dir_recurse(Dir, Rel, Fun) ->
  {ok, Files} = file:list_dir([Dir, Rel]),
  lists:foreach(fun(Path) ->
                    FileInfo = file:read_file_info([Dir, Rel, '/', Path]),
                    dir_recurse(Dir, [Rel, '/', Path], Fun, FileInfo)
                end,
                Files).

dir_recurse(Dir, Path, _Fun, {error,Reason}) ->
  throw({Reason, [Dir, Path]});
dir_recurse(Dir,  Path, Fun, {ok, #file_info{type=directory}}) ->
  Fun(directory, Path),
  dir_recurse(Dir, Path, Fun);
dir_recurse(_Dir, Path, Fun, {ok, #file_info{type=Type}}) when Type =:= regular; Type =:= symlink ->
  Fun(Type, Path).




%%--------------------------------------------------------------------
%% TEST CASES
%%--------------------------------------------------------------------
%%
root_task() ->
  [].
root_task(Config) ->
  Workspace = [proplists:get_value(priv_dir, Config), "root_task/project"],
  ergo:watch(Workspace),
  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/root">>]}]),
  ergo_api:wait_on_build(Workspace, Id),
  match_dir([proplists:get_value(priv_dir, Config), "root_task/result"], Workspace),
  ok.

two_tasks() ->
  [].
two_tasks(Config) ->
  Workspace = [proplists:get_value(priv_dir, Config), "two_tasks/project"],
  ergo:watch(Workspace),

  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id),
  match_dir([proplists:get_value(priv_dir, Config), "two_tasks/result"], Workspace),

  {ok, {build_id, Id2}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id2),
  match_dir([proplists:get_value(priv_dir, Config), "two_tasks/result"], Workspace),
  {ok, AllReqs} = ergo_cli:query(Workspace, <<"ergo-query">>, ["--type", "all", "tasks/two"]),
  SortedAll = lists:sort(AllReqs),

  ExpectedAll = lists:sort([
                            "tasks/two", "tasks/one", "tasks/bootstrap", "in.txt", "middle.txt"
                           ]),
  ct:pal("Sorted all requirements: ~n~p~n~p", [SortedAll, ExpectedAll]),
  ExpectedAll = SortedAll,

  {ok, LeafReqs} = ergo_cli:query(Workspace, <<"ergo-query">>, ["--type=leaves", "tasks/two"]),
  SortedLeaves = lists:sort(LeafReqs),
  ExpectedLeaves = lists:sort([
                               "tasks/two", "tasks/one","tasks/bootstrap","in.txt"
                              ]),
  ct:pal("Leaf reqs: ~n~p~n~p", [SortedLeaves,ExpectedLeaves]),
  ExpectedLeaves = SortedLeaves,

  ok.

child_project() ->
  [].
child_project(Config) ->
  Workspace = [proplists:get_value(priv_dir, Config), "child_project/project"],
  ergo:watch(Workspace),

  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/three">>]}]),
  ergo_api:wait_on_build(Workspace, Id),
  match_dir([proplists:get_value(priv_dir, Config), "child_project/result"], Workspace),

  {ok, {build_id, Id2}} = ergo:run_build(Workspace, [{task, [<<"tasks/three">>]}]),
  ergo_api:wait_on_build(Workspace, Id2),
  match_dir([proplists:get_value(priv_dir, Config), "child_project/result"], Workspace),

  ok.

invalid_task() ->
  [].
invalid_task(Config) ->
  PrivDir = proplists:get_value(priv_dir, Config),
  Workspace = [PrivDir, "invalid_task/project"],
  ergo:watch(Workspace),
  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id),

  %XXX build should fail, without change to project...
  %match_dir([PrivDir, "invalid_task/project"], Workspace),
  %fix it...
  copy_file([PrivDir, "invalid_task/fixed/tasks/two"], [PrivDir, "invalid_task/project/tasks/two"]),
  ct:pal("Fixed build tasks - re-running"),
  %and try again
  {ok, {build_id, Id2}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id2),
  match_dir([PrivDir, "invalid_task/result"], Workspace),
  ok.

missing_script() ->
  [].
missing_script(Config) ->
  PrivDir = proplists:get_value(priv_dir, Config),
  Workspace = [PrivDir, "missing_script/project"],
  ergo:watch(Workspace),
  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id),

  %XXX build should fail, without change to project...
  %match_dir([PrivDir, "missing_script/project"], Workspace),
  %fix it...
  copy_file([PrivDir, "missing_script/fixed/tasks/one"], [PrivDir, "missing_script/project/tasks/one"]),
  ct:pal("Fixed build tasks - re-running"),
  %and try again
  {ok, {build_id, Id2}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id2),
  match_dir([PrivDir, "missing_script/result"], Workspace),
  ok.

disclaimed_production() ->
  [].
disclaimed_production(Config) ->
  PrivDir = proplists:get_value(priv_dir, Config),
  Workspace = [PrivDir, "disclaimed_production/project"],
  ergo:watch(Workspace),
  {ok, {build_id, Id}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id),

  %XXX build should fail, without change to project...
  %match_dir([PrivDir, "disclaimed_production/project"], Workspace),
  %fix it...
  copy_file([PrivDir, "disclaimed_production/fixed/tasks/two"], [PrivDir, "disclaimed_production/project/tasks/two"]),
  ct:pal("Fixed build tasks - re-running"),
  %and try again
  {ok, {build_id, Id2}} = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo_api:wait_on_build(Workspace, Id2),
  match_dir([PrivDir, "disclaimed_production/result"], Workspace),
  ok.





%%% Needed test cases:
%%% * Failed build
%%% * Empty config
%%% * Missing task file
%%% * Graph contradiction (known issue)
%%% * Disclaimer (handled already?)
%%%
%%% Variations on two-task
%%% * file-file dep (i.e. out.txt -> in.txt)
%%% * more specific rule file e.g. "ergo-dep -af tasks/who-makes middle.txt"
%%%
%%% Two task variants of subsequent runs
%%% * w/o changes
%%% * in.txt changed
%%% * tasks/one changed
%%% * tasks/two changed
