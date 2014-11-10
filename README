erdo is a build system, intended to do the same kind of job as Make et al.

Basically, like many before me I've come to the conclusion that Make itself is
pretty terrible, but that everything since Make is worse. This is especially
evident with the current influx of JavaScript "task runners" that are
especially awful.

Premises

A build tool should facilitate the construction of correct, reproduceable, fast
build workflows, in that order. There are a number of challenges to those
goals, not the least of which being that they are in tension, generally.

In the Unix spirit of doing one thing well, a build tool should not actually
know anything about how artifacts are produced - compilers, linkers,
concatenators, transpilers, tranformers, etc. are responsible for actually
taking inputs and producing outputs. The build tool's job is to know how to run
these other tools, and to coordinate their action to produce finished
artifacts.

erdo borrows from DJB's redo idea that build tasks themselves are small shell
scripts, which register their dependencies by means of executing programs from
the erdo suite. The contents of the scripts are always an implicit dependency
of the task they describe, so changing the task always results in the task
being re-run. ( https://github.com/apenwarr/redo )

erdo borrows from an unpublished Google Cloud Build tool some ideas about using
digests to determine the freshness of tasks (although, that's true of e.g.
SCons), and structuring the build as a bipartate graph between build artifacts
and the tasks that generate them. There's a wishlist feature around sharing
artifacts across a small team which is inspired by Google's tool's ability to
cache builds across their enterprise.
(http://google-engtools.blogspot.com/2011/08/build-in-cloud-how-build-system-works.html)

One key innovation (as far as I'm aware) is that erdo explicitly maintains the
build graph. While other build systems operate on an implicit graph, erdo
explicitly records dependencies in a graph and uses that graph to sequence
tasks. One consequence of this is that erdo can produce *reverse*
dependencies, which can be useful for running automatic builds. Another is that
erdo can sequence builds based on the overall build graph, which is especially
useful for parallel builds.
