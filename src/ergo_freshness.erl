-module(ergo_freshness).
-export([create_tables/0, file_digest/2, store/2, check/2]).

-include_lib("kernel/include/file.hrl").

-record(ergo_task_cache, {task_name, dependencies = [], products = []}).
-record(ergo_task_metadata, {task_and_name :: {ergo:workspace_name(), ergo:taskname(), atom()}, value :: term()}).
-record(ergo_cached_digest, {filename, mtime, digest}).
-record(digest, {filename, digest}).

-define(CHUNK_SIZE, 4096).

file_digest(Root, Path) ->
  digest_of_file(file:path_open([Root], Path, [read, raw, binary])).

store(Root, Task) ->
  store(Root, Task, task_deps(Root, Task), task_products(Root, Task)).

check(Root, Task) ->
  check(Root, Task, task_deps(Root, Task), task_products(Root, Task)).

create_tables() ->
  ok = ergo_storage:create_table(ergo_task_cache, bag, record_info(fields, ergo_task_cache)),
  ok = ergo_storage:create_table(ergo_cached_digest, set, record_info(fields, ergo_cached_digest)),
  ok = ergo_storage:create_table(ergo_task_metadata, set, record_info(fields, ergo_task_metadata)),
  [ergo_task_cache, ergo_cached_digest, ergo_task_metadata].


%%%%%%%%


task_deps(Workspace, Task) ->
  [TaskFile | _Args] = Task,
  [TaskFile | ergo_graphs:get_dependencies(Workspace, {task, Task})].

task_products(Workspace, Task) ->
  ergo_graphs:get_products(Workspace, {task, Task}).


-spec(check(ergo:workspace_name(), ergo:taskname(), [file:name_all()], [file:name_all()]) -> hit | miss).
check(Root, Task, Deps, Prods) ->
  check(freshness_policy(Root, Task, Deps, Prods),
        Root, Task, Deps, Prods).

freshness_for_task(Root, Task, Default) ->
  proplists:get_value(fresh, ergo_graphs:get_metadata(Root, {task, Task}), Default).

freshness_for_file(Root, TaskFresh, File) ->
  proplists:get_value(fresh, ergo_graphs:get_metadata(Root, {produced, File}), TaskFresh).

freshness_policy(Root, Task, Deps, Prods) ->
  freshness_policy(Root, Task, Deps, Prods, freshness_for_task(Root, Task, digest), digest).

-type policy() :: digest | never.
-type file_policy() :: policy().
-type task_policy() :: digest.

-spec(freshness_policy(ergo:workspace_name(), ergo:taskname(), [file:name_all()], [file:name_all()], file_policy(), task_policy()) -> policy()).
%freshness_policy(_, _, _, _, _, never) ->
%  never;
freshness_policy(_, _, [], [], _, digest) ->
  digest;
freshness_policy(Root, Task, [], [File | Prods], TaskFresh, digest) ->
  freshness_policy(Root, Task, [], Prods, TaskFresh, freshness_for_file(Root, TaskFresh, File));
freshness_policy(Root, Task, [File | Deps], Prods, TaskFresh, digest) ->
  freshness_policy(Root, Task, Deps, Prods, TaskFresh, freshness_for_file(Root, TaskFresh, File)).

-spec(store(ergo:workspace_name(), ergo:taskname(), [file:name_all()], [file:name_all()]) -> ok).
store(Root, Task, Deps, Prods) ->
  {atomic, _} =
  mnesia:transaction(
    fun() ->
        mnesia:write(#ergo_task_cache{
                        task_name=Task,
                        dependencies=without_missing(digest_list(Root, Deps)),
                        products=without_missing(digest_list(Root, Prods))
                       })
    end),
  ok.

%check(never, _,_,_,_) ->
%  miss;
check(digest, Root, Task, Deps, Prods) ->
  {atomic, Matches} =
  mnesia:transaction(
    fun() ->
        mnesia:match_object(#ergo_task_cache{
                               task_name=Task,
                               dependencies=digest_list(Root, Deps),
                               products=digest_list(Root, Prods)
                              })
    end),
  check_matches(digest, Matches).

check_matches(digest, []) -> miss;
check_matches(digest, _)  -> hit.

without_missing(DigestList) ->
  lists:filter(fun digest_present/1, DigestList).

digest_present(#digest{digest=missing}) ->
  false;
digest_present(_) ->
  true.

digest_list(Root, Files) ->
  lists:sort([ #digest{filename=Path,digest=file_digest(Root,Path)} || Path <- Files ]).

digest_of_file({error, enoent})->
  missing;
digest_of_file({ok, Io, _})->
  hash_file(Io).

hash_file(Io) ->
  hash_file(Io, crypto:hash_init(sha)).

hash_file(Io, Context) ->
  case file:read(Io, ?CHUNK_SIZE) of
    {ok, Chunk} -> hash_file(Io, crypto:hash_update(Context, Chunk));
    eof -> crypto:hash_final(Context)
  end.
