# ergo

`ergo` is a build orchestrator. It's purpose is to manage and sequence the many
tasks that are part of any moderately sized software project.

The core function of ergo is to record the files that are required and produced
by each build task, and then sequence those tasks when a specific file or task
is requested.

The principles of `ergo's` design are that the build process should be correct,
reproducible and fast, in that order. Builds should be as easy to work with as
possible. And while `ergo` should be able to interface with other tools, it
should do as little itself as possible.

`ergo` doesn't itself provide a language with which to define tasks. It
executes commands as indicated, so the tasks themselves can be written in any
language, with the requirement that the language can itself execute commands
(_a la_ a `spawn()` function) in order to report to `ergo` its place in the
build.

## The Depgraph

`ergo` is built around a directed acyclic graph called the "depgraph." The
vertices of this graph are files and tasks, and the edges are their
relationships - i.e. the `gcc a.c -o a.out` task 'requires' the file 'a.c' and
'produces' 'a.out'.

If 'produces' and 'requires' were the only edges in the depgraph, it would be a
simple bipartate graph, with tasks in one side, and files on the other.

However, `ergo` also defines two kinds of edges between tasks. The first,
called an 'also' edge, indicates that the source task should be run whenever
the incident task is run. A second, the 'sequence' edge, indicates that if they
appear together in a build run, one task should be run before the other.

Using these different edges large, complex build graphs can be established from
local reports from within each task. Tasks can often be added to an existing
build without changing the tasks that already exist.

## From Graph to Build

When you run a build with `ergo` like this:

```
ergo compile a
```

what happens is that a new graph is produced from the depgraph, call the "also
graph" - all the tasks that are linked to the request task or file by explicit
'also' edges or through a 'produce'/'require' pair that goes through a file.
That is to say, if a task is brought into the also-graph then all the tasks
that produce the files that the original task requires are also added.

The tasks in the also-graph are then sorted topologically based on the sequence
they need to be run in. In other words, if a task is marked explicitly as
preceeding another, it'll sort first. And, predictably, the producer of a tasks
requirements are sorted ahead of it.

A topological sort isn't a strong sorting, though - there are usually several
tasks that could be run in a number of orders. The build examines this
sequencing and uses it to parallelize the build process.

## Eliding Tasks

Often, only part of the sources of build will change, and the products related
to the changed source files are the only ones which need to be reproduced.

`ergo` determines this by tracking "digests" (which happens to be a hash of the 
file contents) of the various files, and only running tasks whose products are 
missing or where the digests don't match a known list. The result is much 
reduced build times, since we simply skip unnecessary work.

The source file for each task is a implicit requirement of the task when
considering elision, so `ergo` will still re-run a task if none of its
requirements or products have changed, but the task script itself has. Since
each task is its own file, this means that the change is tightly isolated, and
only those parts of the project related to the updated task need to be rebuilt.

## Other Features

`ergo` handles "nested" projects - a build that incorporates another `ergo`
build will run sensibly, producing an overall depgraph as it runs and running
the appropriate tasks in the appropriate working directories.

[WIP] There's also a utility for reporting on the depgraph itself. It can list
all the files that a particular task requires directly or indirectly through
the tasks it depends on (the so called "transitive dependencies" of a task), or
just the "leaf dependencies" of a task - the transitive dependencies for which
no producing task is known (which are assumed to be original source files.) The
practical application is that existing file watching utilities (e.g. fswatch)
can run builds automatically, and watch for changes to the source files during
the build.

## Future Work

One of the original inspirations was the Google Cloud Build tool, which
recognizes that not only are build tasks normally repeated on a single
developer's computer (and hence we can elide tasks based on local versions of
the products) but tasks are often repeated across developers. Because `ergo`
makes use of distributed Erlang, it should be possible for developers working
together to cluster their builds and simply pass existing built files over the
network rather than rebuild them. Conceivably, completely new versions of a
product might be built in a distributed fashion by spreading the work out
across machines and then collecting the results.

Another possible feature would be to stream file contents between tasks through
`ergo` itself by opening streams. This would allow build tasks to pipeline -
essentially to parallelize across generations sometimes. The file would still
be saved to disk so that prior tasks could be elided. Whether the speed
improvements this would provide would be worth the configuration complexity
remains to be seen.

It might expand the number of task-definition languages if `ergo` could accept
graph statements over a socket, or as HTTP requests, or in UDP packets or...
or... or... instead of needing to call out to running commands through the OS.

Likewise, some build tasks might take appreciable time to start up, but do
their actual work quickly. Tools written in Ruby with large numbers of gems
involved are an example. Therefore, it might be useful to be able to set up a
slightly more complex "task server" which would receive commands over e.g. a
socket and perform individual tasks, thus saving all but the first
initialization time.

One issue with using digests to manage task elision is that some build
processes do not produce identical files. For instance, Java class files
include a timestamp of when they were built. There are a number of possible
solutions to this problem, from allowing a task to report its own digest for
its products - this could solve the Java problem by digesting the part of the
file after the timestamp.

Another option would be for a task to report that it's products should be
considered by filesystem timestamp. This wouldn't be as robust as using file
digests, and such files couldn't participate in the distributed build, but it
would be much simpler to manage for the developer.

Finally, there is a small part of the way tasks run that assumes a Unix-like 
OS. I have doubts about whether it will work under Windows, but neither the 
facilities or interest in confirming those doubts or supporting Windows 
directly. I would welcome contribution along these lines, however.

## Related Work

Daniel J. Bernstein described a build tool called redo which was a major
inspiration for `ergo.`

It would be disingenious to neglect to mention Make in all its many forms as
being a major inspiration. Certainly, I learned the idea of eliding build tasks
from Make, and wishing I could avoid its syntax, which is a product of the time
in which it was developed.

The above mentioned Google build tool.

The idea of streaming data through sockets or pipes mentioned in "future work"
is inspired by the Gulp task runner.
