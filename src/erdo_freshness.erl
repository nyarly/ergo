-module(erdo_freshness).
-export([start/0, file_digest/2, store/4, check/3]).

-include_lib("kernel/include/file.hrl").

-record(erdo_task_cache, {task_name, dependencies = [], products = []}).
-record(digest, {filename, digest}).
-record(erdo_cached_digest, {filename, mtime, digest}).

-define(CHUNK_SIZE, 4096).

%% @spec:	start_link() -> {ok,pid()}.
%% @doc:	Starts up Mnesia, waits for tables
%% @end
-spec(start() -> {ok,pid()}).
start() ->
  ok = create_schema(),
  ok = start_mnesia(),
  ok = create_tables(),
  ok = mnesia:wait_for_tables([erdo_task_cache, erdo_cached_digest], 10000),
  ok.

file_digest(Root, Path) ->
  digest_file(Root, Path).

-spec(store(erdo:taskname(), file:name_all(), [file:name_all()], [file:name_all()]) -> ok).
store(Task, Root, Deps, Prods) ->
  mnesia:transaction(fun() ->
        mnesia:write(#erdo_task_cache{
            task_name=Task,
            dependencies=digest_list(Root, Deps),
            products=digest_list(Root, Prods)
          })
    end).

check(Task, Root, Deps) ->
  case mnesia:transaction(fun() ->
          mnesia:match_object(#erdo_task_cache{
              task_name=Task,
              dependencies=digest_list(Root, Deps),
              products='_'
            }) end)
    of
    {atomic, []} -> miss;
    {atomic, [Match]} -> check_products(Root, Match);
    {atomic, [Match|_Rest]} -> check_products(Root, Match)
  end.

digest_list(Root, Files) ->
  lists:sort([ #digest{filename=Path,digest=file_digest(Root,Path)} || Path <- Files ]).

check_products(Root, CacheMatch) ->
  case lists:all(
      fun(ProdDigest) -> file_digest(Root, ProdDigest#digest.filename) =:= ProdDigest#digest.digest end,
      CacheMatch#erdo_task_cache.products
    ) of
    true -> hit;
    _ -> miss
  end.


create_schema() ->
  case mnesia:create_schema([node()]) of
    ok -> ok;
    {error, {_Node, {already_exists, _Node}}} -> ok;
    Error -> Error
  end.

start_mnesia() ->
  mnesia:start().

create_tables() ->
  ok = create_table(erdo_task_cache, bag, record_info(fields, erdo_task_cache)),
  ok = create_table(erdo_cached_digest, set, record_info(fields, erdo_cached_digest)),
  ok.

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

digest_file(Root, Path) ->
  {ok, Io, _FullName} = file:path_open([Root], Path, [read, raw, binary]),
  HashContext = crypto:hash_init(sha),
  Digest = hash_file(Io, HashContext),
  #digest{filename=Path, digest=Digest}.

hash_file(Io, Context) ->
  case file:read(Io, ?CHUNK_SIZE) of
    {ok, Chunk} -> hash_file(Io, crypto:hash_update(Context, Chunk));
    eof -> crypto:hash_final(Context)
  end.
