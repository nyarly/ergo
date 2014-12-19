-module(ergo_commands).
-include_lib("eunit/include/eunit.hrl").

%% API.
-export([run/1, requires/2, provides/2, might_skip/1, skip/1, together/2, order/2]).

%% API.

%% @doc:	Begin an ergo build run
%% @spec:	run(targets::[target()] ) -> command_result().
%% @end
-spec(run([ergo:target()]) -> erdo:command_result() ).
run(Targets) ->
  ergo_events:build_requested(Targets).

%% @spec:	requires(product::ergo:produced(), dependency::erdo:produced()) -> erdo:command_result().
%% @doc:	Declares that the contents of [product] depend on those of [dependency]
%% @end
-spec(requires(ergo:produced(), erdo:produced()) -> erdo:command_result()).
requires(Product, Dependency) ->
  ergo_events:requirement_noted(Product, Dependency).

%% @spec:	provides(task::task(), product::produced()) -> ergo:command_result().
%% @doc:	Declares that [task] produces [product]
%% @end
-spec(provides(ergo:task(), erdo:produced()) -> erdo:command_result()).
provides(Task, Product) ->
  ergo_events:production_noted(Task, Product).

%% @spec:	might_skip(Task::ergo:task()) -> erdo:command_result().
%% @doc:	The [task] might skip - it's an error to call ergo_commands:skip with
%%              a task that hasn't previously been registered as skippable
%% @end

-spec(might_skip(ergo:task()) -> erdo:command_result()).
might_skip(Task) ->
  ok.

%% @spec:	skip(task::ergo:task()) -> erdo:command_result().
%% @doc:	The [task] has determined that it need not be run
%% @end
-spec(skip(ergo:task()) -> erdo:command_result()).
skip(Task) ->
  ergo_events:task_skipped(Task).

%% @spec:	together(first::ergo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	Whenever [first] is run, [second] should also run.
%% @end
-spec(together(ergo:task(), erdo:task()) -> erdo:command_result()).
together(First, Second) ->
  ergo_events:tasks_joint(First, Second).

%% @spec:	order(first::ergo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	When [first] and [second] would both be run,
%%              first precedes second
%% @end
-spec(order(ergo:task(), erdo:task()) -> erdo:command_result()).
order(First, Second) ->
  ergo_events:tasks_ordered(First,Second).
