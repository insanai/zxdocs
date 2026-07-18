#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  We inspect the proof with tests, inspect the implementation with measurements,
  and inspect a deployment with failure drills.
])

= Validation, Testing, and Benchmarks

== Testing a consensus core

A normal test proves that one schedule works. A consensus test should search for
schedules that almost break the invariant.

The main safety oracle is simple:

```text
for every slot:
    collect every committed value from every node
    assert that the set contains at most one distinct value
```

The liveness oracle is conditional:

```text
after the network becomes stable and one leader remains:
    every accepted client command eventually commits
```

Do not assert liveness while messages are dropped forever. The protocol cannot
manufacture a quorum.

=== Deterministic schedule tests

The repository tests these cases:

#table(
  columns: (1.2fr, 1.8fr),
  table.header([*Test*], [*Property*]),
  [Ballot order], [Rounds dominate nodes and equal rounds use node order.],
  [Membership errors], [Empty, zero, and duplicate IDs are rejected.],
  [Consecutive commit], [Three nodes learn the same two values.],
  [Duplicate messages], [Prepare and accept repeats do not add writes or votes.],
  [Reordered recovery], [Completion markers may precede entries.],
  [Highest vote], [Recovery chooses the greatest accepted ballot.],
  [Local acceptance], [The leader persists locally before remote messages.],
  [Contiguous learning], [Slot 2 waits for slot 1.],
  [Catch up], [Known commits are returned from the requested slot.],
  [Slot exhaustion], [The final slot is not reused.],
)

=== A simulator

A stronger simulator keeps a bounded queue of envelopes. At each step it chooses
one action from a seeded generator:

+ deliver one envelope,
+ drop one envelope,
+ duplicate one envelope,
+ move one envelope to another queue position,
+ campaign one node,
+ crash one node,
+ restore one node from its durable shadow,
+ heal a partition,
+ propose one command.

After every action it checks safety. It also compares each live node's internal
durable state with the state obtained by replaying the writes that the simulated
disk accepted.

Seeds must be printed on failure. A failing schedule should be reduced to the
smallest sequence that still fails. Random testing without reproducibility is a
demonstration, not a debugging tool.

=== Crash injection

The effect boundary gives exact crash points.

#table(
  columns: (auto, 1fr),
  table.header([*Point*], [*Simulation action*]),
  [Before writes], [Discard the whole effect batch and restore.],
  [During writes], [Apply a prefix or simulate a torn record, according to the
    journal contract.],
  [After sync], [Apply all writes, discard messages, and restore.],
  [During sends], [Apply all writes and enqueue only a message prefix.],
  [During commit apply], [Persist an application prefix and test at least once
    delivery after restore.],
)

=== Model checking

The code is not a formal specification. A small model can still mirror its core
state: promises, accepted ballots, accepted values, and chosen values for two
slots and three nodes. Exhaustive exploration can check that no transition makes
two chosen values.

The model and implementation must be compared field by field. A proof of the
wrong model is no proof of the program.

== The cross language benchmark

The benchmark uses two independent implementations. OmniPaxos 0.2.2 is a Rust
replicated log library from crates.io. LibPaxos3 is a C implementation from the
University of Lugano. Its source is pinned at revision `d255f8b`.

The command is:

```sh
zig build benchmark
```

It runs the Zig executable in `ReleaseFast`. It then runs the Rust package with
release optimization, one code generation unit, and fat link time optimization.
Finally it compiles the unmodified LibPaxos3 core with `zig cc -O3 -DNDEBUG`.
`Cargo.lock` pins all Rust dependencies. The C script verifies its complete Git
revision before compilation.

=== Workload

#table(
  columns: (auto, 1fr),
  table.header([*Item*], [*Value*]),
  [Voting nodes], [3],
  [Values per sample], [4,096 sequential `u64` values.],
  [Samples], [7. The median elapsed sample is reported.],
  [Storage], [In memory for all implementations.],
  [Network], [In process delivery for all implementations.],
  [Leader setup], [Completed before timing and message counting.],
  [Completion], [The queue drains after every proposed value.],
  [Correctness], [Every checksum must equal 8,390,656.],
)

The benchmark is a latency shaped microbenchmark. It does not batch many client
values into one consensus message. It does not serialize, call a kernel network,
or sync a disk. Zig and Rust use a stable leader and send six messages per value.
LibPaxos3 maintains its 128 slot phase one preexecution window and sends twelve.

=== One observed run

On July 18, 2026, one arm64 macOS 26.5.1 run with Zig 0.16.0 and Rust 1.95.0
reported:

#table(
  columns: (1.2fr, auto, auto, auto),
  table.header([*Implementation*], [*ns/value*],
    [*messages/value*], [*checksum*]),
  [Zig Multi Paxos], [`206.41`], [`6.00`], [`8390656`],
  [C LibPaxos3], [`1679.44`], [`12.00`], [`8390656`],
  [Rust OmniPaxos], [`4524.64`], [`6.00`], [`8390656`],
)

#book_figure(
  [Observed local CPU time per value. This is a regression signal, not a universal
  ranking. Lower is better.],
  benchmark_plot(),
)

The first honest comparison found that the Zig code sent 9 messages per value
because the leader sent messages to itself. The implementation was corrected to
persist local acceptance directly and send only to peers.

The next comparison found a more important error. The benchmark constructed a
large bounded `Effects` object inside the drain function for every value. The
sampling profiler showed almost all time in `bzero`. Reusing one caller owned
effect buffer changed the observed Zig result from about 11,588 ns per value to
between 113 and 206 ns in subsequent runs. The protocol did not become one
hundred times faster. The benchmark stopped measuring unnecessary memory
clearing. Since the timed Zig sample is below one millisecond, normal scheduling
noise remains visible. Treat the result as a regression signal.

In this observed CPU measurement, Zig is about 8.1 times faster than the C run
and about 21.9 times faster than the Rust run. These are local ratios for this
workload. The C implementation performs twice as many logical messages and uses
a different phase one design. The libraries also have different features and
data structures. The numbers must not be presented as a universal language
ranking.

=== What the benchmark does not prove

It does not prove which library is faster on another CPU. It does not measure
durable latency. It does not compare recovery, batching, reconfiguration,
snapshots, read paths, serialization, or partial connectivity. The feature map
in `docs/features.md` records relevant differences.

For a publishable performance claim, record:

+ exact source revisions and dependency lock files,
+ CPU model, core pinning, governor, memory, and operating system,
+ compiler versions and flags,
+ warmup, sample count, distribution, and confidence interval,
+ payload sizes and batching,
+ storage and network configuration,
+ median and tail latency as well as throughput.

== Performance lessons from C and the profiler

LibPaxos2 uses a fixed circular instance table, a compact promise bit vector,
phase one preexecution, and buffered UDP messages. LibPaxos3 separates its core
from libevent, maintains a preexecution window, and tracks a quorum with a member
array and count. MySQL XCom also uses bit sets for prepare and propose replies.

The Zig core already had contiguous fixed arrays and a stable leader pipeline.
This revision added exact width bit sets for duplicate promise and vote tracking.
It also made effect buffer initialization explicit and reused that buffer in the
example and benchmark.

Further work should be measured.

+ Benchmark several payload sizes and batch sizes.
+ Measure wire encoding and packet batching.
+ Measure a durable journal with realistic sync policy.
+ Separate phase one output capacity from steady phase two output capacity if
  large bounds make effect buffers impractical.
+ Profile before changing branch structure.

Any optimization must retain the durable write order and deterministic tests.
A faster unsafe acknowledgement is not an optimization.

== Operating drills

Before production, rehearse:

+ one follower crash and restore,
+ leader crash before any accept reply,
+ leader crash after a quorum but before commit broadcast,
+ minority partition,
+ delayed old leader traffic after healing,
+ disk full during promise and accept writes,
+ torn final journal record,
+ snapshot transfer interrupted at every chunk,
+ slot capacity alert and epoch transition,
+ loss of a complete failure domain.

For each drill, record the expected role, ballot, commit prefix, applied prefix,
client response, and recovery time. If the expected result cannot be written
before the drill, the design is not yet understood.

== Review checklist

#table(
  columns: (auto, 1fr),
  table.header([*Area*], [*Question*]),
  [Identity], [Can a node ID ever name another logical member?],
  [Durability], [Can any protocol reply leave before its write is synced?],
  [Decode], [Are length and version checked before expensive work?],
  [Application], [Is apply deterministic and ordered by slot?],
  [Retry], [Can one client request appear in two slots without running twice?],
  [Read], [Does each endpoint state its consistency level?],
  [Election], [Will campaigns eventually stop competing?],
  [Snapshot], [Is applied slot atomic with application state?],
  [Capacity], [Is transition tested before the hard slot bound?],
  [Security], [Does authenticated identity match the envelope source?],
)
