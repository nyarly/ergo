-module(ergo_freshness).
-export([create_tables/0, file_digest/2, store/4, check/3, elidability/3]).

-include_lib("kernel/include/file.hrl").

-record(ergo_task_cache, {task_name, dependencies = [], products = []}).
-record(ergo_task_metadata, {task_and_name :: {ergo:workspace_name(), ergo:taskname(), atom()}, value :: term()}).
-record(ergo_cached_digest, {filename, mtime, digest}).
-record(digest, {filename, digest}).

-define(CHUNK_SIZE, 4096).

file_digest(Root, Path) ->
  {ok, Io, _FullName} = file:path_open([Root], Path, [read, raw, binary]),
  HashContext = crypto:hash_init(sha),
  Digest = hash_file(Io, HashContext),
  #digest{filename=Path, digest=Digest}.


-spec(store(ergo:taskname(), ergo:workspace_name(), [file:name_all()], [file:name_all()]) -> ok).
store(Task, Root, Deps, Prods) ->
  ct:pal("fresh:store(~p,~p,~p,~p)", [Task, Root, Deps, Prods]),
  [Taskfile | _TaskArgs] = Task,
  {atomic, _} = mnesia:transaction(fun() ->
        mnesia:write(#ergo_task_cache{
            task_name=Task,
            dependencies=digest_list(Root, [Taskfile | Deps]),
            products=digest_list(Root, Prods)
          })
    end),
  ok.

-spec(check(ergo:taskname(), ergo:workspace_name(), [file:name_all()]) -> hit | miss).
check(Task, Root, Deps) ->
  [Taskfile | _TaskArgs] = Task,
  case mnesia:transaction(
         fun() ->
             case get_metadata(Root, Task, elides, true) of
               false -> [];
               _ -> mnesia:match_object(#ergo_task_cache{
                                    task_name=Task,
                                    dependencies=digest_list(Root, [Taskfile | Deps]),
                                    products='_'
                                   })
                    end
         end)
    of
    {atomic, []} -> miss;
    {atomic, [Match]} -> check_products(Root, Match);
    {atomic, [Match|_Rest]} -> check_products(Root, Match)
  end.

elidability(Root, Task, Value) ->
  set_metadata(Root, Task, elides, Value).

digest_list(Root, Files) ->
  lists:sort([ #digest{filename=Path,digest=file_digest(Root,Path)} || Path <- Files ]).

check_products(Root, CacheMatch) ->
  case lists:all(
      fun(ProdDigest) -> file_digest(Root, ProdDigest#digest.filename) =:= ProdDigest#digest.digest end,
      CacheMatch#ergo_task_cache.products
    ) of
    true -> hit;
    _ -> miss
  end.

set_metadata(Root, Task, Name, Value) ->
  {atomic, _} = mnesia:transaction(
    fun() ->
        mnesia:write(#ergo_task_metadata{ task_and_name={Root,Task,Name}, value=Value})
    end), ok.

get_metadata(Root, Task, Name, Default) ->
  mnesia:transaction( fun() ->
                          case mnesia:read(ergo_task_metadata, {Root, Task, Name}) of
                            [] -> Default;
                            [#ergo_task_metadata{ value=Value }] -> Value
                          end
                      end).




create_tables() ->
  ok = ergo_storage:create_table(ergo_task_cache, bag, record_info(fields, ergo_task_cache)),
  ok = ergo_storage:create_table(ergo_cached_digest, set, record_info(fields, ergo_cached_digest)),
  ok = ergo_storage:create_table(ergo_task_metadata, set, record_info(fields, ergo_task_metadata)),
  [ergo_task_cache, ergo_cached_digest, ergo_task_metadata].

hash_file(Io, Context) ->
  case file:read(Io, ?CHUNK_SIZE) of
    {ok, Chunk} -> hash_file(Io, crypto:hash_update(Context, Chunk));
    eof -> crypto:hash_final(Context)
  end.
