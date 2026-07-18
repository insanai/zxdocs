#import "theme.typ": *
#import "figures.typ": *

#part_page("V", [Three worked systems], [
  We now build a small counter, a useful key value service, and a large regional
  control plane. Each example keeps the same protocol and adds one engineering
  layer at a time.
])

= Small example: one counter

The smallest useful state machine holds one integer. A command either does
nothing or adds an amount.

#code_file([examples/counter.zig], [
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
])

Every node starts with the same membership.

```zig
var membership: Consensus.Membership = undefined;
try membership.init(&.{ 1, 2, 3 });

var nodes: [3]Consensus.Node = undefined;
try nodes[0].init(1, &membership);
try nodes[1].init(2, &membership);
try nodes[2].init(3, &membership);
```

The example uses an in memory queue. It campaigns node 1 with a no op, routes
messages until the queue is empty, then proposes three additions of 10.

The state transition is almost too small to name.

```zig
for (effects.committedSlice()) |entry| {
    if (entry.value.operation == .add) {
        counters[node_index] += entry.value.amount;
    }
}
```

The result is:

```text
proposed request 1 in slot 1
proposed request 2 in slot 2
proposed request 3 in slot 3
replicated counters: 30, 30, 30
```

== Trace the first addition

#transcript((
  [1], [Client], [Creates request `(7, 1, add 10)`.],
  [2], [N1], [Assigns slot 1 and persists its local acceptance.],
  [3], [N1], [Sends accept to N2 and N3.],
  [4], [N2], [Persists and acknowledges. A quorum now exists.],
  [5], [N1], [Records commit and sends commit to both peers.],
  [6], [All], [Apply slot 1. Each counter becomes 10.],
))

If N3 is stopped, steps through N2 still form a quorum. When N3 returns, it asks
for commits from slot 1 and applies the same prefix.

== What this example omits

The in memory disk cannot survive a process exit. The queue has no checksum or
authentication. The client does not retry. Election is chosen by the program.
The example teaches the library boundary, not a deployment.

#exercise([21.1], [
  Drop every message to N3. Run the three additions. Restore communication and
  call `requestCatchUp(1, 1, &effects)` on N3. Predict the commit order.
])

= Middle example: a key value service

We now store named byte values. The important new problem is client ambiguity.
A client may send `put`, lose the reply, and retry. Consensus can place both
copies in different slots. The state machine must make the logical request
idempotent.

== Command and state

```zig
const Command = struct {
    client_id: u128,
    request_id: u64,
    operation: enum { noop, put, remove, read_barrier },
    key: [64]u8,
    key_length: u8,
    value_hash: [32]u8,
};

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

Large value bytes live in a content addressed blob store. Consensus orders a
32 byte hash. Before proposing, the leader makes sure the blob is durable on
enough storage nodes. Applying the command only updates the small hash map.

== Deterministic apply

```zig
fn apply(state: *State, slot: paxos.Slot, command: Command) !Result {
    std.debug.assert(slot == state.applied_slot + 1);

    if (state.clients.get(command.client_id)) |record| {
        if (command.request_id <= record.request_id) return record.result;
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

Real code must define what happens when a client sends request 9 after request
7 but request 8 is missing. One policy permits monotonic request IDs and treats
9 as superseding 8. Another stores a bounded window. The policy is application
semantics, not Paxos.

== Write request

The server path is:

+ Authenticate the client.
+ Validate key and value bounds.
+ Store the value blob and obtain its hash.
+ Construct a command with a stable request ID.
+ Forward to the known leader or propose locally.
+ Persist protocol writes before sending protocol messages.
+ Wait until the assigned slot is committed and applied.
+ Return the cached state machine result.

A connection close at any point after proposal is ambiguous. The client retries
the same `(client_id, request_id)`.

== Linearizable read

The simple method proposes `read_barrier`. When that command is applied, every
earlier chosen command has been applied. The server then reads its local map.

```zig
const barrier_slot = try node.propose(.{
    .client_id = client_id,
    .request_id = request_id,
    .operation = .read_barrier,
    .key = [_]u8{0} ** 64,
    .key_length = 0,
    .value_hash = [_]u8{0} ** 32,
}, &effects);
```

This method is not the fastest. It is easy to prove. Optimize reads only after
the required consistency is written down.

== Durable journal owner

One task owns the Paxos node. It receives network and client events through
bounded queues. For each event it calls one node method and obtains effects.

```text
event owner -> node.step
node        -> durable write batch
disk        -> durable completion
event owner -> transport sends
event owner -> state machine applies contiguous commits
```

No other task sends Paxos messages. This single owner makes the ordering rule
easy to inspect.

== Snapshot

Assume the log bound is 100,000 slots. At slot 80,000 the leader proposes a
checkpoint command. Once applied, each node writes:

```text
snapshot_version
cluster_epoch
applied_slot = 80000
key_value_state
client_result_table
checksum
```

The snapshot is complete only after its checksum and final marker are durable.
A new epoch can then begin under an application barrier. The old journal remains
available until the new epoch has a verified quorum.

== Failure story

N1 commits a put in slot 401 but crashes before replying. N2 becomes leader. Its
phase one recovery sees the accepted value and reproposes it. The client retries
the same request. N2 may put that retry in slot 402. When the state machine
applies 402, the client table returns the result from 401 without storing the
blob twice.

Paxos prevents two values in slot 401. The client table prevents one logical
request in two slots from running twice. Both layers are necessary.

= Large example: a regional control plane

Consider a service that assigns workloads to regions. It manages 50,000 workers
and receives 20,000 commands per second at peak. A wrong order can assign one
worker twice. A stale read is acceptable for dashboards but not for placement.

We choose five voting nodes across three failure domains.

#table(
  columns: (auto, auto, auto, 1fr),
  table.header([*Node*], [*Region*], [*Zone*], [*Duty*]),
  [`N1`], [`east`], [`east-a`], [Preferred leader.],
  [`N2`], [`east`], [`east-b`], [Nearby voter.],
  [`N3`], [`central`], [`central-a`], [Voter and snapshot source.],
  [`N4`], [`west`], [`west-a`], [Remote voter.],
  [`N5`], [`west`], [`west-b`], [Remote voter.],
)

A quorum is three. The layout tolerates any two node failures, but it does not
survive loss of east plus one west node if only central and one west remain. The
failure domain calculation must use actual placement, not just `N = 5`.

== Command design

```zig
const Command = struct {
    tenant_id: u64,
    client_id: u128,
    request_id: u64,
    timestamp_ms: u64,
    kind: enum {
        noop,
        assign,
        release,
        change_quota,
        checkpoint,
        read_barrier,
    },
    payload_hash: [32]u8,
};
```

The timestamp is data chosen before proposal. Apply never reads a local clock.
The payload contains worker sets and constraints in external durable storage.
Its hash enters consensus.

== Sharding

One Paxos group cannot order an unlimited world. We partition tenants among 64
groups. Each group has its own membership, node state, log, applied state, and
client deduplication table.

The shard map is itself versioned configuration. A command carries the shard
map version used by the client gateway. A stale version is rejected or routed
through a controlled migration. Moving a tenant between groups is a distributed
transaction and is not made atomic by either group alone.

== Capacity sketch

At 20,000 commands per second, an epoch with 10 million slots lasts:

```text
10,000,000 / 20,000 = 500 seconds
```

That is too short. Batching 100 application commands into one consensus value
reduces the slot rate to 200 per second:

```text
10,000,000 / 200 = 50,000 seconds, about 13.9 hours
```

Still short for comfortable operation. A bounded in memory Paxos log is not the
right place for months of history. The control plane should use smaller epochs,
regular snapshots, and an external audit log.

The batch value contains a fixed maximum number of command hashes. The leader
flushes when the batch is full or a short latency timer expires. The timer decides
when to propose. It is not read during deterministic apply.

== Network sketch

If one batch is 8 KiB and the leader sends it to four peers at 200 batches per
second, leader egress for accept payloads is roughly:

```text
8 KiB * 4 * 200 = 6.25 MiB/s
```

Commit messages are small. A leader change may send recovery metadata for many
slots, so snapshots and epoch length must also bound recovery time.

== Disk sketch

One fsync per batch means 200 syncs per second. A device with 2 ms median sync
latency can keep up in the average case, but tail latency matters. Grouping local
accept records and journal metadata into one atomic write avoids extra syncs.

The benchmark in this repository uses memory storage. It says nothing about
these disk numbers. A deployment benchmark must include the actual journal.

== Read classes

#table(
  columns: (auto, 1fr, 1fr),
  table.header([*Caller*], [*Read path*], [*Reason*]),
  [Dashboard], [Local follower read with applied slot.], [Staleness is visible and
    acceptable.],
  [Scheduler], [Log barrier through the leader.], [Placement needs linear order.],
  [Audit export], [Snapshot plus committed suffix.], [Bulk work need not block the
    proposal path.],
)

== Observability

Every group exports:

+ current role, ballot, and leader hint,
+ highest committed and applied slot,
+ proposal queue depth and age,
+ journal append and sync latency,
+ messages by tag and rejection reason,
+ campaign count and leader tenure,
+ catch up distance per peer,
+ remaining slot capacity,
+ snapshot age and checksum status.

An alert on remaining slots is a safety feature. An alert after exhaustion is a
postmortem note.

== Regional failure

Suppose the east region loses N1 and N2. N3, N4, and N5 can form a quorum. The
failure detector eventually chooses one candidate. Its phase one reads a complete
quorum and recovers every constrained slot. Client gateways redirect new work.

Cross region latency now defines commit latency. Safety is unchanged. Capacity
may fall because the surviving leader has different network and disk limits.

When east returns, its old leader messages carry lower ballots and are rejected.
The nodes catch up before serving strong reads. Merely reconnecting a process
does not make its state current.

== Security boundary

The large system authenticates peers with mutually authenticated channels. The
transport binds the certificate identity to the Paxos node ID and cluster epoch.
It rejects an envelope whose claimed source differs from the channel identity.

Payload hashes are verified before apply. Frame length is checked before memory
is reserved. Rate limits apply before expensive signature or blob work when
possible. Paxos is not a substitute for peer authentication.

== What remains outside this library

The example needs automated epoch transition, snapshot transfer, batch values,
read index optimization, durable journal framing, and a failure detector. Those
features belong to the system design. The current library supplies the bounded
ordering core and states its limits rather than offering incomplete switches.
