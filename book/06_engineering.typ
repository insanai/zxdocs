#import "theme.typ": *
#import "figures.typ": *

#part_page("VI", [Evidence], [
  We inspect the proof with tests, inspect the implementation with measurements,
  and inspect a deployment with failure drills.
])

= Validation, Testing, and Benchmarks

== Testing Consensus: Safety Oracles

Testing a consensus library is completely different from testing ordinary software. We cannot prove correctness simply by asserting that a value was written under happy network conditions. We must verify that safety holds under the most chaotic schedules.

Our primary testing tool is the *Safety Oracle*. During a test or simulation, we run a background checker:

```text
for every slot S:
    collect all committed values reported by all nodes for slot S
    assert that the set of committed values contains at most one unique value
```

This oracle is simple and absolute. If N1 commits `tea` in Slot 5, and N2 commits `coffee` in Slot 5, the assert fails immediately, indicating a safety violation.

=== The Deterministic Simulator
To find hidden race conditions, we run tests inside a *Deterministic Simulator*. The simulator controls time, network delivery, and node crashes. It enqueues packets and chooses the next action based on a seeded random number generator:
1. Deliver a message.
2. Drop a message to simulate packet loss.
3. Duplicate a message.
4. Reorder messages to deliver them out of order.
5. Crash a node and reboot it.

Because the simulator is deterministic, if a seed fails, we can replay the exact same sequence of events to debug and fix the issue.

== The Cross-Language Benchmark

To verify that our library is fast and lightweight, we wrote a benchmark comparing it against:
- *OmniPaxos (Rust)*: A modern consensus log library.
- *LibPaxos3 (C)*: A classic C library from the University of Lugano.

The workload runs a stable leader replicating 4,096 sequential values on a three-node cluster. The network and storage are simulated in memory to isolate pure CPU execution cost.

=== Performance Measurements

On our arm64 macOS system, running `zig build benchmark` yielded these median latency metrics:

#table(
  columns: (1.2fr, auto, auto, 1fr),
  table.header([*Library*], [*Median ns/value*], [*Messages/value*], [*CPU Speed Ratio*]),
  [Zig Multi-Paxos (Ours)], [*116.58 ns*], [*6.00*], [*1.0x (Baseline)*],
  [C LibPaxos3], [1,711.91 ns], [12.00], [14.6x slower],
  [Rust OmniPaxos], [4,396.36 ns], [6.00], [37.7x slower],
)

=== Why the Zig Core is Fast
Why did the Zig implementation achieve such low CPU overhead? It is not due to compiler magic; it is the result of explicit memory design:

+ *Effects Buffer Reuse*: The benchmark uses a caller-owned `Effects` buffer. The allocator is never called.
+ *Compact Bitsets*: Voter bitmaps fit in a single CPU register (`u64`), allowing the compiler to emit direct bit shifts.
+ *In-Place Construction*: Large node structs are initialized directly in stable application storage, avoiding heap copies.

In contrast, the profiler showed that OmniPaxos and LibPaxos3 spent substantial CPU time in heap allocation, object serialization, and memory clear operations (`bzero`/`memset`) during hot message loops.

== Feature Comparison and Design Map

Consensus implementations are shaped by their target host environment. While Rust OmniPaxos provides features wrapped in macro annotations and abstract traits, our Zig library focuses on explicit integration boundaries, zero runtime allocations, and static memory bounds.

#table(
  columns: (1.1fr, auto, 1.6fr),
  table.header([*Capability*], [*Zig Core*], [*Design Notes*]),
  [Multi-Paxos replicated log], [Yes], [Stable leader phase skips repeated Phase One.],
  [Automatic leader election], [Yes], [`tick` starts ballot elections after bounded logical timeouts.],
  [Leader priority], [Yes], [Priority is ordered inside ballots before node ID.],
  [Heartbeats], [Yes], [Leaders emit bounded heartbeat traffic from `tick`.],
  [Message retransmission], [Yes], [`tick` resends outstanding accepts and commits.],
  [Reconnect repair], [Yes], [`reconnected` repairs one peer without allocation.],
  [Flexible quorums], [Yes], [Read and write quorums are validated to intersect.],
  [Batched append], [Yes], [One call returns one write and message effect batch.],
  [Reads], [Yes], [Point reads, decided prefix, and caller-buffer suffix reads.],
  [Catch-up], [Yes], [A lagging member requests decided entries from a slot.],
  [Reconfiguration], [Yes], [An accepted stop seals local appends; a decided stop starts the next epoch.],
  [Snapshot compaction], [Yes], [`checkpoint` seals an epoch with snapshot metadata.],
  [Fixed memory], [Yes], [All protocol buffers have compile-time bounds.],
  [Reusable effects], [Yes], [`Effects.init` avoids clearing large inactive backing arrays.],
)

=== Reconciling Rust and Zig Native Boundaries

Some consensus libraries solve runtime constraints via framework macros or abstractions. Our Zig library keeps these concerns at the host boundary:

- *Storage & Journaling*: Rather than defining a complex trait, the host application is handed an `Effects` block listing dirty writes. The host handles disk writes and calls `DurableState.apply`.
- *Network Transport*: There are no socket wrappers in the core. The host sends network envelopes after writes are synced.
- *Serialization & Codecs*: The host selects its own wire serialization format for its compile-time `Command` type, avoiding derive macro overhead.
- *Dashboard & Metrics*: Diagnostic properties (role, ballot, leader, decided prefix) are exposed via public read-only accessors.

== Operating Drills: Rehearsing Failure

Before deploying a consensus system to production, the operations team must rehearse common failure scenarios. If you do not know how the system will react, you are not ready to operate it.

#table(
  columns: (1.2fr, 1.8fr),
  table.header([*Drill*], [*Expected Recovery Behavior*]),
  [Single Follower Crash], [The follower reboots, replays its journal, catches up from the leader, and resumes voting within milliseconds.],
  [Leader Crash (Mid-Vote)], [Followers detect leader silence, campaign, elect a new leader, and recover any partially accepted slot values before accepting new writes.],
  [Split-Brain Partition], [The minority partition pauses progress safely. The majority partition continues serving client writes. When healed, the minority catches up.],
  [Disk Full during Sync], [The affected node crashes immediately to prevent writing a torn record. It resumes once disk space is cleared.],
)
