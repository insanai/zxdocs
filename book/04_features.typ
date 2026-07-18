#import "theme.typ": *
#import "figures.typ": *

= Advanced Replicated Log Features

#objectives([
  By the end of this chapter you should be able to tune logical timers without
  confusing them with safety, validate flexible quorum arithmetic, repair a
  same-epoch follower, and use `ReplicatedLog` without attributing host-owned
  snapshot work to the library.
])

== Logical Time: The Power of Ticks

Paxos safety does not depend on accurate clocks. Progress mechanisms do need a
way to suspect silence and retransmit. Reading the system clock inside the core
would make identical input schedules harder to reproduce, so the host converts
elapsed time or scheduler events into logical ticks.

Our library keeps time out of the consensus core. The node has no clock. Instead, the host application drives time by calling the `tick` method at a stable interval:

```zig
// Call this every 10 milliseconds in your event loop
try node.tick(noop_command, &effects);
```

When you call `tick`, the node performs three logical duties:

#book_figure(
  [One logical tick drives election timers, heartbeats, and retransmission sweeps.
  Only the logic for the node's current role is executed.],
  tick_flow(),
)

+ *Liveness check (Follower)*: Counts ticks since accepted leader traffic. At
  `election_timeout_ticks` it starts a campaign; this is suspicion, not proof
  that the prior leader failed.
+ *Heartbeat emission (Leader)*: Sends heartbeats at `heartbeat_interval_ticks` to remind followers that it is active, preventing split campaigns.
+ *Retransmission (Leader)*: At `resend_interval_ticks`, the leader sweeps its slot log and resends uncommitted proposals to slow or returning peers.

Because ticks are input calls, a test or simulator can advance logical time by
calling `tick` without waiting for real milliseconds. This makes timeout paths
reproducible; it does not make all liveness schedules trivial to test.

== Flexible Quorums: Shifting the Balance

In classic Paxos, majorities are used for both Phase One (prepare) and Phase Two (propose). For a five-node cluster, both quorums must be size 3.

Howard, Malkhi, and Spiegelman made the Flexible Paxos trade-off explicit:
every possible phase-one quorum must intersect every possible phase-two
quorum. The current library supports uniform quorum *sizes*, for which the
condition is:
$$ |Q_1| + |Q_2| > N $$
Two phase-two quorums need not intersect. Within one ballot, uniqueness and the
single-value check prevent two values; before a later ballot proposes, its
phase-one quorum intersects the earlier phase-two quorum and recovers the
highest vote. Flexible quorums change availability: a five-node `(Q1=4, Q2=2)`
system can write with two members under a stable leader but needs four members
to replace that leader.

This allows you to tune your cluster for different workloads:

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Nodes (N)*], [*Read (Phase 1)*], [*Write (Phase 2)*], [*Operational Trade-off*]),
  [5], [3], [3], [Standard symmetric majority quorum.],
  [5], [4], [2], [Smaller stable-leader vote quorum; leader replacement needs
    four members.],
  [5], [2], [4], [Smaller phase-one quorum; every new value needs four durable
    acceptances.],
)

The options are compile-time constants, but validation occurs when
`Membership.init` receives the runtime member slice:

```zig
const P = paxos.Protocol(Command, .{
    .max_members = 5,
    .max_slots = 8192,
    .read_quorum_size = 4, // Phase 1
    .write_quorum_size = 2, // Phase 2
});
```

== Reconfiguration: The Stop Sign Invariant

When we need to change membership (e.g., adding node 6), we must not let two different configurations run at the same slot.

We solve this using a *Stop Sign* entry. A Stop Sign is a special command proposed in the log:

```zig
const next_epoch_members = [_]NodeId{ 2, 3, 4, 5, 6 };
const slot = try node.reconfigure(
    next_epoch_id,
    &next_epoch_members,
    "checkpoint_hash",
    &effects,
);
```

When a stop sign enters the log:
1. *Immediate local seal*: The proposer seals when `reconfigure` returns;
   another member seals after accepting the stop. This conservative seal can
   later be cleared by recovery if a higher ballot chose a command instead.
2. *Order Conservation*: It continues processing network messages to help decide and commit all slots up to the Stop Sign.
3. *Clean handover*: Once `isReconfigured()` returns the decided stop, the host
   transfers application state and creates a new instance at Slot 1.

This epoch-based design ensures that configuration changes are totally ordered alongside regular writes, preserving safety.

== Catch-Up and Reconciliation

If a node gets partitioned and falls behind, it does not need to run a complex recovery loop. It simply asks its peers for missing commits:

```zig
try node.requestCatchUp(peer_id, first_missing_slot, &effects);
```

The peer replies with every committed entry it still represents from that slot.
The lagging node may receive them out of order, but releases only a contiguous
prefix. The current bounded core does not compact within an epoch. If the old
epoch instance is no longer available, `requestCatchUp` cannot cross that
boundary; the host must transfer and verify the snapshot named by the decided
stop sign, then initialize the appropriate epoch.

#exercise([14.1], [
  For seven members, choose uniform phase-one and phase-two sizes optimized for
  a small stable-leader write quorum of three. What phase-one size is required?
  How many unavailable members can the cluster tolerate during leader
  replacement? Check the exact inequality used by `Membership.init`.
])

#teach_back([
  Explain why `read_quorum_size` is not an application read API. Then explain
  one safe way to serve a linearizable key-value read using an ordered barrier,
  without claiming that `committedAt` itself provides linearizability.
])
