#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [A sequence of decisions], [
  A service needs more than one chosen value. We arrange decisions in slots,
  recover an old leader's work, fill holes, and apply one ordered prefix.
])

= Multi-Paxos Log Replication

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
// From the library's promise counting logic
const complete = member_promise.done and 
                 member_promise.received == member_promise.expected;
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

== The Stable Leader Pipeline

A stable leader can have multiple proposals in flight at the same time. This is called *pipelining*. It hides network latency by allowing the leader to propose Slot 101 before Slot 100 has committed.

However, pipelining introduces the risk of unbounded memory usage. If clients send writes faster than the disk can sync them, the queue of uncommitted proposals will grow forever.

Our library solves this by using *static bounds*: the maximum number of slots (`max_slots`) is fixed at compile time, and the node state allocates no dynamic memory. If the pipeline reaches its limit, the library returns `error.SlotLimitReached`. The host application must handle this by applying backpressure to the clients.

== Membership Changes: The Stop Sign

A consensus cluster cannot remain fixed forever. Machines wear out, datacenters change, and operators must add or remove nodes. 

If we simply change the membership configuration on the fly, we risk splitting the cluster. For example, if we transition from three nodes $\{A, B, C\}$ to a new set $\{D, E, F\}$, a partition could allow $\{A, B\}$ to make decisions under the old configuration, while $\{D, E\}$ make different decisions under the new configuration.

Our library implements a safe, clean reconfiguration mechanism called a *Stop Sign*:

#definition([Stop Sign], [
  A special log entry that contains the new membership configuration. Once a Stop Sign
  is accepted, the current log is sealed—no further proposals can be made in this epoch.
  Once the Stop Sign is committed and applied, the next configuration can safely begin.
])

```zig
const slot = try node.reconfigure(
    next_configuration_id,
    &.{ 2, 3, 4, 5, 6 }, // New membership IDs
    "epoch_metadata",
    &effects,
);
```

By placing the configuration change *inside* the log itself, we order it relative to all other decisions. Every node transitions to the new membership at exactly the same slot, preventing split-brain scenarios.

== Bounded Logs and Epochs

Because the log size `max_slots` is bounded at compile time, what do we do when we run out of slots? We transition to a new epoch.

1. *Checkpoint*: The application applies all committed slots up to slot $K$, writes a snapshot of its database state to disk, and calls `node.checkpoint` to seal the epoch.
2. *Epoch Transition*: The host decides a Stop Sign that names the new configuration.
3. *Clean Start*: The host initializes a fresh node for the next epoch starting at Slot 1, using the snapshot as its initial state.

This epoch-based design allows the library to achieve zero allocation at runtime, ensuring maximum speed and memory safety.
