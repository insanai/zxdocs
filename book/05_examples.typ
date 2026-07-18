#import "theme.typ": *
#import "figures.typ": *

#part_page("V", [Three worked systems], [
  We run the repository's counter, complete a key-value host design, and review
  a regional control-plane architecture. Guidance fades as the systems grow.
])

= Three Worked Systems

#objectives([
  By the end of this part you should be able to trace the runnable counter's
  effect loop, add durable request deduplication and explicit read semantics,
  and decompose a larger service into independently recoverable shards without
  inventing guarantees the library does not provide.
])

== Small Example: The Replicated Counter

*Status: complete runnable repository example.* Run it with `zig build run`.

The command in `examples/counter.zig` is self-contained:

```zig
const Command = struct {
    client: u32,
    request: u32,
    operation: enum { noop, add },
    amount: i64,
};

const P = paxos.Protocol(Command, .{
    .max_members = 3,
    .max_slots = 32,
});
```

The example initializes three nodes, campaigns node 1 with a no-op, proposes
three `add 10` commands, and drains every generated envelope. The central
function is not `propose`; it is the effect consumer:

```zig
// Repository excerpt: examples/counter.zig
for (effects.writesSlice()) |write|
    try disks[node_index].apply(write);

for (effects.messagesSlice()) |message| {
    queue[queue_count.*] = message;
    queue_count.* += 1;
}

for (effects.committedSlice()) |entry| {
    if (entry.value.operation == .add)
        counters[node_index] += entry.value.amount;
}
```

All three counters reach 30. `DurableState` and the queue are memory in this
demonstration. The ordering is real; durability and transport are simulated.
The `client` and `request` fields are unique in the workload, but the demo does
not deduplicate them.

#exercise([16.1], [
  Change only the in-memory delivery schedule so the final queued envelope is
  delivered first. Predict the counters before running. Next deliver one
  envelope twice. Which library test gives confidence about protocol
  idempotence, and what application behavior is still untested?
])

== Middle Example: A Key-Value Host

*Status: design sketch.* `BoundedMap`, `Result`, journal, codec, snapshot store,
and client service are not supplied by this repository.

A key-value service may order hashes that reference separate immutable blob
storage. It also has to resolve client retry ambiguity: a write may commit even
when its reply is lost.

=== A bounded request discipline

One compact design permits at most one outstanding request per client and
persists the most recent ID and result with the application state:

```zig
const ClientRecord = struct {
    request_id: u64,
    result: Result,
};

const State = struct {
    values: BoundedMap([64]u8, [32]u8),
    clients: BoundedMap(u128, ClientRecord),
    applied_slot: paxos.Slot,
};
```

The application transition must advance through duplicate log slots even when
it suppresses a duplicate mutation:

```zig
// Design sketch, not repository code.
fn apply(state: *State, slot: paxos.Slot, command: Command) !Result {
    std.debug.assert(slot == state.applied_slot + 1);

    if (state.clients.get(command.client_id)) |record| {
        if (command.request_id <= record.request_id) {
            state.applied_slot = slot;
            return record.result;
        }
    }

    const result = switch (command.operation) {
        .noop => Result.noop,
        .put => try state.values.put(command.key, command.value_hash),
        .remove => state.values.remove(command.key),
        .read_barrier => Result.barrier,
    };
    try state.clients.put(command.client_id, .{
        .request_id = command.request_id,
        .result = result,
    });
    state.applied_slot = slot;
    return result;
}
```

Persist `values`, `clients`, and `applied_slot` atomically and include all three
in snapshots. The one-record scheme is correct only with monotonically
increasing IDs and at most one outstanding request per client. Concurrent or
out-of-order requests need a bounded per-request result table and an explicit
garbage-collection rule.

=== Reads are an application protocol

`committedAt` and `readDecided` inspect local protocol state; they do not prove
that a node is still leader or caught up at the instant of a read. A simple
linearizable design proposes a `read_barrier` through the leader, waits until
its slot is applied locally, then reads the database. This costs consensus. A
lease or read-index optimization requires reasoning outside the current API.
A follower may serve stale reads only when the service contract permits them
and should return a version such as configuration ID and applied slot.

#exercise([17.1], [
  Complete the crash-recovery design: order snapshot verification, journal
  replay, `Node.restore`, application replay, transport activation, and opening
  the client listener. Mark the point before which a response would be unsafe.
])

== Large Example: Regional Control Plane

*Status: architecture review exercise, not runnable code.*

Assume five voters across three failure zones and many independent routing
partitions. One leader and one journal can become a bottleneck, so partition
commands by a stable routing key and run one sealed log per shard:

```zig
const Shard = paxos.ReplicatedLog(Command, .{
    .max_members = 5,
    .max_entries = 32_768,
    .max_batch = 64,
    .max_metadata_bytes = 96,
});
```

+ *Protocol independence*: Each shard has its own ballot, slots, stop sign, and
  bounds.
+ *Resource isolation*: This exists only if the host also bounds per-shard
  queues and schedules journal, CPU, and network work fairly.
+ *Parallelism*: Different shard journals may progress concurrently when the
  storage system supports it.

A command containing only a blob hash creates another ordering obligation:
replicate and verify the immutable blob before proposing the command that makes
the hash visible, or define deterministic missing-blob recovery before apply.
Paxos orders the hash; it does not store the blob.

=== Regional partition drill

If one zone containing two voters is isolated, the remaining three can form a
default majority and campaign. The isolated two cannot make progress and must
not accept service writes. They may serve versioned stale reads only if that is
an explicit control-plane policy.

After healing, `reconnected` and same-epoch `requestCatchUp` can repair missing
commits. If the active side moved to a new epoch, the host must install the
verified snapshot and configuration chain before a returning node votes.

#teach_back([
  Explain the regional design to an operator using three columns: guaranteed by
  `ReplicatedLog`, required from the host, and merely a proposed service policy.
  Place write ordering, blob availability, stale reads, authentication, and
  snapshot transfer in the correct column.
])
