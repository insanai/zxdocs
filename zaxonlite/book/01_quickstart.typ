#import "theme.typ": *
#import "figures.typ": *

#part_page("I", [Getting started], [
  We run Zaxonlite before we explain it. One binary gives us a durable SQL
  database, then a three-voter cluster that survives a killed leader.
])

= Quickstart with the `zaxon` CLI

#objectives([
  By the end of this chapter you should be able to build the `zaxon` binary,
  run one durable database from a shell, bring up a three-voter cluster on
  your machine, kill its leader and watch a write succeed anyway, and take a
  verified backup.
])

Zaxonlite ships as one standalone executable, the way rqlite ships `rqlited`.
The binary is called `zaxon`. It is both the server and the client. With a
`--data` directory it works on a local node directly. With `--connect` it
speaks the replication protocol to a running cluster. Nothing else is needed:
no external SQLite install, no separate shell tool, no agent.

== Build the binary

Zaxonlite lives inside the paxos-zig monorepo and builds with Zig 0.16:

```console
$ cd zaxonlite
$ zig build -Doptimize=ReleaseSafe
$ ./zig-out/bin/zaxon version
```

`ReleaseSafe` keeps runtime safety checks on. That is the build we recommend
for a database. Copy `zig-out/bin/zaxon` anywhere on your `PATH`.

== One durable database in two minutes

Every `zaxon` command that takes `--data` runs against a local node directory.
The directory is created on first use.

```console
$ zaxon sql --data ./mydb
zaxon> create table notes(id integer primary key, body text)
0 row(s) changed
zaxon> insert into notes(body) values ('first durable row')
1 row(s) changed
zaxon> select * from notes
id | body
---+-----
1 | first durable row
zaxon> .quit
```

That looked like plain SQLite. It was not. Every write you just made was
decided by Multi-Paxos in a single-member configuration, recorded in a
checksummed journal, and synced to disk before `ok` came back.

#predict([
  Delete the file `mydb/current.db` and run the `select` again. What happens?
  Decide before you try it.
])

The database file is disposable. On the next start Zaxonlite discards the
materialized image, copies the last verified snapshot, and replays the
committed journal suffix. The journal is the truth. The `.db` file is a cache
of it. Chapter 6 walks through this recovery in detail.

== Three voters on one machine

A real cluster needs one `serve` process per node. Open three terminals, or
background each command. Each node gets its own directory, ID, and port. Each
`--peer` flag names one other member.

```console
$ zaxon serve --data ./n1 --node 1 --listen 127.0.0.1:7001 \
    --peer 2@127.0.0.1:7002 --peer 3@127.0.0.1:7003
$ zaxon serve --data ./n2 --node 2 --listen 127.0.0.1:7002 \
    --peer 1@127.0.0.1:7001 --peer 3@127.0.0.1:7003
$ zaxon serve --data ./n3 --node 3 --listen 127.0.0.1:7003 \
    --peer 1@127.0.0.1:7001 --peer 2@127.0.0.1:7002
```

#callout(title: [Loopback development cluster], tone: "warning")[
  These nodes listen on `127.0.0.1`, so `zaxon` lets them run without
  a transport credential. A non-loopback listen address is refused until
  you supply `--auth-file` or a mutual-TLS identity
  (`--tls-cert`/`--tls-key`/`--tls-ca`); the shared key alone is still
  only a development transport. A single local node can serve over an
  owner-only Unix-domain socket instead (`--listen unix:<path>`).
  Chapter 13 states the exact boundary of each mode.
]

Now wait for the cluster to elect a leader, from a fourth terminal:

```console
$ zaxon wait --connect 127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003 --leader
$ zaxon leader --connect 127.0.0.1:7001
```

Client mode takes a comma-separated endpoint list and follows leader
redirects on its own. You can point it at any member. Write through the
cluster, then read back:

```console
$ zaxon exec --connect 127.0.0.1:7001 \
    --sql "create table orders(id integer primary key, item text)"
$ zaxon exec --connect 127.0.0.1:7002 \
    --sql "insert into orders(item) values ('espresso machine')"
$ zaxon query --connect 127.0.0.1:7003 --sql "select * from orders"
id | item
---+-----
1 | espresso machine
```

The second command went to a follower. The follower redirected the client to
the leader. The default read level is `linearizable`: before answering, the
leader proves to a quorum that it is still the leader. You never read stale
data by accident.

#book_figure([
  One replicated write. The payload is stored and synced on a quorum before
  any voter's Paxos state may reference it, and the client is acknowledged
  only after the decided transaction is applied.
], write_path())

== Kill the leader

Time to earn the word "replicated". Find the leader, press Ctrl-C in that
node's terminal, and immediately write again:

```console
$ zaxon leader --connect 127.0.0.1:7001
leader: node 1 at 127.0.0.1:7001
$ zaxon exec --connect 127.0.0.1:7002,127.0.0.1:7003 \
    --sql "insert into orders(item) values ('written during failover')"
1 row(s) changed
$ zaxon query --connect 127.0.0.1:7002 --sql "select count(*) from orders"
count(*)
--------
2
```

The two survivors elect a new leader and the write lands. Restart the killed
node with its original `serve` command. It rejoins, catches up from its
peers, and the cluster is back to three.

#transcript((
  [1], [You], [Kill the leader process. Two voters remain, which is still a
    quorum of three.],
  [2], [Voter 2 or 3], [An election timeout fires. The survivor campaigns
    with a higher ballot and wins both remaining votes.],
  [3], [You], [Send `exec` to any survivor. The client follows the redirect
    to the new leader.],
  [4], [New leader], [Stores the payload, gathers quorum acceptance, commits,
    applies, and only then acknowledges.],
  [5], [You], [Restart node 1. It discards its image, rebuilds from its own
    journal, and asks its peers for the slots it missed.],
))

== Retries that cannot double-apply

Kill-the-leader has one sharp edge: if the leader dies after deciding your
write but before answering you, a blind retry would insert the row twice.
Sessions close that hole. Open one, then give every write a sequence number:

```console
$ zaxon session --connect 127.0.0.1:7001
session 4211843370881911185
$ zaxon exec --connect 127.0.0.1:7001 --session 4211843370881911185 \
    --sequence 1 --sql "insert into orders(item) values ('exactly once')"
```

If that command times out, run it again with the same session and the same
sequence. A decided write replays its saved result instead of applying twice.
An undecided write applies normally. Chapter 8 explains the contract; the
rule to remember is: same session, same sequence, same statement.

== Snapshot and backup

```console
$ zaxon backup --connect 127.0.0.1:7001 --to ./orders-backup.db
$ zaxon integrity-check --data ./n1
```

`backup` streams a consistent logical copy from the leader and verifies an
end-to-end SHA-256 before installing it at the destination. It is a plain
SQLite file you can open anywhere. `integrity-check` verifies the SQLite
image, the descriptor chain, and every referenced payload of a stopped node,
and exits 3 on any mismatch.

== Where to go next

You have now used everything the rest of the book explains. The full command
reference is the next chapter. Chapter 3 states the guarantees precisely.
Parts II and III explain how the machine works and how to embed it in your
own process, in Zig or through the C ABI.

#exercise(1, [
  Start the three-voter cluster again and kill two voters instead of one.
  Try a write and a `--level linearizable` read, then a `--level any` read
  against the survivor. Explain each result. Restart one killed voter and
  watch the cluster recover without any repair command.
], hint: [
  One voter out of three is not a quorum. Writes and fenced reads must fail.
  A local read may still answer.
])

#teach_back([
  Explain to a colleague why deleting `current.db` on a stopped node loses
  nothing, but deleting one journal file can refuse to start the node. Use
  the words journal, snapshot, and materialized image.
])
