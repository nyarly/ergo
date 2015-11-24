-module(ergo_app).
-behaviour(application).

-export([start/2]).
-export([stop/1]).

start(_Type, _Args) ->
  {ok, _} = start_distribution(),
  ergo_storage:start(),
  ergo_sup:start_link().

stop(_State) ->
  ok.

start_distribution() ->
  _Hack = os:cmd("epmd -daemon"),  % XXX dirty hack to make sure epmd is running
  case net_kernel:start([ergo_config:node_name(), shortnames]) of
    {ok, Pid} -> {ok, Pid};
    {error, {already_started, Pid}} -> {ok, Pid};
    {error, {{already_started, Pid}, _}} -> {ok, Pid};
    {error, Error} -> {err, Error}
  end.
