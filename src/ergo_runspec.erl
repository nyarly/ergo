-module (ergo_runspec).

-export([ add/2, item/2, reduce/2 ]).

-type predecessors() :: [ ergo:task_name() ].
-type item() :: {ergo:task_name(), predecessors() }.
-type spec() :: [item()].

-spec(add(spec(), item()) -> spec()).
add(Spec, Item) ->
  [Item | Spec].

-spec(item(ergo:task_name(), predecessors()) -> item()).
item(Task, Preq) ->
  {Task, Preq}.

-spec(reduce(ergo:task_name(), spec()) -> spec()).
reduce(Task, Spec) ->
  [ {TN, Deps -- [Task]} || {TN, Deps} <- Spec, TN =/= Task].
