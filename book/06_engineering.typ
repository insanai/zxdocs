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

These are deterministic hand-written schedules. `zig build test` additionally
runs the seeded simulator in `sim/simulation.zig` (below) across three-node
majority, five-node flexible-quorum, and prioritized configurations. The
repository still lacks end-to-end tests against a real crash-safe journal,
corrupted/truncated records, codec version skew, authenticated transport,
snapshot transfer, client retry recovery, and multi-epoch process restart.

#warning([A useful critique], [
  The core protocol tests often update in-memory `Node` state and a separate
  `DurableState`, but they cannot demonstrate that a future production journal
  has correct framing, checksums, sync semantics, truncation recovery, or
  atomic application-state updates. Those are required host tests.
])

== The deterministic fault harness

`sim/simulation.zig` implements the simulator this section previously only
sketched. Each seeded run owns the nodes, one append-only write journal per
node standing in for the disk, a message bag delivered in random order, and a
link-cut matrix. One seeded action chooses among delivering (or dropping or
duplicating) an envelope, ticking a node, proposing a uniquely identified
command at the leader, cutting or healing a link, reconnecting, and crashing a
node at one of three host commit points: before any write is persisted, after
a durable *prefix* of the writes with no message sent, or after all writes
with only a prefix of the messages sent. Restart replays the journal through
`DurableState.apply` and any replay error is itself a failure.

After every observed transition the harness checks: all non-null committed
values for a slot agree with a golden first-commit table, committed values
were proposed or are the no-op, `promised` never regresses within an
incarnation, and the decided prefix never shrinks. Every run ends with a
fault-free quiescence phase that must converge on one leader and one decided
prefix, which catches liveness regressions, not only safety ones.

Failures print the seed, the step, and a trailing action trace;
`zig build sim -- --seed=N --steps=M --verbose` replays a run exactly, and
the runner halves the step budget to report a minimal reproduction. CI runs
64 seeds per configuration inside `zig build test`; a nightly pipeline runs
`--seeds=10000 --steps=4096`.

This harness found three real defects on its first sweeps: `recordCommit`
treated a commit that disagreed with a stale local vote as corruption (legal
Paxos whenever the choosing quorum excluded that node), a restarted node
whose replayed log was committed-but-undelivered could never re-release its
prefix, and phase one did not return decrees a node had learned without
voting, so a leader behind on the log could stall forever. Each fix landed
with the seed that exposed it.

`specs/Paxos.tla` now complements the harness: a TLC-checked model of the
durable state and messages, with the promise-carries-learned-decrees rule
included, checking agreement, commit uniqueness, promise dominance, and
validity on a finite configuration. The spec's action-to-code mapping is in
the conformance appendix and `specs/README.md`; a mechanical refinement
relation between the Zig code and the spec is still not established.

#exercise([19.1], [
  Design the smallest schedule that crashes an acceptor after it emits a reply
  but before a hypothetical host sync. Which oracle might still pass for a
  while? Which later campaign exposes the broken promise? Turn the schedule
  into a regression requirement for the host journal test.
])

== The local CPU benchmark

`zig build benchmark-zig` runs a workload matrix through in-memory nodes:
commit modes (one value synchronously, pipelined windows of 8 and 64,
batches of 16 and 256), payload sizes (8 B, 64 B, 1 KiB), cluster sizes
(3 and 5), and a run with twice the needed log slots so the cost of
exactly-sized arrays is measured instead of assumed. Every run reports the
median of seven samples with min and max, a latency distribution from a
separate instrumented pass, a measured message count, and a checksum, and
exits nonzero if the count or checksum is wrong. `zig build benchmark`
adds the pinned OmniPaxos 0.2.2 and LibPaxos3 workloads and the durable
benchmark below. `sh benchmarks/run-all.sh` runs everything and writes a
machine-readable file under `benchmarks/results/`; the tables below are
rendered from `latest.json` at book build time, so the book cannot cite a
number that was not measured and committed.

#benchmark_results_table()

Three findings from the committed results deserve emphasis. First, elapsed
time on an uncontrolled desktop varies by around two times between quiet
and loaded runs; message counts and checksums are deterministic, timings
are not, which is why every committed result carries its environment.
Second, the comparison inverts with the harness shape: proposing one value
at a time measures per-append overhead, where this library is roughly an
order of magnitude ahead, but once the harness pipelines, OmniPaxos
coalesces log entries into far fewer messages and its per-value time
approaches or beats this library's, whose message count stays fixed at six
per value. That is a design difference the numbers must not launder into a
language claim. Third, LibPaxos3 runs a heavier measured twelve-message
path that includes phase-one preexecution, so its column is labeled, not
equated.

`zig build benchmark-durable` measures the safety contract itself: each
node serializes its writes to an append-only file and syncs before any
message moves. Durability costs several hundred times the in-memory path
per value with an fsync per transition, and group commit over windows of
eight recovers roughly a five-fold improvement. Read the in-memory numbers
with those magnitudes in mind.

The in-memory benchmarks still exclude real serialization, network delay,
contention, snapshots, retries, client admission, and application work.
Their numbers must never be presented as service latency or throughput,
and none of these workloads isolates language, allocator, algorithm, or
implementation quality.

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
