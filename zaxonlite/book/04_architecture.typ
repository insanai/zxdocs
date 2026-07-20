#import "theme.typ": *
#import "figures.typ": *

#part_page("II", [How it works], [
  We open the machine you drove in chapter 1. One ordering contract moves
  every write from SQL text to a durable, replicated, acknowledged row.
])

= Architecture

#objectives([
  By the end of this chapter you should be able to name each module of a
  node and its single responsibility, trace one write from SQL text to
  acknowledgement in order, explain why Paxos decides a fixed-size
  descriptor instead of transaction bytes, and say how client sessions
  ride inside the replicated state machine.
])

In chapter 1 you killed a leader and a write still landed. This part of
the book explains why that worked. We start with the shape of one node.
Chapter 5 then follows the transaction bytes. Chapter 6 follows the
files on disk. Chapter 7 grows the cluster beyond three voters. Chapter
8 states exactly what a client may assume.

== One node, small parts

One node owns one data directory. It is assembled from small parts, and
each part is tested on its own.

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
  [`guard.zig`], [The SQL invariant guard: a narrow authorizer screening
    application statements at prepare time, plus the capture-contract
    check run before every payload extraction.],
  [`server.zig` / `client.zig` / `wire.zig`], [The TCP or Unix-socket
    host behind `zaxon serve`, the RPC client, and the shared frame
    codec.],
  [`capi.zig`], [The C ABI (`libzaxonlite` + `zaxonlite.h`).],
)

The Paxos core is the parent `paxos` library's `ReplicatedLog`. It is a
bounded effect machine and it allocates nothing. The host never mutates
protocol state directly. It calls `append`, `step`, and `tick`, and each
call hands back an explicit `Effects` batch. The contract on that batch
is the durability ordering itself: persist `writesSlice()`, fsync, call
`confirmWritesDurable()`, and only then send `messagesSlice()` and apply
`committedSlice()`. Chapter 6 turns this contract into the full set of
ordering rules and names the invariant each one protects.

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

The real bytes live somewhere else. The payload holds the header, the
per-transaction records, the frame descriptors, and the raw page images.
It sits in the content-addressed store under its own SHA-256, and it is
persisted before the descriptor is ever proposed. That ordering protects
a safety invariant: no counted vote can ever name bytes that are not
durable somewhere. Chapter 5 walks through the payload format itself.

#callout(title: "Chain hashes: history identity in constant space", tone: "note")[
  `result_chain_hash = H(base_chain_hash, database_id, batch_id,
  base_data_slot, payload_hash, payload_bytes, transaction_count,
  frame_count)` with a domain-separated SHA-256. Two nodes with equal
  chain values have applied the same batches in the same order. Recovery,
  commit accounting, and `integrity-check` all validate the chain. A
  mismatch is fatal. It is never repaired silently.
]

== The write path

Every write follows one ordering contract. The contract is identical in
a one-member database and a full cluster. The `./mydb` directory you
created in chapter 1 walked this exact path with a quorum of one.

#book_figure([
  One replicated write, in the order the bytes move. The payload is
  durable on a voter before that voter's vote may count, and the client
  hears nothing until the decided transaction is applied.
], write_path())

#transcript((
  [1], [Leader], [Executes the SQL inside `BEGIN IMMEDIATE ... COMMIT`
    on its capture connection. The replicated session row and the
    `batch_id` marker are updated inside that same SQLite transaction.],
  [2], [Leader], [Captures the committed frames from the `-wal` file.
    The `wal_hook` count says exactly how many frames belong to this
    commit.],
  [3], [Leader], [Persists the payload in the content-addressed store:
    write to a temporary name, fsync, link into place.],
  [4], [Leader], [Appends the descriptor through `ReplicatedLog`, then
    journals the resulting durable writes, fsyncs, and confirms them.
    Only now may accept messages leave the process.],
  [5], [Each voter], [Stores and syncs the payload, then acknowledges it
    with `payload_stored`. The leader releases the value-bearing accept
    to a voter only after that acknowledgement.],
  [6], [Each voter], [Journals its acceptance and fsyncs before
    replying. The slot commits once a quorum has accepted.],
  [7], [Leader], [Applies the committed batch. When the committed slot
    carries this `batch_id`, and only then, it acknowledges the client.],
))

What about a write that fails? A failed SQL statement rolls back before
capture. A rolled-back transaction never advances the WAL hook count, so
nothing about it is ever captured, proposed, or replicated. The failure
stays local to the leader, exactly as it would in plain SQLite.

== The read path

The leader holds the only live SQLite connection: the capture
connection. Its applied state is the database. Followers keep the image
materialized offline and open short-lived read connections per query.

Reads are labeled, and the label is the contract. A read at `any` may be
stale on a follower. A read at `leader` returns the leader's applied
state. A read at `linearizable` completes a quorum fence before it
answers, which is the default you used in chapter 1. Chapter 8 defines
each level precisely and shows the fence protocol.

== Sessions inside the state machine

Bounded client sessions are rows in a replicated table,
`__zaxon_sessions`. The session row is updated inside the same captured
transaction as the user's SQL. This placement is the whole trick.
Exactly-once retry needs no separate log, because wherever the frames
go, the session state goes with them, atomically.

Application SQL can neither read nor write the `__zaxon_*` namespace:
the invariant guard (chapter 5) denies the reserved prefix at prepare
time, so the replicated metadata stays Zaxonlite's alone.

The `__zaxon_meta.batch_id` marker travels the same way. On restart,
recovery compares it against the last committed descriptor to prove the
materialized image is the one the log says it should be. Chapter 6 shows
where that check sits in the recovery sequence, and chapter 8 states the
session contract from the client's side.
