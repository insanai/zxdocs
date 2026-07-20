#import "theme.typ": *

= The C ABI: libzaxonlite

#objectives([
  By the end of this chapter you should be able to link `libzaxonlite`
  into a C program, open a node and run a replicated write, bind typed
  parameters, batch statements into one atomic transaction, retry a write
  exactly once through a session, read results as JSON, and state who
  owns every buffer that crosses the boundary.
])

This chapter is for the dqlite-style embedder. Any language with a C FFI
can host a replicated SQLite node inside its own process. The whole
surface is one header, `zaxonlite/include/zaxonlite.h`, implemented by
`zaxonlite/src/capi.zig`. We walk the surface in the order you will use
it: link, open, write, batch, retry, read, maintain, cluster. The rules
about memory and threads come last, once you have seen every buffer they
govern.

== Link and open

Build the library first. `zig build` inside `zaxonlite/` produces the
static library `zig-out/lib/libzaxonlite.a` and installs the header as
`zig-out/include/zaxonlite.h`. Compile your program against both:

```console
$ cc -I zig-out/include embedder.c zig-out/lib/libzaxonlite.a -o embedder
```

The ABI is narrow on purpose, because narrow is what stays stable.
`zaxonlite`, `zaxonlite_transaction`, and `zaxonlite_cluster` are
`typedef void`. No struct layout leaks into your binary, so the
implementation can change without recompiling you. Every scalar that
crosses the boundary is a fixed-width type from `<stdint.h>` or
`<stdbool.h>`. Protocol quantities are never a bare `int`. Incompatible
changes require a new symbol suffix or a major library version. Additive
JSON response fields are compatible, and you must ignore fields you do
not use. `zaxonlite_version()` returns the library version string. It
says `"unreleased"` until the release owner assigns one.

#api_anchor([`zaxonlite_open` / `zaxonlite_close`],
  [Opens (or creates) one node data directory and releases it.],
  source: [`capi.zig`])

One handle owns one data directory: journal, payload store, snapshots,
and the materialized SQLite image. Open performs full
journal-authoritative recovery before returning. The handle you receive
is therefore already at the decided state. The directory is locked, so a
second `zaxonlite_open` on the same path returns 4 and leaves
`*out_handle` null. `zaxonlite_close` flushes nothing extra, because
every acknowledged write was already durable when its call returned. It
frees the handle.

== The return-code contract

Every fallible function returns a `c_int` from one fixed set. The set is
mirrored in the header comment, in `capi.zig`, and in the CLI's exit
codes. Learn it now, because every later section uses it.

#table(
  columns: (auto, 1fr),
  table.header([*Code*], [*Meaning and what maps to it*]),
  [0 (ok)], [The operation completed.],
  [1 (SQL or session)], [SQLite rejected the statement (`SqliteError`,
    `SqliteBusy`), or a session failed (`UnknownSession`, `SequenceGap`,
    `ResultExpired`). The failed statement had no durable effect.],
  [2 (misuse)], [A caller bug. Examples: a null required argument, a
    write statement on the read path (`WriteInReadQuery`), a bind-count
    mismatch, an invalid value type, or a transaction-builder violation
    (`TransactionFinished`, `EmptyTransaction`, `TooManyStatements`,
    `TransactionInputTooLarge`).],
  [3 (integrity)], [Only `zaxonlite_integrity_check` returns it. The
    image, descriptor chain, or payload store failed verification.],
  [4 (unavailable)], [Everything else. The directory is locked by
    another handle, durable state is corrupt, or I/O failed. The node is
    not safe to use for this operation.],
)

#api_anchor(`zaxonlite_last_error`,
  [Returns the most recent error message for a handle as a borrowed,
    NUL-terminated string.], source: [`capi.zig`])

The message lives in a fixed buffer inside the handle. The next failing
call overwrites it, and `zaxonlite_close` frees it. Never call
`zaxonlite_free` on it. For code 1 from SQLite the message is SQLite's
own text, for example `no such table: missing`. Otherwise it is the Zig
error name. The cluster facade has its own
`zaxonlite_cluster_last_error` with the same lifetime rules.

== Your first replicated write

`zaxonlite_exec` runs one SQL statement batch as one replicated write
transaction. On success `*changes_out` receives the affected-row count:

```c
int64_t changes = 0;
int rc = zaxonlite_exec(db, "insert into c(b) values ('tea')", &changes);
```

That one call proposed a slot, stored and synced the payload, applied
the decided transaction, and only then returned. When `rc` is 0 the row
is durable, not merely buffered.

== Prepared values

String-splicing SQL invites injection and quoting bugs.
`zaxonlite_exec_prepared` adds typed parameter binding through an array
of `zaxonlite_value` structs. Each value names its type and the fields
that type reads:

#table(
  columns: (auto, auto, 1fr),
  table.header([*`type`*], [*Fields read*], [*SQLite binding*]),
  [`ZAXONLITE_NULL`], [(none)], [NULL],
  [`ZAXONLITE_INTEGER`], [`integer`], [64-bit integer],
  [`ZAXONLITE_REAL`], [`real`], [64-bit float],
  [`ZAXONLITE_TEXT`], [`bytes`, `length`], [Text, bounded by `length`,
    never read to a NUL.],
  [`ZAXONLITE_BLOB`], [`bytes`, `length`], [Blob],
)

TEXT and BLOB borrow `bytes` for the duration of the call only. A
`length` of zero binds an empty value and ignores `bytes`. Otherwise a
non-null `bytes` is required. The value count must equal the statement's
parameter count, and an unknown `type` is misuse (code 2). The bound is
65536 values per call.

== Transactions

#api_anchor([`zaxonlite_transaction_begin` /
  `_exec` / `_commit` / `_close`],
  [Collects copied statements across calls, then executes and replicates
    them atomically at commit.], source: [`capi.zig`])

An explicit transaction is a builder, not a live SQLite transaction.
This is a safety decision. A live transaction would hold database locks
while your application thinks, and it would leave speculative SQLite
state behind across a leadership change. The builder holds neither.

Each `zaxonlite_transaction_exec` copies the SQL and all TEXT and BLOB
bytes, so you may release your buffers immediately. Nothing touches
SQLite until commit. Commit executes every statement under the
one-writer gate and proposes exactly one captured WAL transition, so the
batch is atomic: all of it is decided, or none of it.

The bounds are 1024 statements and 64 MiB of copied input. Exceeding
either is misuse.

#predict([
  You call `zaxonlite_transaction_begin`, then `_commit` with no
  statements in between. Is that an error or a harmless no-op? Decide
  before reading on.
])

Committing an empty transaction is misuse, not a no-op. An empty commit
almost always means a logic bug upstream, and the library refuses to
replicate a write that does nothing. A transaction is also single-use.
After `_commit`, whether it succeeded or failed, only `_close` is valid.
`_close` is always required, because it frees the builder.

== Sessions: exactly-once retry

#api_anchor([`zaxonlite_session_open` / `zaxonlite_exec_idempotent`],
  [Replicated client sessions. Each (session, sequence) executes at most
    once.], source: [`capi.zig`])

Suppose your process crashes after proposing a write but before seeing
the result. A blind retry could apply the write twice. Sessions close
that hole. `zaxonlite_session_open` returns a `uint64_t` session id, and
creating it is itself a replicated write. That matters: because the
session table is part of the replicated state, the exactly-once
guarantee survives process crashes and restarts.

`zaxonlite_exec_idempotent(handle, session, sequence, sql, &changes,
&replayed)` executes `sequence` exactly once. Retrying the last sequence
sets `*replayed_out = true` and returns the recorded change count
without executing any SQL. A sequence gap or an expired result fails
with code 1 and has no side effects.
`zaxonlite_expire_sessions(handle, retain, &expired)` deletes sessions
idle for more than `retain` recent session writes and reports how many
were removed.

== Queries and JSON results

`zaxonlite_query_json` and `zaxonlite_query_prepared_json` run read-only
statements. Each returns one JSON object of the shape
`{"columns":[...],"rows":[[...]]}`. Every cell is a string or `null`.
The returned buffer is owned by you and released with `zaxonlite_free`.

A write statement on the read path is misuse. The reason is safety, not
pedantry. The read path performs no replication, so a write that slipped
through it would change this node's image and no one else's. The
replicas would fork. Rejecting the statement with code 2 is the only
correct answer.

== Maintenance

Three calls keep a node healthy over months, not minutes.
`zaxonlite_snapshot` takes an online snapshot and seals the current
journal epoch. `zaxonlite_backup` streams a consistent logical backup to
`path`. `zaxonlite_integrity_check` verifies the SQLite image, the
descriptor chain, and payload availability. It returns 0 only when all
three pass, and 3 otherwise.

== The cluster facade

Everything so far ran one local node. The cluster facade turns your
process into a full cluster member with its own transport.

#api_anchor(`zaxonlite_cluster_open`,
  [Opens a transport-owning cluster member from a runtime role registry.],
  source: [`capi.zig`])

You describe the cluster in a `zaxonlite_cluster_options` struct. It
names the data directory, this process's `node_id`, and the member
registry: an array of `zaxonlite_member { id, address, role }` with
`host:port` addresses. It also takes an optional `cluster_id` mixed into
the derived database identity, an optional PSK (`auth_secret` plus
`auth_secret_length`) for the authenticated transport, and
`startup_timeout_ms`, where 0 selects the 10000 ms default.

Roles are `ZAXONLITE_DATA_VOTER`, `ZAXONLITE_WITNESS`,
`ZAXONLITE_STANDBY`, `ZAXONLITE_READ_REPLICA`, and `ZAXONLITE_GATEWAY`.
The registry has rules: at most nine entries may be voting roles, at
least one member must be a campaigning data voter, ids must be unique
and non-zero, and `node_id` must appear in the registry. Open starts the
node, or the stateless router when the local role is gateway, then
blocks until the local endpoint answers. If the endpoint never answers,
open fails with 4 at the timeout.

The facade routes through the client RPC protocol and follows leader
redirects for you. `zaxonlite_cluster_exec` handles writes.
`zaxonlite_cluster_query_json` handles linearizable reads.
`zaxonlite_cluster_call_json(handle, request_json, require_leader,
&json_out)` sends any RPC op from the next chapter. Cluster-surface
failures return misuse only for null arguments and invalid registries.
Remote errors surface as code 4 with the error name in
`zaxonlite_cluster_last_error`, and for `_call_json` you also receive
the `{"ok":false,...}` response body itself. `zaxonlite_cluster_close`
requests a graceful stop and joins the server thread.

== Memory ownership across the boundary

You have now seen every buffer the ABI moves. Three rules cover all of
them.

+ *You lend inputs.* SQL strings, `zaxonlite_value` bytes, paths, and
  the cluster options struct are borrowed only for the call.
  Transactions copy at `_exec`, and cluster open copies the registry
  before returning, so your buffers are free the moment each call
  returns.
+ *You own returned JSON.* Every `char **json_out` result is a heap
  buffer. Release it with `zaxonlite_free`, which uses the C allocator
  the library links. Your own `free` is the wrong allocator.
+ *You borrow error strings.* `zaxonlite_last_error` and
  `zaxonlite_cluster_last_error` return handle-internal storage. Do not
  free them. Copy them out if you need them past the next call.

== Threading discipline

Each handle owns its own event-loop instance and node. `capi.zig`
guarantees independence between handles and nothing within one. Use a
handle, and any transaction created from it, from one thread at a time,
or under your own lock. This is SQLite's own connection discipline. The
library adds no internal cross-call synchronization on the single-node
surface, so two threads in one handle are a data race, not a queued
wait.

== A complete embedder

The following condenses the shipped smoke test
(`zaxonlite/test/capi_smoke.c`), which exercises every exported
function:

```c
#include "zaxonlite.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    zaxonlite *db = NULL;
    if (zaxonlite_open("./data", &db) != 0) return 1;

    int64_t changes = 0;
    if (zaxonlite_exec(db, "create table c(a integer primary key, b text)",
                       &changes) != 0) {
        fprintf(stderr, "exec: %s\n", zaxonlite_last_error(db));
        zaxonlite_close(db);
        return 1;
    }

    const zaxonlite_value row[] = {
        {.type = ZAXONLITE_TEXT, .bytes = "tea", .length = 3}};
    zaxonlite_exec_prepared(db, "insert into c(b) values (?1)", row, 1,
                            &changes);

    uint64_t session = 0;
    zaxonlite_session_open(db, &session);
    bool replayed = false;
    zaxonlite_exec_idempotent(db, session, 1,
                              "insert into c(b) values ('z')", &changes,
                              &replayed);           /* retry-safe forever */

    char *json = NULL;
    if (zaxonlite_query_json(db, "select a, b from c order by a",
                             &json) == 0) {
        puts(json);       /* {"columns":["a","b"],"rows":[["1","tea"],...]} */
        zaxonlite_free(json);
    }

    zaxonlite_snapshot(db);
    if (zaxonlite_integrity_check(db) != 0) return 3;
    zaxonlite_backup(db, "./data.backup.db");
    zaxonlite_close(db);
    return 0;
}
```

#exercise("9.1", [
  `zaxonlite_query_json(db, "delete from c", &json)` returns 2, yet
  `zaxonlite_exec` accepts the same string. Explain, in terms of the
  replication path each function takes, why the read path must reject
  writes rather than execute them locally.
], hint: [a local write never produces a decided slot.])

#teach_back([
  Without reopening the header, list every buffer your embedder receives
  from `libzaxonlite`, who frees each one, and what happens if you call
  `zaxonlite_free` on the string from `zaxonlite_last_error`. Then check
  yourself against the memory-ownership rules above.
])
