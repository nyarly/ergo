-module(erdo_commands).
-include_lib("eunit/include/eunit.hrl").

%% API.
-export([run/1, requires/2, provides/2, might_skip/1, skip/1, together/2, order/2]).

%% API.

%% @doc:	Begin an erdo build run
%% @spec:	run(targets::[target()] ) -> command_result().
%% @end
-spec(run([erdo:target()]) -> erdo:command_result() ).
run(Targets) ->
  erdo_events:build_requested(Targets).

%% @spec:	requires(product::erdo:produced(), dependency::erdo:produced()) -> erdo:command_result().
%% @doc:	Declares that the contents of [product] depend on those of [dependency]
%% @end
-spec(requires(erdo:produced(), erdo:produced()) -> erdo:command_result()).
requires(Product, Dependency) ->
  erdo_events:requirement_noted(Product, Dependency).

%% @spec:	provides(task::task(), product::produced()) -> erdo:command_result().
%% @doc:	Declares that [task] produces [product]
%% @end
-spec(provides(erdo:task(), erdo:produced()) -> erdo:command_result()).
provides(Task, Product) ->
  erdo_events:production_noted(Task, Product).

%% @spec:	might_skip(Task::erdo:task()) -> erdo:command_result().
%% @doc:	The [task] might skip - it's an error to call erdo_commands:skip with
%%              a task that hasn't previously been registered as skippable
%% @end

-spec(might_skip(erdo:task()) -> erdo:command_result()).
might_skip(Task) ->
  ok.

%% @spec:	skip(task::erdo:task()) -> erdo:command_result().
%% @doc:	The [task] has determined that it need not be run
%% @end
-spec(skip(erdo:task()) -> erdo:command_result()).
skip(Task) ->
  erdo_events:task_skipped(Task).

%% @spec:	together(first::erdo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	Whenever [first] is run, [second] should also run.
%% @end
-spec(together(erdo:task(), erdo:task()) -> erdo:command_result()).
together(First, Second) ->
  erdo_events:tasks_joint(First, Second).

%% @spec:	order(first::erdo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	When [first] and [second] would both be run,
%%              first precedes second
%% @end
-spec(order(erdo:task(), erdo:task()) -> erdo:command_result()).
order(First, Second) ->
  erdo_events:tasks_ordered(First,Second).
