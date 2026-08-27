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
  sign and the memory floor do—and do not do.
])

== Why Multi-Paxos?

Classic Paxos chooses exactly one value for one slot. If we want to build a replicated log to run a database, we could run a completely separate instance of Classic Paxos for every single slot in the log. 

But this is slow! Every slot would require:
1. Phase One (Prepare & Promise) -> 1 Round Trip.
2. Phase Two (Accept & Accepted) -> 1 Round Trip.

This means every single log append takes at least two network round trips and two disk syncs.

Multi-Paxos is an elegant optimization. Instead of running Phase One for each slot, a candidate campaigns for *every unresolved slot* at the same time. Once the candidate wins a quorum of promises covering them, it becomes the stable leader.

For all subsequent slots, the leader can skip Phase One entirely and propose values in Phase Two directly! The cost of a log append drops to a single network round trip.

#book_figure(
  [Multi-Paxos runs Phase One once to establish leadership across all slots,
  allowing subsequent appends to run Phase Two in parallel with a single round trip.],
  log_picture(),
)

== Combining the Phase One Replies

How does a candidate query a log whose slots never end? It cannot ask for
"everything": slots are 64-bit and never reset, so a complete answer could be
unbounded. Phase one therefore runs in chunks. The candidate sends
`prepare (ballot, first)`, naming the first slot it wants resolved. Each
acceptor replies with its accepted votes inside that chunk, then describes
the chunk it answered:

```text
promise (ballot, slot 101, accepted_ballot 3, value "A")
promise (ballot, slot 103, accepted_ballot 4, value "C")
promise_range (ballot, first 101, last 164, accepted_count 2, more false)
```

Because the network can reorder packets, the `promise_range` descriptor might arrive before the individual slot `promise` entries. If the leader immediately declared itself ready, it might miss some accepted entries, violating safety!

To prevent this, the candidate tracks the expected entry count from `promise_range` and waits until it has received every single entry:

```zig
// Equivalent to Protocol.Node.maybeResolveChunk.
if (!peer.range_described) continue;
if (peer.received_in_range >= peer.expected_in_range) {
    complete += 1;
}
```

A member's reply is counted toward the quorum only when it is complete. This count-based tracking makes the protocol transport-independent: we do not assume TCP FIFO ordering for correctness.

When a counted member reports `more`, the candidate resolves the current
chunk and prepares again at the next one. A chunk holds at most
`recovery_chunk_slots` slots, so every recovery message and buffer is bounded
by the chunk, never by history. The descriptor also carries two fences:
`chosen_through`, the acceptor's contiguous chosen prefix, and `anchor`, its
adopted trim anchor. The elected leader takes the greatest fence reported by
the quorum and never fills, proposes, or accepts a client value at or below
it. A missing vote down there means the slot was released, not that it is
open.

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

The library prevents unbounded protocol memory with a slot-tagged consensus
window of `window_slots` physical cells, a compile-time power of two. Slot
`s` lives in cell `s & (window_slots - 1)`, tagged with its slot number, so a
reused cell can never be mistaken for an earlier occupant. A cell is reused
only after the host licenses it: `advanceMemoryFloor(through)` records that
every released entry through `through` has been durably consumed. When
`next_slot - memory_floor` would exceed the window, `propose` returns
`error.WindowFull`. That is transient flow control, not a log limit: retry
after the floor advances. The host should still impose an earlier in-flight
limit and apply client backpressure before the window fills.

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
    "registry_digest",
    &effects,
);
```

By placing the stop inside the log, the old configuration agrees on the
boundary relative to commands. The library does not automatically transfer a
snapshot, start processes, or stop old network traffic. The host must wait for
`isReconfigured()` to return the *decided* stop before calling `initFromStop`,
and must prevent the sealed old instance from serving new writes.

== Global Slots on One Line

Slots are 64-bit and global: they never reset for the lifetime of the log.
There is no "log full" event and no snapshot rollover. What the window bounds
is residency, not history: at most `window_slots` slots live in protocol
memory, and everything below the memory floor survives only in the host's
journal and materialized state. Three host duties follow.

1. *Advance the floor*: After durably consuming released entries, call
   `advanceMemoryFloor` so the window keeps moving. A stalled floor
   eventually turns every proposal into `error.WindowFull`.
2. *Adopt chosen trims*: When the cluster chooses a trim record, call
   `installChosenTrim` with its anchor. A trimmed acceptor then answers
   phase one for the released prefix from the anchor instead of from cells
   it no longer holds.
3. *Serve old history*: A peer catching up from below the memory floor cannot
   be answered from the window. The core emits a `serve_range` host request,
   and the host replies with commit envelopes read from its own journal.

An accepted-but-unchosen slot is never evicted, so no vote can be silently
forgotten. The only terminal condition is `error.GlobalSlotExhausted` at the
end of the 64-bit slot space; at one million commits per second that takes
more than 584,000 years.

A stop sign still seals a configuration, but only for membership change. The
next configuration continues the same slot line: `initFromStop` starts it at
the stop slot with the inherited trim anchor, and no slot number is ever used
twice.

#exercise([11.1], [
  A leader has delivered through slot 80 and holds accepted but undecided
  commands in slots 81 and 82. The window has 64 cells and the host has
  advanced the memory floor only to slot 40. How many new slots can the
  leader propose before `WindowFull`? What must the host do to free more,
  and why can the cells holding slots 81 and 82 never be reclaimed to do it?
])

#teach_back([
  On blank paper draw one row of eight window cells and a longer slot line
  above it. Mark the memory floor, the delivered prefix, and one accepted but
  undecided slot. Explain which cells may be retagged for later slots, what
  licenses that, and why the accepted cell must stay.
])
