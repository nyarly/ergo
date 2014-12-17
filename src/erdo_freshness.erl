-module(erdo_freshness).
-export([start/0, create_tables/0, file_digest/2, store/4, check/3, elidability/2]).

-include_lib("kernel/include/file.hrl").

-record(erdo_task_cache, {task_name, dependencies = [], products = []}).
-record(erdo_task_elidibility, {task_name}).
-record(erdo_cached_digest, {filename, mtime, digest}).
-record(digest, {filename, digest}).

-define(CHUNK_SIZE, 4096).

%% @spec:	start_link() -> {ok,pid()}.
%% @doc:	Starts up Mnesia, waits for tables
%% @end
-spec(start() -> {ok,pid()}).
start() ->
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

-spec(check(erdo:taskname(), file:name_all(), [file:name_all()]) -> hit | miss).
check(Task, Root, Deps) ->
  case mnesia:transaction(
         fun() ->
             case mnesia:read(erdo_task_elidibility, Task) of
               [] -> [];
               _ -> mnesia:match_object(#erdo_task_cache{
                                    task_name=Task,
                                    dependencies=digest_list(Root, Deps),
                                    products='_'
                                   })
                    end
         end)
    of
    {atomic, []} -> miss;
    {atomic, [Match]} -> check_products(Root, Match);
    {atomic, [Match|_Rest]} -> check_products(Root, Match)
  end.

elidability(Task, false) ->
  mnesia:transaction(
    fun() ->
        mnesia:delete({erdo_task_elidibility, Task})
    end);
elidability(Task, true) ->
  mnesia:transaction(
    fun() ->
        mnesia:write(#erdo_task_elidibility{ task_name=Task })
    end).

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

create_tables() ->
  ok = erdo_storage:create_table(erdo_task_cache, bag, record_info(fields, erdo_task_cache)),
  ok = erdo_storage:create_table(erdo_cached_digest, set, record_info(fields, erdo_cached_digest)),
  [erdo_task_cache, erdo_cached_digest].

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
