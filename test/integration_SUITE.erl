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
  %{ok, _} = dbg:tpl(ergo_task,record_and_report, []),
  %{ok, _} = dbg:tpl(ergo_build,handle_event, []),
  {ok, _} = dbg:tpl(ergo_freshness,digest_list, [{'_',[],[{return_trace}]}]),
  dbg:p(all,c),
  DataDir = proplists:get_value(data_dir, Config),
  PrivDir = proplists:get_value(priv_dir, Config),
  copy_dir(DataDir, PrivDir),
  Config.
end_per_suite(_Config) ->
  ok.
init_per_group(_GroupName, Config) ->
  Config.
end_per_group(_GroupName, _Config) ->
  ok.
init_per_testcase(TestCase, Config) ->
  ct:pal("BEGIN: ~p", [TestCase]),
  application:start(crypto),
  application:start(mnesia),
  application:start(ergo),
  Config.
end_per_testcase(_TestCase, _Config) ->
  application:stop(ergo),
  application:stop(mnesia),
  application:stop(crypto),
  ok.
groups() ->
  [].
all() ->
  [root_task, two_tasks].

%%--
%% HELPERS
%%
%%

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
                 (_Type, Path) ->
                  ct:pal("Checking: ~p", [filename:flatten(['.'|Path])]),
                  RefHash = digest([Reference, Path]),
                  case digest([Test, Path]) of
                    RefHash -> ok;
                    _ -> throw({fail, {nomatch, Path}})
                  end
              end).

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
dir_recurse(Dir, Path, Fun, {ok, #file_info{type=directory}}) ->
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
  Id = ergo:run_build(Workspace, [{task, [<<"tasks/root">>]}]),
  ergo:wait_on_build(Workspace, Id),
  match_dir([proplists:get_value(priv_dir, Config), "root_task/result"], Workspace),
  ok.

two_tasks() ->
  [].
two_tasks(Config) ->
  Workspace = [proplists:get_value(priv_dir, Config), "two_tasks/project"],
  Id = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo:wait_on_build(Workspace, Id),
  match_dir([proplists:get_value(priv_dir, Config), "two_tasks/result"], Workspace),
  Id2 = ergo:run_build(Workspace, [{task, [<<"tasks/two">>]}]),
  ergo:wait_on_build(Workspace, Id2),
  ok.

%%% Needed test cases:
%%% * Failed build
%%% * Empty config
%%% * Missing task file
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
