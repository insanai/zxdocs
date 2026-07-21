#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [The Zig library], [
  The proof becomes a bounded state machine. The host owns disk, network, time,
  and application state. The boundary between them is the main API.
])

= Bounded Core State Machine

#objectives([
  By the end of this chapter you should be able to instantiate `Protocol`, run
  each public transition, drain one `Effects` batch safely, replay durable
  records, and identify every service the host must provide.
])

== Design Philosophy: Consensus Without I/O

This library deliberately excludes sockets, threads, filesystem calls, codecs,
and wall-clock reads. The protocol is a deterministic, *mutating* effect
machine: a call changes `Node` immediately and describes required external
actions in caller-owned `Effects`. It is not a pure function and its in-memory
state is not a substitute for the returned durable writes.

Instead, the library acts as a state engine that takes an input event, updates its internal state, and writes its decisions to a caller-supplied *Effect Buffer*. 

#book_figure(
  [The deterministic consensus core receives input events and outputs effects.
  The host application owns the actual execution of disk and network writes.],
  effects_flow(),
)

This design gives the host application complete freedom:
+ The same core can be hosted by TCP, QUIC, a thread pool, or a simulator.
+ Tests can control message delivery and reconstruct nodes from selected
  durable writes. The repository's unit-test harness is deterministic; it is
  not yet a general seeded crash simulator.
+ The critical "persist before durable claim" invariant is explicit at the
  host call site; the core separately classifies the narrow request-only class
  a host may pipeline while its barrier runs.

== Defining the Protocol Configuration

To use the library, you define your state machine Command type and set compile-time bounds:

```zig
const paxos = @import("paxos");

// Your application command
const Command = struct {
    client_id: u128,
    request_id: u64,
    operation: enum { put, delete },
    key: [32]u8,
    value_hash: [32]u8,
};

// Instantiate the protocol module
const Consensus = paxos.Protocol(Command, .{
    .max_members = 5,
    .max_slots = 16_384,
});
```

=== Comptime Pointer Protection
A critical safety invariant is that message payloads must be self-contained. If `Command` contained a pointer (e.g., `[]const u8`), that pointer would only point to memory in the sender's address space. It would be meaningless to a remote peer receiving the message over the network.

To protect you from this class of bugs, our library uses *comptime metaprogramming reflection*. When you instantiate `paxos.Protocol(Command, ...)`:
- The library scans the `Command` struct at compile time.
- If it detects any pointers, slices, or references, it halts compilation with a clear error:
  `"Value type '...' must not contain pointers, slices, or references."`
- This forces the protocol value to own its in-memory bytes. The host must
  still define a versioned, canonical wire and journal encoding and validate
  decoded lengths and enum tags before constructing an envelope.

#api_anchor([`paxos.Protocol(Value, options)`], [
  Generates a concrete family of message, durable-state, effect, membership,
  and node types. A message or write from a differently configured family is
  not wire-compatible merely because its Zig fields look similar.
], source: [`src/protocol.zig`])

== The Effect Contract

When you feed an event into the node, you pass a reference to an `Effects` buffer. The node writes its actions to this buffer. *You must execute these effects in a strict order*:

```zig
// 1. Deliver the envelope to the node
try node.step(envelope, &effects);

// 2. Write and sync to disk journal FIRST
for (effects.writesSlice()) |write| {
    try journal.append(write);
}
try journal.sync(); // Blocking sync

// 3. Send network messages SECOND
for (effects.messagesSlice()) |message| {
    try transport.send(message);
}

// 4. Apply released entries in slot order.
for (effects.committedSlice()) |entry| {
    try db.apply(entry.slot, entry.value);
}
```

All writes in one batch must be appended in slice order and made durable before
*any* message from that batch leaves. Do not invoke another node transition
until the batch has been consumed: every public transition resets the active
effect counts and may overwrite the backing arrays. Application delivery can
follow the sends, as above, but the host must atomically persist its state
machine mutation and applied-slot cursor if it needs exactly-once effects.

#warning([A failed sync invalidates the live node], [
  The call has already mutated `Node`. If append or sync fails, stop using that
  in-memory node. Terminate or discard it, repair storage, replay only verified
  durable records into a fresh `DurableState`, restore a fresh node, and repair
  application state independently.
])

== The public transition surface

#table(
  columns: (1.1fr, 1.8fr),
  table.header([*Operation*], [*Host event and result*]),
  [`init`, `restore`], [Bootstrap empty state or reconstruct protocol state
    from replayed `DurableState`.],
  [`campaign(noop)`], [Start phase one explicitly.],
  [`tick(noop)`], [Advance logical failure detection, heartbeat, and resend
    counters by one host-defined interval.],
  [`step(envelope)`], [Process one already decoded, validated, authenticated,
    correctly routed member message.],
  [`propose`, `proposeBatch`], [Assign one or more slots on a prepared leader.],
  [`reconnected`], [Ask the current role to repair one restored peer link.],
  [`requestCatchUp`], [Emit `learn` for a nonzero starting slot.],
  [`committedAt`, `readDecided`], [Inspect learned values; these are log-state
    reads, not linearizable application reads.],
  [`currentLeader`, `decidedThrough`], [Return diagnostic hints and the released
    contiguous prefix.],
)

Every operation can return an error before producing a useful batch. Initialize
an `Effects` value once with `effects.init()`, then let each transition reset
its counts. Use `paxos.explainError(err)` for an operator-facing explanation;
do not treat every error as retryable.

== Metaprogramming and Bounds Optimization

We want the library to support thousands of slots without wasting CPU cycles.
To solve this, we optimized our custom `BitSet` implementation:

```zig
// The hybrid BitSet adapts to the size at compile time
pub fn BitSet(comptime size: usize) type {
    if (size <= 64) {
        return struct {
            bits: std.meta.Int(.unsigned, size) = 0,
            // Inline bit shifting...
        };
    } else {
        const word_count = (size + 63) / 64;
        return struct {
            words: [word_count]u64 = .{0} ** word_count,
            // Array word shifting...
        };
    }
}
```

For at most 64 elements the backing integer has exactly the requested bit
width—`BitSet(7)` occupies one byte in the current test. Larger sets use a
fixed array of `u64` words. This is an implementation detail worth measuring,
not a promise that a particular compiler will choose one instruction.

== Restoring State After a Crash

When a node restarts, it does not keep any volatile leadership or voter memory. It reconstructs its stable consensus state simply by replaying its journal:

```zig
var durable: Consensus.DurableState = .{};

// Replay records from disk
for (records) |record| {
    try durable.apply(record);
}

var node: Consensus.Node = undefined;
try node.restore(my_node_id, &membership, &durable);
```

Upon restore, the node is a follower. A later heartbeat can identify a leader;
enough `tick` calls can start a campaign. Phase one recovers accepted protocol
values from a complete read quorum.

`restore` does not restore your database, client sessions, snapshot files,
transport queues, or authentication state. It also resets the volatile
delivery cursor. Restore the application state and its applied slot from the
host's own durable data; if that cursor trails committed journal records,
replay those values idempotently before serving traffic. Do not wait for
`committedSlice()` to reconstruct the entire old application state.

#teach_back([
  Draw a vertical boundary labeled library/host. Place `Node`, `Effects`,
  journal bytes, socket bytes, tick scheduling, application state, and snapshot
  files on the correct side. Add one arrow that is forbidden until an `fsync`
  succeeds.
])
