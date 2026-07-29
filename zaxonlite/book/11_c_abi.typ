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
it: link, open, write, batch, hold a live transaction, retry, read — as
JSON and as typed results — maintain, cluster, and finally reach an
existing cluster as a pure client. The rules about memory and threads
come last, once you have seen every buffer they govern.

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
not use. `zaxonlite_version()` returns the library version string. Release
0.1.2 returns `"0.1.2"`.

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

== Live transactions

The builder never holds SQLite state open, and for a cluster member
that is the right trade: a leader can change while your application
thinks. On a single-member local handle there is no other leader to
lose to, so a caller-held transaction is safe — and some hosts, a
DB-API layer or an ORM unit of work, need one. Gate C live
transactions serve exactly that case.

#api_anchor([`zaxonlite_live_begin` / `_exec` / `_savepoint` /
  `_release_savepoint` / `_rollback_to_savepoint` / `_commit` /
  `_rollback` / `_active`],
  [A caller-held SQLite transaction on the writer connection of a
    single-member local handle.], source: [`capi.zig`])

`zaxonlite_live_begin` opens a real transaction on the writer
connection; a multi-member handle refuses it. Statements run through
`zaxonlite_live_exec`, and each observes the transaction's earlier
uncommitted writes — read-your-writes, before anything replicates.
Savepoints are host-managed and named by ordinal:
`zaxonlite_live_savepoint(handle, 2)` creates `zx_sp_2`, with release
and rollback-to counterparts.

Nothing leaves the process until `zaxonlite_live_commit`. Commit
captures the whole transaction as exactly one WAL transition and
acknowledges only after the decided slot is applied — the same
durability meaning as a one-shot write, held open across your calls.
`zaxonlite_live_rollback` publishes nothing. While a live transaction
is open, one-shot writes, snapshots, and membership operations on the
handle are refused, and `zaxonlite_live_active` reports the state.

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

== Typed results and structured writes

JSON stringifies every cell, and for a host language with real
integers and floats that is a lossy detour. The typed surface removes
it. `zaxonlite_query_prepared_result` runs the same read-only prepared
query but returns an opaque `zaxonlite_result` handle instead of a
buffer.

#api_anchor([`zaxonlite_query_prepared_result` / `zaxonlite_result_*`],
  [Materialized typed query results behind an opaque handle, read
    through bounds-checked accessors.], source: [`capi.zig`])

The result owns copied column names and cell bytes.
`zaxonlite_result_column_count` and `zaxonlite_result_row_count` give
the shape, `zaxonlite_result_column_name` names a column, and
`zaxonlite_result_value` fills a `zaxonlite_value` whose text and
blob bytes are borrowed from the result until
`zaxonlite_result_close`. Every count and index operation is
bounds-checked, so an out-of-range row or column is an error, never a
read past the end. Integer and real cells preserve SQLite's runtime
storage class, and zero-length text or blob is distinct from NULL.
`zaxonlite_result_close` releases the handle and accepts NULL, so
cleanup paths need no guard.

Writes gain a structured counterpart.
`zaxonlite_exec_prepared_result` reports a `zaxonlite_exec_result`:
`changes`, `replayed`, and `last_insert_rowid`, which is present —
`has_last_insert_rowid` set — only when the statement observably
updated SQLite's last insert rowid (an INSERT or REPLACE). When the
statement has a RETURNING clause its typed rows arrive in the same
opaque result form, and they are complete before the write is
acknowledged: a RETURNING row you hold describes a durable, decided
write, never a speculative one.

#api_anchor([`zaxonlite_statement_describe` /
  `zaxonlite_statement_parameter_name`],
  [Statement metadata from SQLite's own preparation, so hosts never
    parse SQL.], source: [`capi.zig`])

Two describers keep hosts out of the SQL-parsing business.
`zaxonlite_statement_describe` prepares, without executing, the first
statement and reports `parameter_count`, `column_count`, `read_only`,
and `has_tail`, so a host rejects trailing statements without parsing
SQL. `zaxonlite_statement_parameter_name` copies the name of one
bound parameter (1-based, with the `:name`, `@name`, or `$name`
spelling included), or an empty string for a positional one. SQLite
resolves the names; the host never rewrites SQL.

Finally, `zaxonlite_last_error_category` returns the stable category
of the handle's most recent error: 0 none, 1 constraint, 2 busy, 3
interrupt, 4 misuse, 5 storage, 6 integrity, 7 availability, 8
session, 9 other SQL, 10 validation. The values are ABI-stable, so a
host maps them to its own exception hierarchy; the message from
`zaxonlite_last_error` stays diagnostic only.

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
the database identity derived when a member's data directory is first
created, an optional PSK (`auth_secret` plus
`auth_secret_length`) for the authenticated transport, and
`startup_timeout_ms`, where 0 selects the 10000 ms default.

Roles are `ZAXONLITE_DATA_VOTER`, `ZAXONLITE_WITNESS`,
`ZAXONLITE_STANDBY`, `ZAXONLITE_READ_REPLICA`, and `ZAXONLITE_GATEWAY`.
The registry has rules: it holds at most 36 members, at most nine
entries may be voting roles, at least one member must be a campaigning
data voter, ids must be unique and non-zero, and `node_id` must appear
in the registry. Open starts the
node, or the stateless router when the local role is gateway, then
blocks until the local endpoint answers. If the endpoint never answers,
open fails with 4 at the timeout.

#api_anchor(`zaxonlite_cluster_open_v2`,
  [Opens the same facade from a size-versioned options struct with a
    PSK provider file, a loopback development mode, and Unix-socket
    service.], source: [`capi.zig`])

The v1 options struct has no size member, so its layout is frozen
forever; that is why a versioned entry point exists at all.
`zaxonlite_cluster_options_v2` begins with `struct_size`, which you
set to `sizeof(zaxonlite_cluster_options_v2)` before calling, so the
library knows which fields your binary was compiled against and later
additions stay compatible. Three fields ride on it. An
`auth_file_path` names a PSK provider file, loaded with the native
regular-file, symlink, permission, and size checks; it is mutually
exclusive with the raw `auth_secret` buffer, because two sources for
one secret is a configuration ambiguity. `allow_psk_only_loopback`
enables development-only PSK TCP: it requires a secret, forbids TLS,
and every member address must be numeric loopback (127.0.0.1 or ::1).
And a registry holding a single member whose address is
`unix:<absolute path>` serves one local node over an owner-only
Unix-domain socket — the registry must contain exactly that member,
it may not be a gateway, and Unix service composes with neither TLS
nor the PSK flag.

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

== The remote client

Everything above either owns a data directory or is a cluster member.
An application process on another machine is neither: it wants to
reach an existing cluster the way a database driver reaches a
database. The remote client is that driver surface — a pooled
external client that opens no data directory and no listener.

#api_anchor([`zaxonlite_remote_open` / `_close` / `_exec` / `_query` /
  `_resolve_pending` / `_status_json` / `_last_error` /
  `_last_error_category`],
  [A pooled external client speaking typed client RPC to an existing
    cluster.], source: [`capi_remote.zig`])

You describe the target in `zaxonlite_remote_options`: 1 to 36 seed
addresses (`host:port`, or one `unix:<path>` that must be the only
seed, since one socket path names exactly one server), a mutual TLS
identity or a PSK provider file with the loopback-only development
flag, and a `pool_size` of 1 to 64 connection slots, where 0 selects
`min(32, max(4, 2 * seed_count))`. Reads distribute over the pool at
a read level you name — 0 `any`, 1 `leader`, 2 `linearizable` —
while every write travels one FIFO write lane that owns a replicated
session and numbers each write, so retry across leader changes and
ambiguous connection loss stays exactly-once. If a write's deadline
expires with its fate unknown, the exact request is retained and
every later write fails until `zaxonlite_remote_resolve_pending`
reaches a definitive outcome: success, an idempotent replay, or a
rejection that proves the statement never committed.

Two refusals protect the surface. Every slot's first status probe
must observe the same pinned database identity — supplied in
`expected_database_id`, or learned from the first probe — so a pool
never straddles two clusters. And a server that does not advertise
the typed value contract (`typed_v1` in status) is refused outright,
so remote cells keep their storage classes exactly like local ones.
Results come back through the same `zaxonlite_result_*` accessors,
and `zaxonlite_remote_status_json` returns raw status JSON for host
diagnostics. Chapter 12 builds the Python SDK on precisely this
surface.

== Memory ownership across the boundary

You have now seen every buffer the ABI moves. Three rules cover all of
them.

+ *You lend inputs.* SQL strings, `zaxonlite_value` bytes, paths, and
  the cluster options struct are borrowed only for the call.
  Transactions copy at `_exec`, and cluster open copies the registry
  before returning, so your buffers are free the moment each call
  returns.
+ *You own returned results.* Every `char **json_out` result is a
  heap buffer released with `zaxonlite_free`, which uses the C
  allocator the library links; your own `free` is the wrong
  allocator. Every `zaxonlite_result` handle is released with
  `zaxonlite_result_close`, and the text and blob bytes
  `zaxonlite_result_value` lends you are valid only until that
  close.
+ *You borrow error strings.* `zaxonlite_last_error` and
  `zaxonlite_cluster_last_error` return handle-internal storage. Do not
  free them. Copy them out if you need them past the next call.

== The boundary contract

The header states the argument rules once, and every exported function
follows them. `NULL` is accepted only where a parameter is documented
optional; a non-zero length always requires a non-null pointer, and a
null pointer always requires a zero length. Declared counts and lengths
are validated against product limits before any memory is read, sliced,
or allocated from them: the cluster registry holds at most 36 members,
a secret is at most 4096 bytes, and one bound TEXT or BLOB value is at
most 64 MiB. Every fallible function sets its output handles, pointers,
and scalar out-parameters to a safe empty value — `NULL`, 0, or
`false` — before doing any other work, on success and on every error
path, so a caller that ignores a return code still never reads an
uninitialized output. Violating the argument rules is misuse, code 2.

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

#exercise([11.1], [
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
