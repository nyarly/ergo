-module (ergo_runspec).

-export([ add/2, item/2, reduce/2, eligible_batch/1 ]).

-define(NOTEST, true).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type predecessors() :: [ ergo:taskname() ].
-type item() :: {ergo:taskname(), predecessors() }.
-type spec() :: [item()].

-spec(add(spec(), item()) -> spec()).
add(Spec, Item) ->
  [Item | Spec].

-spec(item(ergo:taskname(), predecessors()) -> item()).
item(Task, Preq) ->
  {Task, Preq}.

-spec(reduce(ergo:taskname(), spec()) -> spec()).
reduce(Task, Spec) ->
  [ {TN, Deps -- [Task]} || {TN, Deps} <- Spec ].

-spec eligible_batch(Spec::spec()) -> {[ergo:taskname()], spec()}.
eligible_batch(Spec) ->
  lists:foldl(fun filter_batch/2, {[],[]}, Spec).

filter_batch({Task, []}, {Tasks, Spec}) ->
  {[Task | Tasks], Spec};
filter_batch(Item, {Tasks, Spec}) ->
  {Tasks, [Item | Spec]}.



-ifdef(TEST).
module_test_() ->
  % convenience variables
  {
    foreach,
    fun() ->  %setup
      dbg:tracer(),
      dbg:p(all, c),
      ok
    end,
    fun(_State) -> %teardown
      dbg:ctp(), dbg:p(all, clear),
      ok
  end,
  [
   fun(_) ->
     {"Eligible tasks",
     ?_test(begin
              {Ready, Spec} = eligible_batch([{ready, []}, {not_ready, [ready]}, {also_not, [other]}]),
              ?assertEqual([ready], Ready),
              ?assertEqual(lists:sort([{not_ready, [ready]}, {also_not,[other]}]), lists:sort(Spec))
       end)
     }
   end,

   fun(_) ->
       {"Spec reduction should remove a completed task",
        ?_test(begin
                 Reduced = reduce(done_task, [{done_task, []}, {other_task, [done_task]}, {last_task, [other_task, done_task]}]),
                 ?assertMatch( Reduced, [{done_task, []}, {other_task, []}, {last_task, [other_task]}])
               end)
       }
   end
  ]}.
-endif.
