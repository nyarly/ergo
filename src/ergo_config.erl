%%% @author  Judson Lester nyarly@gmail.com
%%% @copyright (C) 2015, Judson Lester. All Rights Reserved.
%%% @doc
%%%		Wraps the configuration stuff of Ergo
%%% @end
%%% Created :  Mon Mar 23 11:20:07 2015 by Judson Lester
-module(ergo_config).

-export([node_name/0, mnesia_dir/0]).

main_config_dir()->
  main_config_dir(application:get_env(config_dir)).

main_config_dir(undefined) ->
  filename:join([os:getenv("HOME"), ".config/ergo"]);
main_config_dir({ok, FromAppEnv}) ->
  FromAppEnv.

node_name() ->
  node_name(file:read_file(node_name_path())).

node_name_path() ->
  filename:join([main_config_dir(), "node_name"]).

node_name({ok, Bin}) ->
  {match, [Name]} = re:run(Bin, <<"\\A\\s*(\\S*)\\s*\\z">>, [{capture, [1], binary}]),
  binary_to_atom(Name, latin1);
node_name({error, enoent}) ->
  ergo.

mnesia_dir() ->
  filename:join([main_config_dir(), "ergo_mnesia"]).
