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
   {timetrap,{minutes,10}},
   {create_priv_dir, auto_per_tc}
  ].
init_per_suite(Config) ->
  Config.
end_per_suite(_Config) ->
  ok.
init_per_group(_GroupName, Config) ->
  Config.
end_per_group(_GroupName, _Config) ->
  ok.
init_per_testcase(_TestCase, Config) ->
  copy_test_project(Config, "test1", "project", "config", "result"),
  Config.
end_per_testcase(_TestCase, _Config) ->
  ok.
groups() ->
  [].
all() ->
  [root_task].

%%--
%% HELPERS
%%
%%

copy_test_project(Config, TestSub, Proj, Conf, Res) ->
  DataDir = proplists:get_value(data_dir, Config),
  PrivDir = proplists:get_value(priv_dir, Config),
  [copy_dir([DataDir, TestSub, '/', SubDir], [PrivDir, SubDir]) || SubDir <- [Proj, Conf, Res]].


-include_lib("kernel/include/file.hrl").
copy_dir(Source, Destination) ->
  mkdir(Destination),
  dir_recurse(Source,
              fun(directory, Path) ->
                  mkdir([Destination,Path]) ;
                 (_Type, Path) -> file:copy([Source,Path], [Destination,Path])
              end).

mkdir(Destination) ->
  case file:make_dir(Destination) of
    ok -> ok;
    {error, eexist} -> ok;
    Error -> throw({error, Error, [Destination]})
  end.


match_dir(Reference, Test) ->
  dir_recurse(Reference,
              fun(directory, _Path) -> ok;
                 (_Type, Path) ->
                  RefHash = digest([Reference, Path]),
                  RefHash = digest([Test, Path])
              end).

digest(Path) ->
  {ok, Io, _FullName} = file:open(Path, [read, raw, binary]),
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
  Workspace = [proplists:get_value(priv_dir, Config), "project"],
  Id = ergo:run_build(Workspace, [{task, [<<"tasks/root">>]}]),
  ergo:wait_for_build(Workspace, Id),
  ok.
