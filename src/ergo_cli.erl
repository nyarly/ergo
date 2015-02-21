-module (ergo_cli).
-export ([tasks/5, taskfile/5, files/5]).

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

command_parse(Ifs, CmdName, CommandLine, OptSpec, UsageExtra, Fun) ->
  case getopt:parse([{help, $h, "help", boolean, "Print this help text"}| OptSpec], string:tokens(CommandLine, Ifs)) of
    {ok, {Options, Args}} ->
      case proplists:get_bool(help, Options) of
        true ->
          {CmdTail, OptsTail} = UsageExtra, usage_string(CmdName, OptSpec, CmdTail, OptsTail);
        _ -> Fun(Options, Args)
      end;
    {error, _} -> {CmdTail, OptsTail} = UsageExtra, usage_string(CmdName, OptSpec, CmdTail, OptsTail)
  end.

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
  FirstTask = ergo_task:taskname_from_token(ReporterId),
  SecondTask = [ list_to_binary(Part) || Part <- Args],

  maybe_cotasks(proplists:get_bool(also,  Options), proplists:get_bool('when',  Options), Workspace, ReporterId, FirstTask, SecondTask),

  maybe_deps(proplists:get_bool(preceed,  Options), proplists:get_bool(follow,  Options),Workspace, ReporterId, FirstTask, SecondTask).

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
               false -> {Args, ergo_task:taskname_from_token(ReporterId)}
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
  ergo:add_file_dep(Workspace, ReporterId, FirstFile, SecondFile).

%          preceed,follow
maybe_deps(true,true,_,_,_,_) ->
  {error, contradictory_preceed_follow};
maybe_deps(true,_,Workspace,Reporter,First,Second) ->
  ergo:add_task_seq(Workspace,Reporter,First,Second);
maybe_deps(_,true,Workspace,Reporter,First,Second) ->
  ergo:add_task_seq(Workspace,Reporter,Second,First);
maybe_deps(_,_,_,_,_,_) ->
  ok.

%             also,when
maybe_cotasks(true,true,Workspace,Reporter,First,Second) ->
  ergo:add_cotask(Workspace,Reporter,First,Second),
  ergo:add_cotask(Workspace,Reporter,Second,First);
maybe_cotasks(false,true,Workspace,Reporter,First,Second) ->
  ergo:add_cotask(Workspace,Reporter,Second,First);
maybe_cotasks(true,false,Workspace,Reporter,First,Second) ->
  ergo:add_cotask(Workspace,Reporter,First,Second);
maybe_cotasks(_,_,_,_,_,_) ->
  ok.

%             require,produce
maybe_filedep(true,true,_,_,_,_) ->
  {error, contradictory_require_produce};
maybe_filedep(true,false,Workspace,Reporter,First,Second) ->
  ergo:add_required(Workspace,Reporter,First,Second);
maybe_filedep(false,true,Workspace,Reporter,First,Second) ->
  ergo:add_product(Workspace,Reporter,First,Second);
maybe_filedep(false,false,_,_,_,_) ->
  ok.

usage_string(ProgramName, OptSpecList, CmdLineTail, OptionsTail) ->
  io_lib:format("~ts~n~n~ts~n",
                [ unicode:characters_to_list(getopts:usage_cmd_line(ProgramName, OptSpecList, CmdLineTail)),
                  unicode:characters_to_list(getopts:usage_options(OptSpecList, OptionsTail))]).
