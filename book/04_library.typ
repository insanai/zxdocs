#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [The Zig library], [
  The proof becomes a bounded state machine. The host owns disk, network, time,
  and application state. The boundary between them is the main API.
])

= Bounded Core State Machine

== Design Philosophy: Consensus Without I/O

Most consensus libraries try to do too much. They spin up threads, create TCP sockets, read from the system clock, and manage file streams. This makes them difficult to test, debug, and port.

Our library takes a completely different approach. The core protocol is a *pure, deterministic state machine*. It performs no input/output (I/O). It does not allocate memory. It does not read the clock. 

Instead, the library acts as a state engine that takes an input event, updates its internal state, and writes its decisions to a caller-supplied *Effect Buffer*. 

#book_figure(
  [The pure consensus core receives input events and outputs side effects.
  The host application owns the actual execution of disk and network writes.],
  effects_flow(),
)

This design gives the host application complete freedom:
+ The same consensus core runs inside TCP, QUIC, a thread pool, or a discrete-event simulator.
+ Tests can control the exact message delivery order and trigger crashes at any instruction.
+ The critical "write before send" invariant is explicitly enforced and visible at the host call site.

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
  `"Command payload type must not contain runtime pointers or references"`
- This forces you to use fixed-size arrays, inline values, or content hashes, guaranteeing safety at zero runtime cost.

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

// 4. Apply committed entries to the state machine THIRD
for (effects.committedSlice()) |entry| {
    try db.apply(entry.slot, entry.value);
}
```

This sequence is the physical representation of the Paxos proof: *writes to disk must be durable before messages leave the machine.* If a write fails, you must crash the process; continuing with volatile memory state violates safety.

== Metaprogramming and Bounds Optimization

We want the library to support thousands of slots without wasting CPU cycles.
To solve this, we optimized our custom `BitSet` implementation:

```zig
// The hybrid BitSet adapts to the size at compile time
pub fn BitSet(comptime size: usize) type {
    if (size <= 64) {
        return struct {
            bits: u64 = 0,
            // Inline bit shifting...
        };
    } else {
        const words = (size + 63) / 64;
        return struct {
            bits: [words]u64 = .{0} ** words,
            // Array word shifting...
        };
    }
}
```

If your cluster size is small (e.g., `max_members = 5`), the voter bitmaps fit in a single 64-bit CPU register. The compiler emits fast register shift operations. If you configure a large log (e.g., `max_slots = 32_768`), the slot bitmaps automatically scale to use compact, cache-friendly array backings, preventing compilation bottlenecks.

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

Upon restore, the node enters the follower role. It will wait for heartbeats from the current leader. If no leader speaks before the election timeout, it will campaign to recover leadership. The Paxos query phase guarantees that the new campaign will discover any previously accepted values on disk.
