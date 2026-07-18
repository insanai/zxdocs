#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [The Zig library], [
  The proof becomes a bounded state machine. The host owns disk, network, time,
  and application state. The boundary between them is the main API.
])

= Design before syntax

The library performs no input or output. It starts no thread. It reads no clock.
It allocates no memory after initialization. A node consumes one input and fills
one caller supplied effect buffer.

This design is useful for three reasons.

+ The same core works inside TCP, QUIC, an actor runtime, or a simulator.
+ A test can choose every delivery order and crash point.
+ The write before send rule is visible at the call site.

The cost is also visible. The host must supply real storage, a transport, tick
delivery, serialization, snapshots, and a deterministic state machine. The
library is a consensus component. It is not a server process.

#book_figure(
  [One input creates three kinds of effects. Durable writes are consumed first.],
  effects_flow(),
)

= Package use

For a tagged Codeberg release, ask Zig to compute the archive hash.

```sh
zig fetch --save \
  https://codeberg.org/OWNER/paxos/archive/v0.1.0.tar.gz
```

The consumer's `build.zig` exposes the module.

```zig
const dependency = b.dependency("paxos", .{
    .target = target,
    .optimize = optimize,
});

const application = b.addExecutable(.{
    .name = "ledger",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "paxos",
            .module = dependency.module("paxos"),
        }},
    }),
});
```

For local work, use `.paxos = .{ .path = "../paxos" }` in `build.zig.zon`.
The fixture under `integration/consumer` compiles this exact arrangement.

= Choose the value and bounds

```zig
const paxos = @import("paxos");

const Command = struct {
    client_id: u128,
    request_id: u64,
    operation: Operation,
    key: [32]u8,
    value_hash: [32]u8,
};

const Consensus = paxos.Protocol(Command, .{
    .max_members = 5,
    .max_slots = 16_384,
});
```

The command is copied into node state and messages. A borrowed slice would copy
only a pointer and a length. That pointer might die before a message is encoded.
To guarantee safety, the library enforces at compile time (via metaprogramming
reflection) that the `Value` type contains no pointers, slices, or references.
Any attempt to instantiate a protocol with a pointer-containing type will trigger
a compilation error. Use fixed-size arrays, inline values, or content hashes
referring to separate durable blob storage.

Bounds are compile-time values. They determine the size of nodes and effect
buffers. Large bounds can create large stack objects. To avoid compilation
bottlenecks on large bitsets, the library optimizes its bitset representation:
bitsets of size at most 64 (such as `MemberSet` on typical clusters) are backed
by a single register-sized unsigned integer, whereas larger bitsets (such as
`SlotSet` with thousands of slots) are backed by an array of 64-bit words.
This hybrid design ensures maximum CPU shifting speed and prevents compiler
exhaustion. Long-lived nodes should normally live in stable application storage
rather than in a deeply nested call.

== Capacity calculation

Let `M` be members and `S` be slots. The important arrays are proportional to:

#table(
  columns: (1fr, auto, 1.2fr),
  table.header([*State*], [*Order*], [*Purpose*]),
  [Accepted and committed values], [`O(S)`], [Durable protocol history.],
  [Promise receipt bits], [`O(MS)` bits], [Duplicate safe phase one recovery.],
  [Acknowledgement bits], [`O(MS)` bits], [One vote per member and slot.],
  [Largest recovery output], [`O(MS)`], [Accept broadcast for recovered slots.],
)

Compile a representative configuration and inspect `@sizeOf(Consensus.Node)`.
Do not select one million slots merely because the type accepts the number.

= In place construction

The node is large. TigerStyle recommends construction in place so that an
accidental stack copy cannot hide in a return value.

```zig
var membership: Consensus.Membership = undefined;
try membership.init(&.{ 1, 2, 3 });

var node: Consensus.Node = undefined;
try node.init(1, &membership);
```

Membership rejects an empty set, zero IDs, duplicates, and a set above the
compile time bound. A node ID must belong to its membership.

The membership is copied intentionally into the node. The source is passed by
pointer because it may exceed 16 bytes and because the call site should not make
an accidental temporary copy.

= The public types

== Ballot

`Ballot` provides `order`, `lessThan`, and `eql`. Ballot zero is the initial
sentinel. Real node IDs are nonzero.

== Message and Envelope

`Message` is a tagged union. `Envelope` adds source and target node IDs. The
transport encodes the tag and payload. It must reject frames that exceed a bound
before allocating or decoding their value.

== DurableState

`DurableState` contains:

+ the highest promised ballot,
+ an optional accepted ballot and value for every slot,
+ an optional committed value for every slot.

`DurableState.apply(write)` is a reference journal replay function. It rejects
a promise that moves backward and a commit that conflicts with an earlier
commit. It asserts that no accepted ballot exceeds the highest promise.

== Effects

`Effects` contains fixed arrays and active counts. Initialize it in place once.

```zig
var effects: Consensus.Effects = undefined;
effects.init();
```

A public operation resets the counts. The caller must consume the batch before
calling the node again. Reuse the same buffer in the event loop. Constructing a
large buffer inside a hot function can clear far more memory than the active
effect entries require.

The arrays remain uninitialized beyond their active counts. Serialization must
use the slices, never the entire backing arrays. This avoids reading padding or
unused memory.

= The effect contract

Every call follows one order.

```zig
try node.step(envelope, &effects);

for (effects.writesSlice()) |write| {
    try journal.append(write);
}
try journal.sync();

for (effects.messagesSlice()) |message| {
    try transport.send(message);
}

for (effects.committedSlice()) |entry| {
    try machine.apply(entry.slot, entry.value);
}
```

Writes may be grouped in one atomic batch. Messages from that operation wait for
the batch. Commits also wait if the application state is meant to reflect only
durable protocol knowledge.

If append or sync fails, stop the node. Restore it from the last good journal.
Do not continue with the advanced in memory state.

#warning([A common integration bug], [
  Putting writes and sends on independent queues does not preserve the contract.
  The send queue may win. Use a barrier or one owner that releases messages only
  after the durable completion arrives.
])

= Campaign

```zig
try node.campaign(noop, &effects);
```

The call chooses a round greater than the attempted round, local promise, and
highest observed rejection. It clears volatile election state and broadcasts a
prepare.

The no op is retained for holes discovered by recovery. Campaign does not make
the node a leader. The node becomes a leader only after `step` has processed a
complete quorum of promise replies.

Multiple calls are safe. They create higher ballots and may harm progress. The
usual host calls `tick` and lets the configured logical timeout start a campaign.

= Propose

```zig
const slot = try node.propose(command, &effects);
```

The node must be a prepared leader. The call assigns `next_slot`, records the
local acceptance, places its durable write in effects, and sends accept messages
to remote peers. The returned slot is an address, not a success result.

When the last bounded slot is used, `next_slot` becomes zero. The next proposal
returns `error.SlotLimitReached`. Saturating arithmetic is not used because it
could reuse the final slot.

= Step

`step` accepts one envelope. It rejects a wrong recipient and a source outside
membership. The message tag selects a small handler.

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Message*], [*Main state*], [*Possible output*]),
  [`prepare`], [Promise and accepted log.], [`promise`, `promise_done`, or `nack`.],
  [`promise`], [Recovery candidate per slot.], [Leader recovery when complete.],
  [`promise_done`], [Expected entry count.], [Leader recovery when complete.],
  [`accept`], [Promise and accepted value.], [`accepted` or `nack`.],
  [`accepted`], [Member bitmap per slot.], [`commit` after quorum.],
  [`commit`], [Committed value and prefix.], [Contiguous application entries.],
  [`learn`], [Known commits.], [`commit` replies.],
  [`nack`], [Observed round and role.], [No immediate output.],
  [`heartbeat`], [Leader contact and ballot.], [`nack` if stale.],
)

The parent `step` owns the branch. Leaf handlers perform one protocol duty. This
keeps control flow flat and each function below the TigerStyle 70 line limit.

= Request catch up

```zig
try node.requestCatchUp(peer, first_missing_slot, &effects);
```

The peer must be in membership and the slot must be nonzero. The method emits a
single learn request. The caller can retry another peer after its own timeout.

= Restart

Journal replay builds a `DurableState`. Restore writes into an existing node.

```zig
var durable: Consensus.DurableState = .{};
for (records) |record| try durable.apply(record);

var node: Consensus.Node = undefined;
try node.restore(my_id, &membership, &durable);
```

Volatile leadership, acknowledgements, proposals, and partial promise replies
are discarded. The node restarts as a follower. This is safe because a later
campaign recovers accepted state from a quorum.

= Serialization

The generic library does not prescribe bytes. A production frame should include:

#table(
  columns: (auto, 1fr),
  table.header([*Field*], [*Purpose*]),
  [Magic and version], [Reject unrelated or incompatible frames.],
  [Cluster and epoch ID], [Reject delayed traffic from another deployment.],
  [Source and target], [Authenticate routing identity.],
  [Message tag], [Select the union payload.],
  [Payload length], [Bound decode work before allocation.],
  [Checksum or MAC], [Detect corruption or authenticate the sender.],
)

Integer byte order must be fixed. Unknown versions and tags must be rejected.
Do not cast a network byte slice directly to a Zig struct. Padding and host byte
order are not a wire format.

= Storage format

Journal records should be framed separately from network records. One practical
layout is:

```text
record_length | record_version | record_tag | payload | checksum
```

On recovery, scan from the beginning or from a trusted checkpoint. Verify each
length and checksum. Stop at a torn final record. Reject corruption in the
middle. Apply records in order.

The applied state machine index belongs in the application snapshot. Persist the
snapshot and index atomically. Protocol commit delivery after restart is at least
once, so the index prevents a second application.

= Errors and assertions

Operating errors are returned. Examples are invalid membership, wrong recipient,
not leader, and slot exhaustion. Programmer and invariant errors are assertions.

The core asserts that:

+ the local node remains a member,
+ counts remain inside their arrays,
+ accepted ballots do not exceed the promise,
+ slots and delivered prefixes remain bounded,
+ a local accept never goes below the promise.

Assertions turn silent state corruption into a stopped node. In consensus, a
stopped node is usually safer than a node that continues with impossible state.

= TigerStyle audit

The implementation applies the relevant rules as design constraints.

#table(
  columns: (1.2fr, 1.8fr),
  table.header([*Rule*], [*Application*]),
  [Bound everything.], [Members, slots, messages, writes, commits, and loops have
    compile time bounds.],
  [No allocation after init.], [The consensus core contains no allocator.],
  [Simple control flow.], [No recursion. Message dispatch is one explicit switch.],
  [Assert invariants.], [Public boundaries and buffer mutations use paired
    assertions.],
  [Keep functions short.], [Core functions remain below 70 lines.],
  [Keep lines short.], [The format check enforces at most 100 columns.],
  [Initialize large values in place.], [`Membership`, `Node`, and restore use
    destination pointers.],
  [Explain why.], [Comments describe safety reasons rather than restating syntax.],
  [Zero runtime dependencies.], [The published Zig module imports only Zig std.],
)

`usize` appears where Zig slices and arrays require an index or length. Protocol
identities and counters that cross the API use explicit `u32`, `u64`, or `u16`
types. This is a deliberate boundary between machine indexing and protocol data.
