#import "theme.typ": *
#import "figures.typ": *

#part_page("V", [Three worked systems], [
  We now build a small counter, a useful key value service, and a large regional
  control plane. Each example keeps the same protocol and adds one engineering
  layer at a time.
])

= Three Worked Systems

== Small Example: The Replicated Counter

The simplest useful state machine is a replicated counter. We run it on three nodes, and the application state is a single integer.

Our command structure is small:

```zig
const Command = struct {
    client: u32,
    request: u32,
    operation: enum { noop, add },
    amount: i64,
};

const Consensus = paxos.Protocol(Command, .{
    .max_members = 3,
    .max_slots = 32,
});
```

To run the counter:
1. *Initialize*: Set up three nodes with a shared membership configuration.
2. *Campaign*: Propose a No-Op to establish leadership for Node 1.
3. *Propose*: Submit `add 10` requests to the leader.
4. *Apply*: When commits are reported, update the local counter:

```zig
for (effects.committedSlice()) |entry| {
    if (entry.value.operation == .add) {
        counter += entry.value.amount;
    }
}
```

If we propose `add 10` three times, every node applies the entries in order, and all three counters reach exactly `30`.

== Middle Example: The Key-Value Store

In a key-value service, we map string keys to hashes referencing separate blob storage. This system introduces the challenge of *client retry ambiguity*.

Imagine a client sends `put("key1", hashA)`. The write commits successfully, but the network drops the leader's reply. The client does not know if the write succeeded. It must retry. 

If we simply write the retry to the log in a new slot, the state machine will execute the request twice. If the operation is a simple write, it might be harmless, but for increment or append operations, duplicate execution violates application semantics.

=== Making Operations Idempotent

To solve this, our state machine keeps a *Client Deduplication Table*. It maps each `client_id` to its last completed `request_id` and the result of that operation:

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

When applying a committed command:

```zig
fn apply(state: *State, slot: paxos.Slot, command: Command) !Result {
    std.debug.assert(slot == state.applied_slot + 1);

    // 1. Check for duplicates
    if (state.clients.get(command.client_id)) |record| {
        if (command.request_id <= record.request_id) {
            // Already applied! Return the cached result.
            return record.result;
        }
    }

    // 2. Apply mutation
    const result = switch (command.operation) {
        .noop => Result.noop,
        .put => try state.values.put(command.key, command.value_hash),
        .remove => state.values.remove(command.key),
        .read_barrier => Result.barrier,
    };

    // 3. Update client record
    try state.clients.put(command.client_id, .{
        .request_id = command.request_id,
        .result = result,
    });
    state.applied_slot = slot;
    return result;
}
```

Now, if a client retries request 42, the command is written to two slots (say, Slot 14 and Slot 15). The state machine executes it in Slot 14, caches the result, and ignores Slot 15, returning the cached result. Consensus orders the log slots; the application table makes those slots idempotent.

== Large Example: Regional Control Plane

For a global workload placement service, we must manage routing updates for 50,000 edge routers. We choose five voting nodes placed across three geographic zones: Dublin, London, and Frankfurt.

=== Scaling with Shards

A single Multi-Paxos log cannot scale to handle tens of thousands of writes per second because a single leader becomes a CPU and disk bottleneck.

We solve this by *Sharding*. We partition our routing table updates into 10 separate zones. Each zone runs its own independent `ReplicatedLog` instance on the same physical nodes:

```zig
const Shard = paxos.Protocol(Command, .{
    .max_members = 5,
    .max_slots = 32_768,
});
```

- *Isolation*: A disk failure or queue backlog in Zone 1 does not block consensus in Zone 2.
- *Parallelism*: Nodes can write to different shard journals concurrently, maximizing disk throughput.
- *Independence*: Epoch transitions and slot limits are managed separately for each shard.

=== Handling Regional Partitions

Suppose a fiber cut completely isolates the Dublin datacenter (N1, N2). 

The London datacenters (N3, N4) and Frankfurt datacenter (N5) still have three active nodes. Since three out of five form a majority, they can campaign, elect N3 as leader, and continue proposing updates for all shards.

Dublin edge routers will detect the partition. They can still serve local stale reads from their database snapshots, but they will reject writes until the fiber is repaired. Once the network heals, N1 and N2 catch up by requesting missing commits, restoring the cluster to full health.
