#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  We separate proof obligations, repository tests, local measurements, and
  deployment evidence. Each answers a different question.
])

= Validation, Testing, and Operations

#objectives([
  By the end of this part you should be able to describe what the current test
  suite establishes, design the missing fault harness, interpret the benchmark
  without causal overclaiming, and plan recovery drills with observable exit
  criteria.
])

== Four kinds of confidence

#table(
  columns: (auto, 1.25fr, 1.35fr),
  table.header([*Evidence*], [*Question answered*], [*What it cannot answer*]),
  [Invariant argument], [Why every allowed transition preserves agreement.],
    [Whether the Zig code and host exactly implement the argument.],
  [Deterministic tests], [Whether selected executions and edge cases behave as
    asserted and remain reproducible.], [Whether untested schedules are safe.],
  [Model checking or refinement], [Whether all states within a finite model
    satisfy a specification.], [Whether codecs, disks, and production code
    refine that model unless the relation is established.],
  [Fault drills and telemetry], [Whether the deployed host recovers under
    realistic failures and within its objectives.], [A general proof of
    safety.],
)

Lamport's invariant discipline tells us what to check. Knuth's literate
discipline tells us to record why each case exists. A regression test should
name the failure schedule and the invariant it protects.

== What the repository tests today

`zig build test` currently covers:

+ ballot ordering, membership rejection, and flexible quorum validation;
+ leader election and consecutive stable-leader proposals;
+ duplicate prepare and accept messages;
+ reordered phase-one entry/completion messages and highest-vote recovery;
+ bounded exhaustion, one-node quorums, batches, ticks, and heartbeats;
+ replay rejection of conflicting values and commits;
+ contiguous learner delivery and same-epoch catch-up;
+ stop-sign sealing, checkpoint metadata, and restore behavior.

These are deterministic hand-written schedules. The repository does *not* yet
contain the general seeded simulator previously described in earlier drafts of
this book. It also lacks end-to-end tests against a real crash-safe journal,
corrupted/truncated records, codec version skew, authenticated transport,
snapshot transfer, client retry recovery, and multi-epoch process restart.

#warning([A useful critique], [
  The core protocol tests often update in-memory `Node` state and a separate
  `DurableState`, but they cannot demonstrate that a future production journal
  has correct framing, checksums, sync semantics, truncation recovery, or
  atomic application-state updates. Those are required host tests.
])

== Build the missing deterministic fault harness

A useful simulator owns nodes, durable images, application images, logical
ticks, and an explicit envelope queue. One seeded action chooses among:

1. deliver, drop, duplicate, or reorder one envelope;
2. tick one node;
3. crash a node, discarding volatile `Node` and undurable effects;
4. restore from the selected durable prefix;
5. reconnect a link or request catch-up;
6. propose a uniquely identified client command.

After every action, run at least these oracles:

```text
for every slot:
    all non-null committed values are equal
for every node:
    promised never decreases in its durable history
    applied slots form a prefix and each command is applied at most once
for every client request:
    all recorded results are equal
```

Record the seed and the minimized action trace. Start with one slot and three
members; increase slots, restarts, and epochs only after the smaller state space
is trustworthy. A TLA+ specification would complement this harness, especially
if the project states how message types and durable writes refine specification
actions. No such refinement is currently shipped.

#exercise([19.1], [
  Design the smallest schedule that crashes an acceptor after it emits a reply
  but before a hypothetical host sync. Which oracle might still pass for a
  while? Which later campaign exposes the broken promise? Turn the schedule
  into a regression requirement for the host journal test.
])

== The local CPU benchmark

`zig build benchmark-zig` runs 4,096 sequential `u64` values through three
in-memory nodes, drains every message, reports the median of seven samples, and
checks a sum. Two invocations during the 18 July 2026 book review reported:

#table(
  columns: (1.4fr, auto),
  table.header([*Measure*], [*Observed value*]),
  [Median CPU time per value], [116.46 ns and 216.30 ns],
  [Logical messages], [24,576],
  [Logical messages per value], [6.00],
  [Checksum on both runs], [8,390,656],
)

The timing spread under an uncontrolled desktop scheduler is itself evidence:
one local number is not a stable product claim. The message count and checksum
are deterministic for this workload; elapsed time is not.

The aggregate `zig build benchmark` also runs pinned OmniPaxos and LibPaxos3
workloads. They are useful comparative regression fixtures, not an experiment
that isolates language, allocator, algorithm, or implementation quality. The
paths differ in protocol details and message counts. Report machine, build
mode, versions, sample distribution, and workload whenever publishing results.

The benchmark excludes real serialization, system calls, fsync, network delay,
contention, snapshots, retries, client admission, and application work. Its
numbers must never be presented as service latency or throughput.

== Capability map: exact boundaries

#table(
  columns: (1.2fr, auto, 1.65fr),
  table.header([*Capability*], [*Core*], [*Boundary*]),
  [Multi-Paxos log], [Yes], [Stable leader skips repeated phase one.],
  [Logical elections], [Yes], [`tick`; no clock reads or randomized deadlines.],
  [Priority, heartbeat, resend], [Yes], [Bounded deterministic mechanisms.],
  [Flexible quorum sizes], [Yes], [Validated by `Membership.init`.],
  [Batch proposal], [Yes], [Bounded caller input and effect storage.],
  [Log inspection], [Yes], [Not an application linearizable-read protocol.],
  [Same-epoch catch-up], [Yes], [`learn` and `commit` messages.],
  [Reconfiguration boundary], [`ReplicatedLog`], [Decides a stop sign; host
    transfers state and starts processes.],
  [Snapshot files and compaction], [No], [`checkpoint` orders only metadata and
    the next configuration ID.],
  [Storage, codec, transport, auth], [No], [Required from the host.],
  [Client sessions], [No], [Required for retry semantics.],
)

== Operating drills with exit criteria

#table(
  columns: (1.05fr, 1.8fr),
  table.header([*Drill*], [*Observe before declaring recovery*]),
  [Follower crash], [Verified journal replay; restored configuration ID;
    monotonic decided/applied prefix; caught-up peer; no duplicate effect.],
  [Leader crash during vote], [New higher ballot; recovery of the greatest
    accepted value; no conflicting commit; client ambiguity resolved by ID.],
  [Minority partition], [No minority writes acknowledged; majority progress if
    its required quorums remain; returning nodes repair before voting.],
  [Disk full or sync failure], [Node stops before sends from the failed batch;
    no reuse of mutated memory; restart from last verified record.],
  [Corrupt snapshot], [Hash/version rejection; no epoch activation; recovery
    from another verified source.],
)

Track ballot changes, role, current leader hint, decided and applied prefixes,
journal sync latency, queue depth, retransmissions, catch-up distance, epoch ID,
and client retry counts. `currentLeader()` is a hint for routing and metrics,
not a lease certificate.

#teach_back([
  Pick one production claim such as "survives a leader crash." State the
  invariant argument, repository test, missing integration test, telemetry,
  and drill exit criterion needed to support that sentence honestly.
])
