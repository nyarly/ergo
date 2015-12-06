-module (ergo_cli).
-export ([tasks/5, taskfile/5, files/5, invalid/5, query/3, query/4]).

tasks(Workspace, ReporterId, CmdName, Ifs, CommandLine) ->
  command_parse( Ifs, CmdName, CommandLine, run_tasks(spec), run_tasks(usage),
                 fun(Options, Args) ->
                     run_tasks(Workspace, ReporterId, Options, Args)
                 end).

taskfile(Workspace, ReporterId, CmdName, Ifs, CommandLine) ->
  command_parse( Ifs, CmdName, CommandLine, run_taskfile(spec), run_taskfile(usage),
                 fun(Options, Args) ->
                     run_taskfile(Workspace, ReporterId, Options, Args)
                 end).

files(Workspace, ReporterId, CmdName, Ifs, CommandLine) ->
  command_parse( Ifs, CmdName, CommandLine, run_files(spec), run_files(usage),
                 fun(Options, Args) ->
                     run_files(Workspace, ReporterId, Options, Args)
                 end).

invalid(Workspace, ReporterId, CmdName, Ifs, CommandLine) ->
  command_parse( Ifs, CmdName, CommandLine, run_invalid(spec), run_invalid(usage),
                 fun(Options, Args) ->
                     run_invalid(Workspace, ReporterId, Options, Args)
                 end).

query(Workspace, CmdName, CommandTokens) ->
  command_parse( CmdName, CommandTokens, run_query(spec), run_query(usage),
                 fun(Options, Args) ->
                     run_query(Workspace, Options, Args)
                 end).

query(Workspace, CmdName, Ifs, CommandLine) ->
  query(Workspace, CmdName, tokenize(CommandLine, Ifs)).

tokenize(CommandLine, Ifs) ->
  string:tokens(CommandLine, Ifs).

command_parse(Ifs, CmdName, CommandLine, OptSpec, UsageExtra, Fun) ->
  command_parse(CmdName, tokenize(CommandLine, Ifs), OptSpec, UsageExtra, Fun).

command_parse(CmdName, CommandTokens, OptSpec, UsageExtra, Fun) ->
  case ergo_getopt:parse([{help, $h, "help", boolean, "Print this help text"}| OptSpec], CommandTokens) of
    {ok, {Options, Args}} ->
      case proplists:get_bool(help, Options) of
        true ->
          {CmdTail, OptsTail} = UsageExtra, usage_string(CmdName, OptSpec, CmdTail, OptsTail);
        _ -> Fun(Options, Args)
      end;
    {error, _} -> {CmdTail, OptsTail} = UsageExtra, usage_string(CmdName, OptSpec, CmdTail, OptsTail)
  end.

run_query(spec) ->
  [
   {type, $t, "type", atom, "Query type, required. Accepted values are \"all\" or \"leaf\""}
  ];
run_query(usage) ->
  {
   { "TARGET",
     [{"TARGET", "all arguments are treated as a task or file target to query"}]
   }
  }.

run_query(Workspace, Options, Args) ->
  handle_query(Workspace, proplists:get_value(type, Options), [list_to_binary(Arg) || Arg <- Args]).

handle_query(Workspace, all, Targets) ->
  ergo_graphs:all_transitive_requirements(Workspace, [{task, Targets}]);
handle_query(Workspace, leaves, Targets) ->
  ergo_graphs:leaf_transitive_requirements(Workspace, [{task, Targets}]);
handle_query(_, UnkType, _) ->
  {error, {unknown_query_type, UnkType}}.


run_tasks(spec) ->
  [
   {also, $a, "also", undefined, "If this task is run, TASK should be run 'also`"},
   {'when', $w, "when", undefined, "This task should be run 'when' TASK is"},
   {preceed, $p, "preceed", undefined, "This task precedes TASK"},
   {follow, $f, "follow", undefined, "This task follows TASK"}
  ];
run_tasks(usage) ->
  {  "TASK",
   [{"TASK", "all arguments are treated as the task to run"}]}.
run_tasks(Workspace, ReporterId, Options, Args) ->
  SecondTask = [ list_to_binary(Part) || Part <- Args],
  maybe_cotasks(proplists:get_bool(also,  Options), proplists:get_bool('when',  Options), Workspace, ReporterId, self, SecondTask),
  maybe_deps(proplists:get_bool(preceed,  Options), proplists:get_bool(follow,  Options),Workspace, ReporterId, self, SecondTask).

run_taskfile(spec) ->
  [
   {require, $r, "requires", undefined, "The task requires the file(s)"},
   {produce, $p, "produces", undefined, "The task produces the file(s)"},
   {other, $t, "task", undefined, "The task is question is specified after the file (otherwise, all args are files for this task)"}
  ];
run_taskfile(usage) ->
  {  "FILE(s) [TASK]",
   [{"FILE(s)", "with --task: first arg is a file; without, all args are filenames"},
    {"TASK", "with --task: all arguments are used as a taskname"}]
  }.
run_taskfile(Workspace, ReporterId, Options, Args) ->
  {Files,Taskname} = case proplists:get_bool(other, Options) of
               true -> [File|Rest] = Args,
                       {[File], [list_to_binary(Part) || Part <- Rest]};
               false -> {Args, self}
             end,
  [maybe_filedep(proplists:get_bool(require,Options),proplists:get_bool(produce,Options),
                Workspace, ReporterId, Taskname, File) || File <- Files].

run_files(spec) ->
  [];
run_files(usage) ->
  {  "FIRST SECOND",
   [{"FIRST", "Required file"},
    {"SECOND", "Requiring file"} ]
  }.
run_files(Workspace, ReporterId, [], [FirstFile, SecondFile]) ->
  ergo_api:add_file_dep(Workspace, ReporterId, FirstFile, SecondFile).

%          preceed,follow
maybe_deps(true,true,_,_,_,_) ->
  {error, contradictory_preceed_follow};
maybe_deps(true,_,Workspace,Reporter,First,Second) ->
  ergo_api:add_task_seq(Workspace,Reporter,First,Second);
maybe_deps(_,true,Workspace,Reporter,First,Second) ->
  ergo_api:add_task_seq(Workspace,Reporter,Second,First);
maybe_deps(_,_,_,_,_,_) ->
  ok.

%             also,when
maybe_cotasks(true,true,Workspace,Reporter,First,Second) ->
  ergo_api:add_cotask(Workspace,Reporter,First,Second),
  ergo_api:add_cotask(Workspace,Reporter,Second,First);
maybe_cotasks(false,true,Workspace,Reporter,First,Second) ->
  ergo_api:add_cotask(Workspace,Reporter,Second,First);
maybe_cotasks(true,false,Workspace,Reporter,First,Second) ->
  ergo_api:add_cotask(Workspace,Reporter,First,Second);
maybe_cotasks(_,_,_,_,_,_) ->
  ok.

%             require,produce
maybe_filedep(true,true,_,_,_,_) ->
  {error, contradictory_require_produce};
maybe_filedep(true,false,Workspace,Reporter,First,Second) ->
  ergo_api:add_required(Workspace,Reporter,First,Second);
maybe_filedep(false,true,Workspace,Reporter,First,Second) ->
  ergo_api:add_product(Workspace,Reporter,First,Second);
maybe_filedep(false,false,_,_,_,_) ->
  ok.

run_invalid(spec) ->
  [];
run_invalid(usage) ->
  {
   "[MESSAGE]",
   [{"MESSAGE", "describing reason this task run is invalid (e.g. bad arguments)"}]
  }.

run_invalid(Workspace, ReporterId, _Options, Args) ->
  Message = case Args of
              [] -> "No message";
              M -> M
            end,
  ergo_api:invalid(Workspace, ReporterId, Message).


usage_string(ProgramName, OptSpecList, CmdLineTail, OptionsTail) ->
  io_lib:format("~ts~n~n~ts~n",
                [ unicode:characters_to_list(ergo_getopt:usage_cmd_line(ProgramName, OptSpecList, CmdLineTail)),
                  unicode:characters_to_list(ergo_getopt:usage_options(OptSpecList, OptionsTail))]).
