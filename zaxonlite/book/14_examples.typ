#import "theme.typ": *
#import "figures.typ": *

= Worked examples

#objectives([
  By the end of this chapter you should be able to embed one durable node in
  a Zig program and name the durability effect of every call, run a
  failure-drill lab against a five-member cluster and predict each drill's
  outcome before you run it, and outline how an application with its own
  event loop embeds the C ABI without violating its threading contract.
  Guidance fades from example to example.
])

== Small example: one durable node embedded in Zig

*Runnable example, heavy guidance.* Every call below is exercised, with the
same argument shapes, by `zaxonlite/src/integration_test.zig`. The program
mirrors how `zaxon` itself opens a node in `zaxonlite/src/main.zig`. Run it
against a fresh directory. On a second run, `create table` fails by design,
because the schema is already part of the replicated history.

#code_file("examples/durable_node.zig (assembled from tested calls)")[
```zig
const std = @import("std");
const zaxonlite = @import("zaxonlite");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // Step 1: open (or create) the node data directory.
    const node = try zaxonlite.Node.open(gpa, io, .{ .directory = "./inventory" });
    defer node.close();

    // Step 2: replicated writes. Each exec is one journal-durable slot.
    _ = try node.exec("create table items(id integer primary key, v text)");
    const insert = try node.exec("insert into items(v) values ('tea'), ('coffee')");
    std.debug.print("{d} row(s) changed\n", .{insert.changes});

    // Step 3: read the applied state.
    var rows = try node.query(gpa, "select id, v from items order by id");
    defer rows.deinit();
    for (rows.rows) |row| {
        std.debug.print("{s}: {s}\n", .{ row[0].?, row[1].? });
    }

    // Step 4: exactly-once retry through a replicated session.
    const session = try node.openSession();
    const first = try node.execIdempotent(session, 1,
        "insert into items(v) values ('water')");
    const retry = try node.execIdempotent(session, 1,
        "insert into items(v) values ('water')");
    std.debug.assert(!first.replayed and retry.replayed);
    std.debug.assert(first.changes == retry.changes);

    // Step 5: snapshot. Seal the epoch, start the next one.
    try node.snapshot();
}
```
]

Let us name what each step guarantees, in order.

+ *Open.* `Node.open` acquires the directory lock, and a second open fails
  with `error.NodeLocked`. It verifies identity and the `CURRENT` snapshot
  pointer, truncates a torn journal tail, discards `current.db` with its WAL
  and SHM, and rebuilds the image from the verified snapshot plus the
  committed journal suffix. Nothing the previous process acknowledged can be
  missing. Nothing it never decided can appear.
+ *Write.* When `exec` returns, the transaction's descriptor is committed,
  its journal records are fsynced, and the slot is applied locally. In a
  one-member configuration all of that happens before the call returns. A
  failed statement rolls back and replicates nothing; the test proves this
  with a `not null` violation, after which the decided slot count has not
  moved.
+ *Read.* `query` accepts only read-only SQL. A write statement fails with
  `error.WriteInReadQuery` instead of sneaking around the replicated write
  path. The result set is arena-backed, and `deinit` frees all of it.
+ *Retry.* `openSession` is itself a replicated write, so the session and
  its last recorded result survive crash and restart. Retrying sequence 1
  replays the recorded result without executing SQL. A skipped sequence
  fails with `error.SequenceGap`, an unknown session with
  `error.UnknownSession`, and a sequence older than the last with
  `error.ResultExpired`. None of those failures has side effects.
+ *Snapshot.* `snapshot` materializes a verified generation, installs
  `CURRENT`, advances the configuration ID, and starts an empty journal for
  the new epoch. Recovery afterward is the snapshot base plus the epoch
  suffix. Old epochs and unreferenced payloads become garbage.

#checkpoint("the journal is the database")[
  The integration suite deletes `current.db` outright after step 2's writes
  and reopens the node: the rows come back and `integrityCheck()` passes.
  Try the same against your program's directory. The materialized image is a
  projection; the fsynced journal and payload store are the authority.
]

== Middle example: a failure-drill lab

*Runnable lab, medium guidance.* Chapter 1 already taught bring-up,
kill-the-leader, sessions, and backup, so we do not repeat them. This lab
practices the failures those basics do not cover. Drills 1 and 2 mirror what
`zaxonlite/src/role_cluster_test.zig` asserts about witnesses and read
replicas. Drills 3 and 4 mirror the wipe, resync, and restart steps that
`zaxonlite/src/cluster_test.zig` runs against real `zaxon serve` processes.

The lab needs a registry the quickstart cluster does not have. A witness
votes, and the database identity is derived once, at bootstrap, from the
voting member ids plus the cluster id, so adding a witness describes a
different database than the one your chapter 1 directories hold. Changing
a voting set is never a restart with new flags. The one supported online
reconfiguration is the decided one-for-one replacement of a data voter
from chapter 13, and it changes the members, never the identity or the
count. It does not add a witness. We sidestep the problem with fresh
directories and a five-member registry: three data voters, one witness,
one read replica.

```sh
zaxon serve --data ./lab/n1 --node 1 --listen 127.0.0.1:7101 \
    --peer 2@127.0.0.1:7102 --peer 3@127.0.0.1:7103 \
    --peer 4@127.0.0.1:7104/witness --peer 5@127.0.0.1:7105/read-replica &
```

Nodes 2 and 3 repeat that shape with their own directory, id, and listen
address. The witness and the replica name their own roles:

```sh
zaxon serve --data ./lab/n4 --node 4 --role witness \
    --listen 127.0.0.1:7104 \
    --peer 1@127.0.0.1:7101 --peer 2@127.0.0.1:7102 \
    --peer 3@127.0.0.1:7103 --peer 5@127.0.0.1:7105/read-replica &
zaxon serve --data ./lab/n5 --node 5 --role read-replica \
    --listen 127.0.0.1:7105 \
    --peer 1@127.0.0.1:7101 --peer 2@127.0.0.1:7102 \
    --peer 3@127.0.0.1:7103 --peer 4@127.0.0.1:7104/witness &
```

Set an endpoint list for the voters, wait for a leader, and create a table:

```sh
V=127.0.0.1:7101,127.0.0.1:7102,127.0.0.1:7103
zaxon wait --connect $V --leader
zaxon exec --connect $V --sql "create table drills(id integer primary key, note text)"
```

=== Drill 1: what a witness buys you

Ask the registry what node 4 can do:

```sh
zaxon members --connect $V --json
```

Node 4 reports `votes` true and `serves_reads` false; node 5 reports the
reverse. The flags are the whole story. A witness stores the replicated log
so it can vote honestly, but it never materializes a SQL image, so it has
nothing to answer a query with:

```sh
zaxon query --connect 127.0.0.1:7104 --level any --sql "select 1"
```

The witness answers with the error `forbidden`, and the command exits 4.
This refusal is not a missing feature. A node that voted on history it never
stored as SQL would invite reads it cannot serve consistently.

Now use the vote. Find the leader, then stop one data voter that is not the
leader (here we assume the leader is node 1):

```sh
zaxon leader --connect $V
zaxon stop --connect 127.0.0.1:7103
zaxon exec --connect $V --sql "insert into drills(note) values ('one voter down')"
```

The write succeeds. Count the voting set: nodes 1 through 4 vote, so quorum
is three, and voters 1 and 2 plus the witness reach it. The witness kept the
cluster writable while holding no data. Restart node 3 with its original
`serve` command before the next drill.

=== Drill 2: stale and fresh reads at the replica

Write one row, then read it back at the replica with a freshness bound:

```sh
zaxon exec --connect $V --sql "insert into drills(note) values ('fresh')"
zaxon query --connect 127.0.0.1:7105 --level any --freshness-ms 2000 \
    --sql "select count(*) from drills"
```

The replica answers. A freshness-bounded read passes two checks: the
replica heard from a leader inside the bound, and its applied slot has
caught up to the decided slot it last observed. Note that `--freshness-ms`
requires `--level any`; a bound on a fenced read would be redundant, and the
server rejects the combination as a usage error.

#predict([
  Stop all three data voters. The replica still holds every applied row.
  Should the freshness-bounded read above still answer? Decide before you
  run the next block.
])

```sh
zaxon stop --connect 127.0.0.1:7101
zaxon stop --connect 127.0.0.1:7102
zaxon stop --connect 127.0.0.1:7103
zaxon query --connect 127.0.0.1:7105 --level any --freshness-ms 500 \
    --sql "select count(*) from drills"
```

The read fails with the error `stale` and exit code 4, even though the rows
are sitting right there. The bound is a promise about recency, not about
possession, and with no leader the replica cannot prove recency. Two
follow-ups sharpen the boundary. A plain `--level any` query still answers
from the local image, because you asked for no promise. A
`--level linearizable` query against the same endpoint exhausts the redirect
budget and exits 4, because no quorum can fence a read. Restart the three
voters and the bounded read recovers on its own.

=== Drill 3: wipe a follower, then resync across a sealed epoch

Stop node 2 and destroy its materialized image:

```sh
zaxon stop --connect 127.0.0.1:7102
rm ./lab/n2/current.db
```

Restart node 2 with its original `serve` command. It rebuilds the image
from its snapshot plus its journal, then rejoins. Prove it: read
`applied_slot` from `zaxon status --connect 127.0.0.1:7101 --json`, wait
with `zaxon wait --connect 127.0.0.1:7102 --applied <slot>`, and compare
`chain` in both nodes' `status --json`. Equal chains mean identical applied
history.

Now make the follower miss a whole epoch instead of a file:

```sh
zaxon stop --connect 127.0.0.1:7102
zaxon exec --connect $V --sql "insert into drills(note) values ('pre-roll')"
zaxon snapshot --connect $V
zaxon exec --connect $V --sql "insert into drills(note) values ('post-roll')"
```

Restart node 2 again. Its journal ends in an epoch the cluster has sealed,
so a journal suffix alone cannot catch it up. Watch `status --json` on port
7102: the configuration id jumps when the transferred snapshot installs, and
`applied_slot` then climbs through the new epoch. Both writes are present at
the end, and the chains converge again.

=== Drill 4: the full-cluster restart

Record the current row count with a fenced read:

```sh
zaxon query --connect $V --sql "select count(*) from drills"
```

Now kill all five processes with `kill -9`. Not `stop`, not Ctrl-C. The
automated suite does the same, because recovery must not depend on graceful
shutdown. Then restart all five with their original commands and verify:

```sh
zaxon wait --connect $V --leader --timeout-ms 20000
zaxon query --connect $V --sql "select count(*) from drills"
zaxon integrity-check --connect 127.0.0.1:7101
```

The count is unchanged, and the integrity check passes on each data voter.
Every write that was acknowledged before the kill is present exactly once
afterward. That sentence is the product; the drills exist so you believe it.

== Large example: the C ABI inside your own event loop

*Design sketch, light guidance.* The API surface below is
`zaxonlite/include/zaxonlite.h`, and every function named here is exercised
by the C smoke test in `zaxonlite/test/capi_smoke.c`, built by
`zig build test-cabi`. The event loop integration around it is yours to
design.

One constraint shapes the whole design: every call is synchronous. A
single-node handle from `zaxonlite_open` blocks in `zaxonlite_exec` until
the write is journal-durable and applied. A cluster facade from
`zaxonlite_cluster_open` owns its own listener, peer, and tick threads and
blocks the calling thread until quorum commit. Use each handle from one
thread at a time. An application with a latency-sensitive loop, such as a
game server, a UI, or an async runtime, should therefore never call either
handle from the loop thread.

One workable shape:

+ A dedicated database thread owns the handle for its whole lifetime, from
  `zaxonlite_open(dir, &db)` through `zaxonlite_close(db)`.
+ The loop enqueues request records, SQL text plus a completion callback or
  future, on a bounded queue; the database thread executes them in order and
  posts results back through the loop's own wake-up mechanism.
+ Reads return owned JSON from `zaxonlite_query_json` or
  `zaxonlite_query_prepared_json`; hand the buffer to the loop and let the
  consumer call `zaxonlite_free`.
+ Writes that must survive an ambiguous crash use `zaxonlite_session_open`
  once, then `zaxonlite_exec_idempotent` with a monotonic sequence; on
  restart, replaying the last sequence is safe by construction, and the
  smoke test proves it by reopening the directory and asserting `replayed`.
+ Multi-statement writes go through `zaxonlite_transaction_begin`, `_exec`,
  `_commit`, and `_close`; statements and bound values are copied, so the
  loop may free its buffers as soon as each call returns.
+ Every return code maps to a policy: 0 continue; 1 surface the SQL or
  session error from `zaxonlite_last_error` to the caller; 2 is a bug in
  your marshalling, such as a null argument or a write on the read path;
  3 and 4 stop accepting work and page an operator.

Gaps deliberately left for you: the queue's backpressure rule when the
database thread falls behind; whether reads bypass the queue on a second
read-only path; how sequences are assigned when several loop tasks share one
session; and when periodic `zaxonlite_snapshot` and
`zaxonlite_expire_sessions` calls run so they never race a burst of writes.

#exercise([14.1], [
  Extend the chapter 1 quickstart cluster with a read replica. Tear the
  three voters down, then restart all four processes with the same extended
  registry: node 4 serves with `--role read-replica` and the three voter
  peers, and each voter adds `--peer 4@127.0.0.1:7004/read-replica`. Write
  through the voters, then compare three reads against port 7004:
  `--level any` immediately after the write, the same query with
  `--freshness-ms 500`, and `--level linearizable`. Explain which
  answered locally, which
  was rejected as stale or answered fresh, and which redirected. Then
  explain why adding node 4 changed no write quorum and no database
  identity.
], hint: [
  A learner rejects a freshness-bounded read until it has heard a leader
  heartbeat inside the bound and its applied slot has caught up. A
  linearizable request to a learner returns `not_leader` with the certifying
  voter as the redirect hint. Identity and quorum are derived from voting
  members only.
])

#teach_back([
  Using only the words votes and serves_reads, explain to a colleague why
  the witness in drill 1 kept writes alive but could not answer a query,
  while the replica in drill 2 could answer a query but could not keep
  writes alive. Then explain which drill would break if the two flags were
  ever combined carelessly on one node.
])
