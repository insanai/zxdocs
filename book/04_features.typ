#import "theme.typ": *
#import "figures.typ": *

= The complete log interface

The small `Protocol` type exposes the proof. The `ReplicatedLog` type exposes the
shape most applications need. It orders commands, seals configurations, carries
snapshot references, and keeps every storage decision bounded.

This chapter is a tour of the complete interface. We shall begin with time. We
shall end with a new parliament.

== One owner and one reusable buffer

A node should have one owner. The owner may be an actor, an event loop task, or
a thread. It supplies one effect buffer and reuses it for every call.

```zig
var effects: Log.Effects = undefined;
effects.init();

try node.tick(noop, &effects);
try consume(&effects);

try node.step(envelope, &effects);
try consume(&effects);
```

The call to `init` changes only three counts. It does not clear the large fixed
arrays behind them. Every public node operation later calls `reset`, which also
changes only the counts.

#warning([Do not construct the buffer in a hot loop], [
  A bounded effect buffer can be large. Writing `var effects = Effects{}` inside
  a per message function may cause the compiler to clear the complete object.
  Construct it once, call `init`, and pass its address. A profiler found this
  exact mistake in the first benchmark.
])

The owner consumes the effects before the next call. It never keeps a slice from
an old effect batch. The next operation is allowed to overwrite those entries.

== Logical time

The library reads no wall clock. The host calls `tick` at a stable interval.
The interval might be ten milliseconds. It might be one simulator step. Paxos
cares about the order of calls, not the name of the clock.

```zig
try node.tick(noop_command, &effects);
```

A follower counts ticks since useful leader contact. At
`election_timeout_ticks` it starts a campaign. A leader uses the same call to
send heartbeats and to scan its bounded log for work that should be resent.

#book_figure(
  [One logical tick drives three explicit duties. Only one branch is active for
  the current role.],
  tick_flow(),
)

The three intervals have different purposes.

#table(
  columns: (1.3fr, auto, 1.7fr),
  table.header([*Option*], [*Default*], [*Meaning*]),
  [`election_timeout_ticks`], [10], [A follower campaigns after this much
    silence.],
  [`heartbeat_interval_ticks`], [3], [A leader reminds followers that its ballot
    is active.],
  [`resend_interval_ticks`], [10], [A leader repairs missing accept and commit
    traffic.],
)

The host should not call every node at exactly the same instant forever. Give
preferred nodes a greater priority. Stagger process starts. A simulator should
also test repeated ties. Safety does not depend on a lucky schedule. Prompt
election does.

== Ballot priority

A ballot contains a round, a priority, and a node ID. Comparison uses that order.

```text
(round, priority, node)
```

The round is most important. No priority can defeat a later round. Priority
breaks a tie between candidates that begin the same round. The node ID breaks
the final tie and makes every ballot unique.

```zig
try node.initWithPriority(my_id, &membership, 100);
```

Choose priority from a stable operational fact, such as a preferred region or a
machine class. Do not change it on every tick. An unstable preference creates
work and explains nothing.

== Heartbeats

A heartbeat names the active ballot. It contains no command. A follower rejects
an older heartbeat and observes a current one as leader contact. Accept and
commit messages also count as leader contact, so a busy cluster does not need a
heartbeat for every interval.

A heartbeat is not a lease. It does not prove that the sender still owns a
quorum at the moment an application read begins. A linearizable read must use a
protocol that confirms leadership with a quorum, or it must be represented by a
log entry. The local read methods in this library report decided local state.

== Retransmission

At the resend interval, a leader walks the bounded slot array. For each peer it
sends known commits and active accepts. This is deliberately simple. It has a
finite upper bound and it repairs lost traffic without a second data structure.

The scan costs `members * slots` in the worst case. Choose `max_entries` with
that fact in mind. A host with a very large retained log can call `reconnected`
when a transport returns and can use checkpoints before periodic scans become
expensive.

```zig
try node.reconnected(peer_id, &effects);
```

A leader resends that peer's known state. A follower that reconnects to its
leader asks for commits after its delivered prefix. The transport owns backoff,
connection state, packet size, and congestion control.

== Flexible quorums

Classic Paxos usually uses a majority in both phases. This library also accepts
different read and write quorum sizes.

```zig
const P = paxos.Protocol(Command, .{
    .max_members = 5,
    .max_slots = 8192,
    .read_quorum_size = 4,
    .write_quorum_size = 2,
});
```

The word read here means phase one. It does not mean an application query. The
word write means phase two.

For `N` members, safety requires:

```text
read quorum + write quorum > N
```

Every phase one quorum must intersect every phase two quorum. Two phase two
quorums need not intersect for the same leader ballot because an acceptor will
not accept two values for one ballot and slot. Leader recovery is the operation
that must meet an earlier chosen value.

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*N*], [*Read*], [*Write*], [*Use*]),
  [3], [2], [2], [The ordinary majority rule.],
  [5], [4], [2], [Cheap steady writes and expensive leader replacement.],
  [5], [2], [4], [Expensive steady writes and cheaper leader replacement.],
  [5], [3], [3], [The ordinary majority rule.],
)

The membership constructor rejects zero sizes, sizes above membership, and a
pair that does not intersect. This turns a proof obligation into a checked
configuration.

== Batch proposal

`proposeBatch` assigns consecutive slots and returns one combined effect batch.

```zig
var slots: [32]paxos.Slot = undefined;
const assigned = try node.proposeBatch(commands, &slots, &effects);
```

The caller owns `slots`. The library allocates nothing. Every command still has
its own Paxos slot and its own accept envelope. The combined effect batch lets a
host encode several envelopes into one network packet and place several durable
records in one storage transaction.

The `ReplicatedLog` wrapper calls this operation `appendBatch`. Its `max_batch`
option bounds temporary entry conversion.

Batching has three different meanings. Keep them separate.

#table(
  columns: (1.1fr, 1.9fr),
  table.header([*Kind*], [*Meaning*]),
  [API batching], [One call assigns several slots and fills one effect buffer.],
  [Storage batching], [One journal transaction or sync covers several writes.],
  [Wire batching], [One transport frame carries several envelopes.],
)

The library supplies the first. Its effect boundary makes the second and third
possible. The host chooses their byte format and latency limit.

== Compact vote sets

Duplicate votes must not count twice. The direct representation is one Boolean
per member and slot. The C implementations studied for this library suggested a
smaller representation: a bit vector.

`BitSet(K)` uses exactly `K` bits. Insertion sets one bit and reports whether the
set changed. Quorum counting uses a population count. Phase one receipt sets use
one bit per slot. Phase two vote sets use one bit per member.

This design has four useful properties.

+ no allocator is needed,
+ duplicate detection is constant time,
+ storage is compact and contiguous,
+ the code still says `insert` and `count` instead of exposing shifts everywhere.

The abstraction is small because readability counts. An optimization that
forces every protocol handler to repeat a bit mask expression is too expensive
to maintain.

= Reconfiguration by stop sign

A fixed membership is easy to reason about. A changing membership is not. The
safe method used here gives each membership its own configuration and puts one
special value at the end.

That value is a stop sign.

#definition([Stop sign], [
  A log entry that names the next configuration and optional snapshot metadata.
  Once accepted, the current `ReplicatedLog` remains sealed. Once decided, the
  next configuration may be initialized from it.
])

#book_figure(
  [A stop sign is the final ordered fact of one configuration and the first
  trusted fact used to construct the next.],
  epoch_flow(),
)

The entry contains:

+ a strictly greater configuration ID,
+ a bounded member list,
+ a bounded metadata byte string.

```zig
const slot = try node.reconfigure(
    42,
    &.{ 2, 3, 4, 5, 6 },
    "snapshot:sha256:...",
    &effects,
);
```

The metadata is protocol data. Keep it small. It may name a snapshot, schema,
encryption key, or deployment record. Large snapshot bytes belong in an object
store or a transfer protocol.

== Why the log seals on acceptance

Suppose a leader accepts a stop sign locally and then loses leadership. The stop
sign may or may not already be chosen. If the old node later appends commands
beyond it, recovery must distinguish two incompatible ideas of where the
configuration ended.

The wrapper chooses the simple rule. An accepted stop sign seals the local log.
This remains true after journal replay. The node may still process protocol
messages and help finish recovery. It may not accept new application appends in
that configuration.

This rule can be conservative. A stop sign that never becomes chosen can leave
one process sealed until the deployment resolves the configuration transition.
The gain is a clear invariant: no local command is proposed beyond a stop that
the same durable state remembers.

== Starting the next configuration

After the stop sign is decided and its preceding prefix is applied, construct a
fresh node.

```zig
const stop = node.isReconfigured().?;

var next_membership: Log.Membership = undefined;
var next: Log.Node = undefined;
try next.initFromStop(
    my_id,
    &stop,
    &next_membership,
    leader_priority,
);
```

A removed node cannot initialize because its ID is not in the new membership.
The old node and old journal should remain available until the new configuration
has installed the required state and the operator's retention rule permits
deletion.

Messages need a configuration ID in their outer frame. The generic core does
not add one to `Envelope` because deployments already need a cluster ID, wire
version, and authenticated sender. The decoder must route a message to the node
for exactly that configuration. A delayed packet from configuration 41 must not
enter configuration 42.

== Checkpoint epochs

The protocol log is bounded. Before its final slot, create an application
snapshot and seal the epoch with `checkpoint`.

```zig
_ = try node.checkpoint(snapshot_reference, &effects);
```

Checkpoint keeps the same member list and increments the configuration ID. The
stop metadata names the snapshot. The next node begins with an empty bounded
protocol log while the application begins with the installed snapshot state.

The safe order is:

+ apply all decided commands through slot `K`,
+ write a snapshot that includes state and `K`,
+ make the snapshot durable and retrievable,
+ propose a checkpoint that names it,
+ wait until the stop sign and its prefix are decided,
+ initialize the next epoch from that stop sign,
+ discard old data only after the retention rule is satisfied.

The snapshot reference must identify immutable bytes. A path whose contents can
change is not an identity.

= Reads and catch up

The core offers three local views.

#table(
  columns: (1.1fr, 1.9fr),
  table.header([*Method*], [*Answer*]),
  [`committedAt(slot)`], [The locally known decided value for one valid slot.],
  [`decidedThrough()`], [The highest contiguous slot released to the
    application.],
  [`readDecided(from, out)`], [A caller owned copy of a decided contiguous
    suffix.],
)

These are local reads. They do not contact a quorum. A follower may be behind.
For a stale tolerant endpoint, return the local prefix and its slot. For a
linearizable endpoint, use a quorum confirmed leadership method or put the read
barrier in the log.

A missing follower asks a peer for commits.

```zig
try node.requestCatchUp(peer, first_missing_slot, &effects);
```

The peer returns each known commit from that slot. The requester releases values
only when the prefix is contiguous. If the gap is large, transfer a checkpoint
instead of replaying the complete retained log.

= What remains with the host

The library is complete as a bounded consensus state machine. A production
system is larger. The following duties remain explicit.

#table(
  columns: (1fr, 2fr),
  table.header([*Duty*], [*Required host rule*]),
  [Journal], [Append all writes in order and sync before any related send.],
  [Transport], [Authenticate source, bound frames, retry, and apply backpressure.],
  [Encoding], [Use a versioned byte format independent of Zig struct layout.],
  [Clock], [Call `tick` at a documented interval and test delayed calls.],
  [Snapshots], [Atomically bind application state to its applied slot.],
  [Clients], [Use stable request IDs and deduplicate applied commands.],
  [Configuration], [Route every frame by cluster and configuration identity.],
  [Observability], [Record ballot, role, leader, prefix, queue depth, and errors.],
)

OmniPaxos includes more policy inside its Rust object, including a ballot leader
election protocol with a published partial connectivity progress argument,
internal batch accept messages, and live log trimming. Paxos Zig keeps policy at
the effect boundary, uses checkpoint epochs for compaction, and does not claim
the same partial connectivity guarantee. `docs/features.md` records each
difference. A feature table is more useful than a broad claim of equivalence.

= A compact operating recipe

The complete loop can now be stated in ten short sentences.

+ Construct membership and node in place.
+ Construct one effect buffer in place and call `init` once.
+ Give one owner all calls to that node.
+ Feed authenticated envelopes to `step`.
+ Call `tick` at the chosen interval.
+ Persist and sync writes before sending messages.
+ Apply committed entries once and in slot order.
+ Use request IDs for client retries.
+ Checkpoint before the bounded log is full.
+ Start a new configuration only from a decided stop sign.

Each sentence can be tested. That is the point. A consensus library becomes
usable when its obligations fit in the caller's field of view.
