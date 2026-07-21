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

== Three voters on one machine: PSK first

A real cluster needs one `serve` process per node. Open three terminals, or
background each command. Each node gets its own directory, ID, and port. Each
`--peer` flag names one other member. Start with the deliberately small local
development transport: one owner-only pre-shared key (PSK), restricted by
`--dev-psk` to numeric loopback addresses.

Create the provider file, then define two Bash conveniences for the client
commands below:

```console
$ openssl rand -hex 32 > demo.psk
$ chmod 600 demo.psk
$ cluster=127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003
$ zc() { zaxon "$@" --auth-file ./demo.psk; }
```

Start one command in each of three terminals:

```console
$ zaxon serve --data ./n1 --node 1 --listen 127.0.0.1:7001 \
    --peer 2@127.0.0.1:7002 --peer 3@127.0.0.1:7003 \
    --auth-file ./demo.psk --dev-psk
$ zaxon serve --data ./n2 --node 2 --listen 127.0.0.1:7002 \
    --peer 1@127.0.0.1:7001 --peer 3@127.0.0.1:7003 \
    --auth-file ./demo.psk --dev-psk
$ zaxon serve --data ./n3 --node 3 --listen 127.0.0.1:7003 \
    --peer 1@127.0.0.1:7001 --peer 2@127.0.0.1:7002 \
    --auth-file ./demo.psk --dev-psk
```

Each terminal immediately prints the node ID, role, data directory, listen
address, transport, durability mode, peer connections, and the stable leader.
There is no silent-daemon guessing step.

#callout(title: [Development boundary], tone: "warning")[
  `--dev-psk` is a quickstart convenience, not production transport. It is
  refused unless the listener and every peer are `127.0.0.1` or `::1`. The
  PSK authenticates one shared secret and protects frame integrity, but does
  not encrypt traffic or give nodes distinct identities. Use mTLS for any
  cluster that leaves one machine.
]

Wait for election, write, and read. In PSK-only mode give leader-only commands
the whole endpoint list: a shared key cannot safely authenticate an advertised
node ID, so the client rotates only through seeds you supplied.

```console
$ zc wait --connect "$cluster" --leader
applied 0, leader 3
$ zc leader --connect "$cluster"
leader: node 3 at 127.0.0.1:7003
$ zc exec --connect "$cluster" \
    --sql "create table orders(id integer primary key, item text)"
0 row(s) changed
$ zc exec --connect "$cluster" \
    --sql "insert into orders(item) values ('espresso machine')"
1 row(s) changed
$ zc query --connect "$cluster" --sql "select * from orders"
id | item
---+-----
1 | espresso machine
```

== Move the same cluster to mTLS

Stop all three nodes with Ctrl-C. Their data stays in `n1`, `n2`, and `n3`;
we are changing only the transport. Production TCP uses a small cluster CA,
one identity per node, and an operator/client identity. Create them now:

```console
$ mkdir -p demo-pki
$ openssl ecparam -name prime256v1 -genkey -noout -out demo-pki/ca.key
$ chmod 600 demo-pki/ca.key
$ openssl req -new -x509 -key demo-pki/ca.key -sha256 -days 1 \
    -subj /CN=zaxon-demo-ca -addext basicConstraints=critical,CA:TRUE \
    -addext keyUsage=critical,keyCertSign,cRLSign -out demo-pki/ca.crt
$ for n in 1 2 3; do \
    openssl ecparam -name prime256v1 -genkey -noout -out demo-pki/n$n.key; \
    chmod 600 demo-pki/n$n.key; \
    openssl req -new -key demo-pki/n$n.key -subj /CN=zaxon-node-$n \
      -out demo-pki/n$n.csr; \
    openssl x509 -req -in demo-pki/n$n.csr -CA demo-pki/ca.crt \
      -CAkey demo-pki/ca.key -CAcreateserial -days 1 -sha256 \
      -out demo-pki/n$n.crt; \
  done
$ openssl ecparam -name prime256v1 -genkey -noout -out demo-pki/client.key
$ chmod 600 demo-pki/client.key
$ openssl req -new -key demo-pki/client.key -subj /CN=zaxon-client \
    -out demo-pki/client.csr
$ openssl x509 -req -in demo-pki/client.csr -CA demo-pki/ca.crt \
    -CAkey demo-pki/ca.key -CAcreateserial -days 1 -sha256 \
    -out demo-pki/client.crt
```

The server certificates' canonical common names bind their configured node
IDs. Redefine the Bash helper for mTLS client commands:

```console
$ zc() { zaxon "$@" --tls-cert demo-pki/client.crt \
    --tls-key demo-pki/client.key --tls-ca demo-pki/ca.crt; }
```

```console
$ zaxon serve --data ./n1 --node 1 --listen 127.0.0.1:7001 \
    --peer 2@127.0.0.1:7002 --peer 3@127.0.0.1:7003 \
    --tls-cert demo-pki/n1.crt --tls-key demo-pki/n1.key --tls-ca demo-pki/ca.crt
$ zaxon serve --data ./n2 --node 2 --listen 127.0.0.1:7002 \
    --peer 1@127.0.0.1:7001 --peer 3@127.0.0.1:7003 \
    --tls-cert demo-pki/n2.crt --tls-key demo-pki/n2.key --tls-ca demo-pki/ca.crt
$ zaxon serve --data ./n3 --node 3 --listen 127.0.0.1:7003 \
    --peer 1@127.0.0.1:7001 --peer 2@127.0.0.1:7002 \
    --tls-cert demo-pki/n3.crt --tls-key demo-pki/n3.key --tls-ca demo-pki/ca.crt
```

Now wait for the restarted cluster to elect a leader, from a fourth terminal:

```console
$ zc wait --connect 127.0.0.1:7001,127.0.0.1:7002,127.0.0.1:7003 --leader
$ zc leader --connect 127.0.0.1:7001
```

Client mode takes a comma-separated endpoint list and follows leader
redirects on its own. Under mTLS you can point it at any member: the client
accepts the advertised address only when the new server certificate names the
advertised node ID. Send a write to node 1 even if node 3 is leader, then read
through node 2:

```console
$ zc exec --connect 127.0.0.1:7001 \
    --sql "insert into orders(item) values ('mTLS redirect')"
1 row(s) changed
$ zc query --connect 127.0.0.1:7002 --sql "select * from orders"
id | item
---+-----
1 | espresso machine
2 | mTLS redirect
```

Both commands may begin at followers. A follower redirects the authenticated
client to the leader. The default read level is `linearizable`: before answering, the
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
$ zc leader --connect 127.0.0.1:7001
leader: node 1 at 127.0.0.1:7001
$ zc exec --connect 127.0.0.1:7002,127.0.0.1:7003 \
    --sql "insert into orders(item) values ('written during failover')"
1 row(s) changed
$ zc query --connect 127.0.0.1:7002 --sql "select count(*) from orders"
count(*)
--------
3
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
$ zc session --connect 127.0.0.1:7001
session 4211843370881911185
$ zc exec --connect 127.0.0.1:7001 --session 4211843370881911185 \
    --sequence 1 --sql "insert into orders(item) values ('exactly once')"
```

If that command times out, run it again with the same session and the same
sequence. A decided write replays its saved result instead of applying twice.
An undecided write applies normally. Chapter 8 explains the contract; the
rule to remember is: same session, same sequence, same statement.

== Snapshot and backup

```console
$ zc backup --connect 127.0.0.1:7001 --to ./orders-backup.db
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
