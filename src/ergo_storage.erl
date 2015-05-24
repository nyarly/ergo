-module(ergo_storage).
-export([start/0, create_table/3]).

%% @spec:	start() -> {ok}.
%% @doc:	Starts up Mnesia, waits for tables
%% @end
-spec(start() -> ok).
start() ->
  _ = mnesia:stop(), % already started somehow?
  setup_storage(),
  ok = create_schema(),
  ok = start_mnesia(),
  TableList = lists:flatten([ergo_freshness:create_tables()]),
  ok = mnesia:wait_for_tables(TableList, 10000),
  ok.

setup_storage() ->
  MnesiaDir = ergo_config:mnesia_dir(),
  io:format("Ensuring that ~p exists.~n", [MnesiaDir]),
  filelib:ensure_dir(MnesiaDir),
  set_storage_dir(MnesiaDir).

set_storage_dir(Dir) ->
  application:set_env(mnesia, dir, Dir).

create_schema() ->
  case mnesia:create_schema([node()]) of
    ok -> ok;
    {error, {_Node, {already_exists, _Node}}} -> ok;
    Error -> Error
  end.

create_table(Name, Type, Attrs) ->
  case mnesia:create_table(Name,
      [ {attributes, Attrs},
        {type, Type},
        {disc_copies, [node()]}
      ]) of
    {atomic, ok} -> ok;
    {aborted, {already_exists, Name}} -> ok;
    Error -> Error
  end.

start_mnesia() ->
  mnesia:start().
