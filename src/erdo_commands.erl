-module(erdo_commands).
-include_lib("eunit/include/eunit.hrl").

%% API.
-export([run/1, requires/2, provides/2, skip/1, together/2, order/2]).

%% API.

%% @doc:	Begin an erdo build run
%% @spec:	run(targets::[target()] ) -> command_result().
%% @end
-spec(run([erdo:target()]) -> erdo:command_result() ).
run(targets) ->
  erdo_events:build_requested(targets).

%% @spec:	requires(product::erdo:produced(), dependency::erdo:produced()) -> erdo:command_result().
%% @doc:	Declares that the contents of [product] depend on those of [dependency]
%% @end
-spec(requires(erdo:produced(), erdo:produced()) -> erdo:command_result()).
requires(product, dependency) ->
  erdo_events:requirement_noted(product, dependency).

%% @spec:	provides(task::task(), product::produced()) -> erdo:command_result().
%% @doc:	Declares that [task] produces [product]
%% @end
-spec(provides(erdo:task(), erdo:produced()) -> erdo:command_result()).
provides(task, product) ->
  erdo_events:production_noted(task, product).

%% @spec:	skip(task::erdo:task()) -> erdo:command_result().
%% @doc:	The [task] has determined that it need not be run
%% @end
-spec(skip(erdo:task()) -> erdo:command_result()).
skip(task) ->
  erdo_events:task_skipped().

%% @spec:	together(first::erdo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	Whenever [first] is run, [second] should also run.
%% @end
-spec(together(erdo:task(), erdo:task()) -> erdo:command_result()).
together(first, second) ->
  erdo_events:tasks_joint(first, second).

%% @spec:	order(first::erdo:task(), second::erdo:task()) -> erdo:command_result().
%% @doc:	When [first] and [second] would both be run,
%%              first precedes second
%% @end
-spec(order(erdo:task(), erdo:task()) -> erdo:command_result()).
order(first, second) ->
  erdo_events:tasks_ordered(first,second).
