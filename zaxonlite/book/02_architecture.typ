#import "theme.typ": *

= Architecture

== Components

One node owns one data directory and is assembled from small, separately
tested parts:

#table(
  columns: (auto, 1fr),
  table.header([*Module*], [*Responsibility*]),
  [`node.zig`], [The host: lifecycle, the write path ordering contract,
    effect handling, recovery, snapshots, epoch rollover, and the
    leader/follower split of the materialized image.],
  [`journal.zig`], [The framed, CRC-checksummed, append-only protocol
    journal; replay with torn-tail truncation and interior-corruption
    rejection.],
  [`payload_store.zig`], [Content-addressed immutable payloads under
    `payloads/aa/<hash>`, installed with write-temp/sync/link.],
  [`wal.zig`], [WAL frame capture from SQLite's `-wal` file and the
    deterministic offline page apply; the payload wire format.],
  [`command.zig`], [The fixed-size replicated descriptor
    (`TransactionBatch`) and the cumulative chain-hash formula.],
  [`types.zig`], [The one `ReplicatedLog` instantiation and canonical
    encodings of its entries and durable writes.],
  [`sqlite.zig`], [Narrow bindings over the pinned SQLite amalgamation:
    exactly the C API subset the product needs.],
  [`server.zig` / `client.zig` / `wire.zig`], [The TCP host behind
    `zaxon serve`, the RPC client, and the shared frame codec.],
  [`capi.zig`], [The C ABI (`libzaxonlite` + `zaxonlite.h`).],
)

The Paxos core is the parent `paxos` library's `ReplicatedLog`: a
bounded, allocation-free effect machine. The host never mutates protocol
state directly; it calls `append`, `step`, `tick`, and consumes an
explicit `Effects` batch whose contract *is* the durability ordering:
persist `writesSlice()`, fsync, `confirmWritesDurable()`, only then send
`messagesSlice()` and apply `committedSlice()`.

== The replicated command

Paxos never carries transaction bytes. A committed slot holds a
fixed-size descriptor:

```zig
TransactionBatch {
    database_id:       u128,   // cluster-wide database identity
    batch_id:          u128,   // random identity of this execution
    base_data_slot:    u64,    // previous data slot in the epoch
    base_chain_hash:   [32]u8, // cumulative history before this batch
    result_chain_hash: [32]u8, // cumulative history after this batch
    payload_hash:      [32]u8, // SHA-256 name of the frame payload
    payload_bytes:     u64,
    transaction_count: u32,
    frame_count:       u32,
}
```

The payload — header, per-transaction records, frame descriptors, raw
page images — lives in the content-addressed store and is persisted
*before* the descriptor is proposed, so no counted vote can ever name
bytes that are not durable somewhere.

#callout(title: "Chain hashes: O(1) history identity", tone: "note")[
  `result_chain_hash = H(base_chain_hash, database_id, batch_id,
  base_data_slot, payload_hash, payload_bytes, transaction_count,
  frame_count)` with a domain-separated SHA-256. Two nodes with equal
  chain values have applied the same batches in the same order. Recovery,
  commit accounting, and `integrity-check` all validate the chain; a
  mismatch is fatal, never repaired silently.
]

== The write path

Every write follows one ordering contract, identical in one-member and
cluster deployments:

+ execute the SQL inside `BEGIN IMMEDIATE … COMMIT` on the leader's
  capture connection; the replicated session row and the `batch_id`
  marker are updated *inside the same SQLite transaction*;
+ capture the committed frames from the `-wal` file (the `wal_hook`
  count says exactly how many);
+ persist the payload in the content-addressed store (write, fsync,
  link);
+ append the descriptor through `ReplicatedLog`;
+ journal the resulting durable writes and fsync, then confirm;
+ only now may accept messages leave the process;
+ when the slot commits and carries *this* `batch_id`, acknowledge.

A failed SQL statement rolls back before capture; rolled-back
transactions never advance the WAL hook count, so nothing about them is
ever captured, proposed, or replicated.

== The read path

The leader holds the only live SQLite connection (the capture
connection); its applied state is the database. Followers keep the image
materialized offline and open short-lived read connections per query.
Reads are labeled: `any` may be stale on a follower; `leader` is the
leader's applied state; `linearizable` completes a quorum fence first
(chapter 6).

== Sessions inside the state machine

Bounded client sessions are rows in a replicated table
(`__zaxon_sessions`), updated inside the same captured transaction as the
user's SQL. Exactly-once retry therefore needs no separate log: wherever
the frames go, the session state goes, atomically. The
`__zaxon_meta.batch_id` marker travels the same way and lets recovery
prove the materialized image matches the last committed descriptor.
