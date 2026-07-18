#import "theme.typ": *
#import "figures.typ": *

#part_page("III", [A sequence of decisions], [
  A service needs more than one chosen value. We arrange decisions in slots,
  recover an old leader's work, fill holes, and apply one ordered prefix.
])

= Multi-Paxos Log Replication

== One Paxos instance per slot

Let slot 1 choose `open`. Let slot 2 choose `write A`. Let slot 3 choose `close`.
Each slot is a separate consensus problem. Safety for slot 2 says nothing about
slot 3. The log obtains its order from slot numbers.

The direct construction runs phase one and phase two in every slot. It is safe
and slow. A stable leader can prepare one ballot across all bounded slots. Once
it has a quorum of complete replies, it may run phase two for each free slot.
This is Multi Paxos.

The proof has not changed. Each slot still follows B1, B2, and B3. We have only
combined the phase one questions into fewer messages.

=== Slot numbers

The library uses one based `u32` slots. Slot zero means "no slot." The conversion
to an array index occurs in one helper.

```zig
fn slotIndex(slot: Slot) !usize {
    if (slot == 0) return error.InvalidSlot;
    if (slot > options.max_slots) return error.SlotLimitReached;
    return @as(usize, slot - 1);
}
```

Centralizing the conversion is more than tidiness. It gives one place to check
the two boundaries. An index is not a count. A slot is not an index.

== A batched prepare reply

An acceptor may have accepted values in many slots. Its response to prepare is a
series of messages:

```text
promise(ballot, slot 2, accepted ballot 7, value B)
promise(ballot, slot 5, accepted ballot 9, value E)
promise_done(ballot, accepted_count 2)
```

The network may deliver `promise_done` first. If the candidate counted the
member immediately, it could become leader without seeing value `E`. That value
might already be chosen.

The candidate therefore tracks, for each member:

+ whether the final marker arrived,
+ the number of entries promised by the marker,
+ the number of distinct entries received,
+ a Boolean per slot to reject duplicates.

A member's response is complete only when the marker exists and both counts are
equal. A quorum means a quorum of complete responses.

=== Why a count instead of FIFO

#callout([Why a count instead of FIFO], [
  TCP preserves sender order on one connection, but the Paxos safety core need
  not assume TCP. A count makes the requirement explicit and lets other
  transports reorder messages safely.
], kind: "idea")

=== Selecting recovered values

For each slot, compare every accepted ballot reported by the complete quorum.
Keep the greatest one and its value.

Consider three promise replies.

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Member*], [*Slot*], [*Ballot*], [*Value*]),
  [`N1`], [`4`], [`(6, 1)`], [`alpha`],
  [`N2`], [`4`], [`(8, 2)`], [`beta`],
  [`N3`], [`4`], [`null`], [`null`],
)

The new leader must propose `beta` in slot 4. It does not matter that `alpha`
arrived first. Arrival order is not ballot order.

The test named "phase one tolerates reordering and recovers the highest accepted
value" constructs this schedule. It sends completion markers before entries and
gives two minority acceptors different old values. The leader waits and chooses
the value from the greater ballot.

== Holes and the no op value

Suppose recovery finds a value in slot 5 but no accepted value in slot 4. The
leader must not put an important new command into slot 4 if clients may already
have observed work associated with slot 5. It fills the hole with a no op.

Lamport called this the olive day decree. It changes no application state. It
does make the log prefix complete.

The host supplies the no op value when it calls `campaign`.

```zig
try node.campaign(.{
    .client_id = 0,
    .request_id = 0,
    .operation = .noop,
}, &effects);
```

The protocol cannot invent a valid generic `Value`. Only the application knows
which value means no work.

== Learning in order

A network can deliver commit for slot 7 before commit for slot 6. The learner
records slot 7 but does not apply it. State machines must see one common prefix.

#book_figure(
  [Slots 1 through 5 may be applied. Slot 7 is known, but slot 6 blocks it.],
  log_picture(),
)

When slot 6 arrives, the learner emits both 6 and 7 in order. The field
`delivered_through` marks the prefix already returned during this process
lifetime.

Across process restart, delivery is at least once. The application must persist
its applied slot with its state. If it sees an old slot again, it ignores it.

=== Catch up

A lagging node sends:

```text
learn { from_slot }
```

The peer returns every known commit at or after that slot. The method is simple
and bounded. It is suitable for the library's fixed log. A large production
system should transfer a snapshot when the missing prefix is too large.

The catch up request may go to any member. A leader is a good choice because it
is likely to know the newest prefix. A stale peer can return only what it knows;
the learner may ask another peer later.

== Stable leader pipeline

After phase one, several slots may be in phase two at the same time. The API lets
the host call `propose` again before an earlier proposal commits. It can also use
`proposeBatch` to assign several consecutive slots in one call. Each slot has its
own compact acknowledgement bit set.

Pipelining hides network latency, but it creates a bound question. The current
library bounds slots and effect buffers at compile time. The host should also
bound client requests in flight. An unbounded input queue would move the memory
problem outside the protocol without solving it.

For a three node cluster, one stable value creates six remote protocol messages.
With `W` values in flight, a rough upper bound for protocol envelopes in the
transport is `6W`, before retries and catch up. The right `W` follows from disk
latency, network bandwidth, and the largest acceptable response time.

== Leader replacement trace

We now follow the case that makes Paxos worth learning.

#transcript((
  [1], [N1], [Leads ballot `(4, 1)` and sends accept for `red` in slot 8.],
  [2], [N2], [Persists the acceptance and replies.],
  [3], [N1], [The local vote and N2 form a quorum. `red` is chosen.],
  [4], [N1], [Crashes before sending commit.],
  [5], [N3], [Starts ballot `(5, 3)` and sends prepare.],
  [6], [N2], [Promises `(5, 3)` and reports `(4, 1), red` for slot 8.],
  [7], [N3], [Gets a complete quorum. `red` is the greatest report for slot 8.],
  [8], [N3], [Reproposes `red` in ballot `(5, 3)`.],
  [9], [N3], [Gets a quorum and announces commit.],
))

The client may have timed out at step 4. It cannot conclude that `red` failed.
It must retry with the same request identity. The state machine will recognize
the duplicate if a second slot later contains that request.

=== A value accepted by only one node

Now suppose N1 crashes before its local vote gains any remote vote. The value is
not chosen. A later leader may still recover it if N1 belongs to the new phase
one quorum and its ballot is the greatest report.

Preserving the value is conservative. It is not evidence that the old client
succeeded. It is the uniform rule that also protects values which did succeed
without an announcement.

== Reads

Consensus orders writes. Reads need a stated consistency level.

#table(
  columns: (auto, 1.2fr, 1.2fr),
  table.header([*Read*], [*Method*], [*Property*]),
  [Local], [Read the local applied state.], [Fast and possibly stale.],
  [Log barrier], [Propose a read marker and wait to apply it.], [Linearizable and
    consumes a slot.],
  [Read index], [Confirm current leadership with a quorum, then wait for the
    confirmed applied index.], [Linearizable with extra protocol support.],
  [Lease], [Use a time bounded leader lease.], [Fast, but clocks enter the
    safety argument.],
)

Version 0.1 supplies local decided reads and the log barrier through ordinary
proposals. It does not implement read index or leases. The application must not
call a local read linearizable merely because it came from the leader.

== Membership

Membership changes are consensus decisions about future quorums. A careless
switch from old members to new members can create two nonintersecting quorums.

The small `Protocol.Node` keeps membership fixed. The `ReplicatedLog.Node` places
a stop sign in the ordered log. The stop sign names the next membership and
seals the current configuration. A decided stop sign constructs the next epoch.
The transport must retain enough configuration identity to reject delayed
messages.

Other choices include joint consensus, delayed activation by slot, and
matchmaker protocols. They differ in proof and operation. This library selects
one explicit stop sign design rather than hiding several proofs behind a Boolean
option.

== Bounded logs and epochs

`max_slots` is a hard limit. A slot is never reused within an epoch. After the
last slot, `propose` returns `error.SlotLimitReached`.

Before that point, the application should:

+ persist an application snapshot and its applied slot,
+ verify the snapshot on enough nodes,
+ call `checkpoint` with an immutable snapshot reference,
+ decide the stop sign and stop proposals in the old epoch,
+ create the next epoch with `initFromStop`,
+ reject delayed envelopes from the old epoch at the transport boundary.

The core message type does not contain a configuration identifier. A production
transport must frame one outside the message. Node IDs should also remain stable
for the logical members they name.
