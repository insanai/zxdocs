#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [A sequence of decisions], [
  A service needs more than one chosen value. We arrange decisions in slots,
  recover an old leader's work, fill holes, and apply one ordered prefix.
])

= Multi-Paxos Log Replication

#objectives([
  By the end of this chapter you should be able to lift the single-decree rule
  across slots, explain complete phase-one replies under packet reordering,
  recover holes with a host-supplied no-op, and describe exactly what a stop
  sign and checkpoint do—and do not do.
])

== Why Multi-Paxos?

Classic Paxos chooses exactly one value for one slot. If we want to build a replicated log to run a database, we could run a completely separate instance of Classic Paxos for every single slot in the log. 

But this is slow! Every slot would require:
1. Phase One (Prepare & Promise) -> 1 Round Trip.
2. Phase Two (Accept & Accepted) -> 1 Round Trip.

This means every single log append takes at least two network round trips and two disk syncs.

Multi-Paxos is an elegant optimization. Instead of running Phase One for each slot, a candidate campaigns for *all slots in the log* at the same time. Once the candidate wins a quorum of promises for the entire log, it becomes the stable leader. 

For all subsequent slots, the leader can skip Phase One entirely and propose values in Phase Two directly! The cost of a log append drops to a single network round trip.

#book_figure(
  [Multi-Paxos runs Phase One once to establish leadership across all slots,
  allowing subsequent appends to run Phase Two in parallel with a single round trip.],
  log_picture(),
)

== Combining the Phase One Replies

How does a candidate query the entire log? In Phase One, it sends a single `prepare` message. Acceptors reply with all of their accepted votes across all slots in a sequence of messages:

```text
promise (ballot, slot 1, accepted_ballot 3, value "A")
promise (ballot, slot 3, accepted_ballot 4, value "C")
promise_done (ballot, accepted_count 2)
```

Because the network can reorder packets, the final `promise_done` marker might arrive before the individual slot `promise` entries. If the leader immediately declared itself ready, it might miss some accepted entries, violating safety!

To prevent this, the candidate tracks the expected entry count from `promise_done` and waits until it has received every single entry:

```zig
// Equivalent to Protocol.Node.maybeBecomeLeader.
if (!self.promise_done[member]) continue;
if (self.promise_received[member] == self.promise_expected[member]) {
    complete += 1;
}
```

A member's reply is counted toward the quorum only when it is complete. This count-based tracking makes the protocol transport-independent: we do not assume TCP FIFO ordering for correctness.

== Holes and the No-Op Value

Imagine that N1 becomes the leader. During its Phase One recovery, it discovers:
- Slot 1 has an accepted vote `alpha`.
- Slot 3 has an accepted vote `gamma`.
- Slot 2 has no accepted votes reported by anyone.

By the safety rules, the leader must recover and propose `alpha` in Slot 1 and `gamma` in Slot 3. But what about Slot 2? The leader cannot leave Slot 2 empty. If it did, and later applied Slot 3, the database would have a gap in its history, violating state machine order.

The leader must fill the gap in Slot 2. It proposes a *No-Op* (no-operation) command. A No-Op command consumes the slot, but when the state machine applies it, it performs no work.

In our Zig library, the host application supplies the No-Op value when starting a campaign:

```zig
try node.campaign(.{
    .client_id = 0,
    .request_id = 0,
    .operation = .noop,
}, &effects);
```

This keeps the library clean and generic: the consensus core does not need to invent application-specific command values.

#warning([A no-op is still a real value], [
  It must be self-contained, serializable, deterministic when applied, and
  safe to replay. `campaign` stores the supplied value for recovery; there is
  no special no-op tag inside the generic protocol.
])

== The Stable Leader Pipeline

A stable leader can have multiple proposals in flight at the same time. This is called *pipelining*. It hides network latency by allowing the leader to propose Slot 101 before Slot 100 has committed.

However, pipelining introduces the risk of unbounded memory usage. If clients send writes faster than the disk can sync them, the queue of uncommitted proposals will grow forever.

The library prevents unbounded protocol memory by giving the entire epoch a
static `max_slots` bound. It does not implement a smaller in-flight window or
client admission policy. A leader may fill the remaining epoch with
uncommitted proposals; after the last slot it returns
`error.SlotLimitReached`. The host should impose an earlier in-flight limit,
apply backpressure, and reserve space for a stop sign or checkpoint.

== Membership Changes: The Stop Sign

A consensus cluster cannot remain fixed forever. Machines wear out, datacenters change, and operators must add or remove nodes. 

If we simply change the membership configuration on the fly, we risk splitting the cluster. For example, if we transition from three nodes $\{A, B, C\}$ to a new set $\{D, E, F\}$, a partition could allow $\{A, B\}$ to make decisions under the old configuration, while $\{D, E\}$ make different decisions under the new configuration.

Our library implements a safe, clean reconfiguration mechanism called a *Stop Sign*:

#definition([Stop Sign], [
  A special log entry that names the next configuration. The proposer seals
  local appends as soon as `reconfigure` succeeds; another node seals after it
  accepts or commits the stop. Once the stop is decided, the host may transfer
  state and initialize the next configuration.
])

```zig
const slot = try node.reconfigure(
    next_configuration_id,
    &.{ 2, 3, 4, 5, 6 }, // New membership IDs
    "epoch_metadata",
    &effects,
);
```

By placing the stop inside the log, the old configuration agrees on the
boundary relative to commands. The library does not automatically transfer a
snapshot, start processes, or stop old network traffic. The host must wait for
`isReconfigured()` to return the *decided* stop before calling `initFromStop`,
and must prevent the sealed old instance from serving new writes.

== Bounded Logs and Epochs

Because the log size `max_slots` is bounded at compile time, what do we do when we run out of slots? We transition to a new epoch.

1. *Quiesce appends*: Reserve capacity, stop admitting new commands, and let
   the application reach the decided prefix that the snapshot will represent.
2. *Snapshot*: Durably write and verify host-owned application state.
3. *Checkpoint*: Call `node.checkpoint(snapshot_metadata, &effects)`. This is a
   convenience wrapper that proposes a stop sign with the same members and
   `configuration_id + 1`; it does not write the snapshot.
4. *Decide the boundary*: Consume effects until `isReconfigured()` returns the
   stop sign. The snapshot metadata in that value must identify the durable
   state through every command before the stop.
5. *Start the next epoch*: Initialize a fresh `ReplicatedLog.Node` at Slot 1 and
   restore the host state named by the metadata.

This epoch design bounds protocol memory and performs no runtime allocation in
the core. It does not by itself guarantee maximum speed, safe snapshot files,
or bounded memory in the host.

#exercise([11.1], [
  A leader has decided through slot 80, has accepted but not decided commands
  in slots 81 and 82, and has four free slots. May the host snapshot through
  80 and immediately start a new epoch? Describe the steps needed to give
  commands 81 and 82 an unambiguous fate.
])

#teach_back([
  On blank paper draw three boxes labeled old epoch, stop sign, and new epoch.
  Explain which box the library writes, which state the host writes, and the
  exact observation that permits the new epoch to start.
])
