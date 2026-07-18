#import "theme.typ": *
#import "figures.typ": *

= Advanced Replicated Log Features

== Logical Time: The Power of Ticks

Consensus depends on order, not time. If a consensus library queries the system clock directly, it introduces a source of non-determinism. System clocks can drift, jump backward during NTP syncs, or pause during virtual machine migrations.

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

+ *Liveness check (Follower)*: Counts ticks since it last heard from the leader. If the count exceeds `election_timeout_ticks`, the follower assumes the leader has failed and starts a campaign.
+ *Heartbeat emission (Leader)*: Sends heartbeats at `heartbeat_interval_ticks` to remind followers that it is active, preventing split campaigns.
+ *Retransmission (Leader)*: At `resend_interval_ticks`, the leader sweeps its slot log and resends uncommitted proposals to slow or returning peers.

Because ticks are just integer calls, testing becomes trivial: a simulator can fast-forward time simply by calling `tick` in a loop, without waiting for real milliseconds to pass.

== Flexible Quorums: Shifting the Balance

In classic Paxos, majorities are used for both Phase One (prepare) and Phase Two (propose). For a five-node cluster, both quorums must be size 3.

But Leslie Lamport and Heidi Howard proved a deeper truth: *any quorum size is safe as long as every Phase One quorum intersects with every Phase Two quorum.*
$$ |Q_1| + |Q_2| > N $$
Two Phase Two quorums do *not* need to intersect with each other. Why? Because the leader handles slot ordering. We only need the Phase One query to meet the Phase Two vote to discover any chosen values.

This allows you to tune your cluster for different workloads:

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Nodes (N)*], [*Read (Phase 1)*], [*Write (Phase 2)*], [*Operational Trade-off*]),
  [5], [3], [3], [Standard symmetric majority quorum.],
  [5], [4], [2], [*Optimized Writes*: Write quorum of 2 allows lightning-fast writes (only one remote response needed). Leader replacement requires 4 nodes.],
  [5], [2], [4], [*Optimized Recovery*: Election is very fast, but writes require 4 nodes. Useful for read-heavy static clusters.],
)

In the Zig library, we validate this inequality at compile time:

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

When a node accepts a Stop Sign:
1. *Immediate Seal*: It seals the current log. The node will reject any new local client proposals for that epoch.
2. *Order Conservation*: It continues processing network messages to help decide and commit all slots up to the Stop Sign.
3. *Clean Handover*: Once the Stop Sign commits and is applied to the state machine, the host knows the epoch is over. It creates a new node instance starting at Slot 1 under the new membership.

This epoch-based design ensures that configuration changes are totally ordered alongside regular writes, preserving safety.

== Catch-Up and Reconciliation

If a node gets partitioned and falls behind, it does not need to run a complex recovery loop. It simply asks its peers for missing commits:

```zig
try node.requestCatchUp(peer_id, first_missing_slot, &effects);
```

The peer replies with committed entries. The lagging node applies them in strict order. If the gap is too large (e.g., the peer has already discarded old slots to free disk space), the host can transfer a snapshot file instead, bringing the node up to date in one quick step.
