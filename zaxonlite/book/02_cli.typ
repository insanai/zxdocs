#import "theme.typ": *
#import "figures.typ": *

= The `zaxon` command line

#objectives([
  By the end of this chapter you should be able to pick the right mode for
  any task, run every `zaxon` subcommand and read its output, wire a node
  up from a config file and environment variables, script the CLI through
  `--json` and its exit codes, and read any diagnostic without guessing.
])

The quickstart used `zaxon` in a hurry. This chapter is the reference. One
binary carries three modes that share one command surface:

- Embedded mode (`--data <dir>`): the command opens the node in-process,
  exactly as an embedding application would. No server runs.
- Client mode (`--connect <endpoint>[,...]`): the command speaks the
  replication protocol to running `zaxon serve` processes. It walks the
  endpoint list and follows leader redirects on its own.
- Server mode (`zaxon serve`): the process hosts one role-aware node behind
  a TCP endpoint, alone or in a cluster, or behind a local Unix-domain
  socket for a single node.

Use embedded mode for a stopped node: local inspection, integrity checks,
recovery, one-machine databases. Use client mode whenever a `serve` process
owns the directory. A data directory has exactly one owner at a time. If a
server owns it, an embedded command is refused:

```console
$ zaxon status --data ./srv1
-- NODE DIRECTORY LOCKED --

Another process owns this data directory.

Hint: Stop that process or choose a different --data directory.
```

That refusal exits with code 4. The lock protects safety: two writers on one
journal would fork history.

== Embedded mode

Every embedded command opens the node, does its work, applies any journal
suffix it finds, and closes. The directory is created on first use. No
daemon runs. `zaxon exec --data ./mydb --sql "..."` is a complete durable
write from a shell. Embedded mode is the only home of `recover`, and the
natural home of `integrity-check`, because both want exclusive ownership
of the files they judge.

== Client mode

`--connect` takes a comma-separated endpoint list. An endpoint is
`host:port` or `unix:<path>`; the latter dials a local server's
Unix-domain socket. The same syntax applies to the config file's
`connect` field and to `ZAXON_CONNECT`. For a command that needs
the leader, the client tries each endpoint until one answers, and follows
the redirect the follower sends back. You never need to know who leads.

#transcript((
  [1], [You], [Run `zaxon exec --connect a,b,c`. The client picks the first
    reachable endpoint.],
  [2], [Follower], [Answers "not leader" and names the current leader.],
  [3], [Client], [Reconnects to the advertised leader and replays the
    request there.],
  [4], [Leader], [Commits the write through Paxos, applies it, and returns
    the result the command prints.],
))

Commands that do not need the leader, such as `status`, `members`, `wait`,
and `stop`, are answered by whichever endpoint you reached. So is a
`query --level any` read. A leader hint is followed only when it names one
of the endpoints you configured; a hint pointing anywhere else falls back
to round-robin over your list, so a redirect can never send the client
outside the cluster it was told about. When no endpoint can complete a
leader-only request, the client prints one `-- NO REACHABLE LEADER --`
diagnostic and exits 4. Its hint states the two causes worth checking: a
lost voter quorum, or wrong `--connect` addresses and credentials.

When the servers require mutual TLS, client mode takes the same three
certificate flags as `serve`: `--tls-cert`, `--tls-key`, and `--tls-ca`.
Chapter 13 covers provisioning.

== Server mode: `serve`

`serve` needs three things: a directory, a node ID, and a listen endpoint.
Peers are optional; without them you get a single-voter cluster.

```console
$ zaxon serve --data ./n1 --node 1 --listen 127.0.0.1:7001 \
    --peer 2@127.0.0.1:7002 --peer 3@127.0.0.1:7003
```

Each `--peer` is `id@host:port[/role]`. A peer whose ID equals `--node` is
ignored, so all members can share one peer list. The optional role suffix
and the node's own `--role` accept `data-voter`, `witness`, `standby`,
`read-replica`, or `gateway`. A node run with `--role gateway` owns no
database state at all: it only routes client traffic to members that serve
reads or writes. Chapter 7 explains what each role may do.

With more than one member, `serve` derives a database identity from the
membership, plus `--cluster-id` when given. Two clusters with the same
member list but different `--cluster-id` values refuse to mix. That fence
protects safety against cross-cluster replay.

For a single local node that should not open a TCP port at all,
`--listen unix:<path>` serves over a Unix-domain socket instead.
Filesystem permissions are the local authorization boundary: the socket
is restricted to owner-only permissions (mode 0600) immediately after
binding. A pre-existing file at the socket path is refused, never
silently unlinked, so a stale socket left by a crash needs explicit
operator removal; an orderly shutdown removes the path itself. The mode
is single-node only. Configured peers are rejected, because cluster
links require TCP, and gateway mode is TCP-only. Clients reach the node
with `--connect unix:<path>`.

`serve` can also carry a mutual TLS identity: `--tls-cert <pem>`,
`--tls-key <pem>`, and `--tls-ca <pem>`, always all three together; a
partial set is a usage error, exit 2. Every TCP connection the server
accepts or dials, peer and client alike, then runs TLS 1.3 with mutual
certificate verification against the cluster CA, and a peer's certificate
must name exactly the node id it claims. TLS and the PSK compose: when
both are configured, the PSK handshake runs inside the TLS channel.
Chapter 13 covers certificate provisioning and the identity rules;
chapter 7 states what each transport mode proves.

#callout(title: [Non-loopback requires a transport credential], tone: "warning")[
  Without `--auth-file` or a TLS identity, every listen and peer address
  must be loopback. A public address is refused at startup, exit 4:
  "A non-loopback listener cannot start without a transport secret or TLS
  identity." The diagnostic's hint names the ways out: provide
  `--auth-file` or `--tls-cert`/`--tls-key`/`--tls-ca`, bind a loopback
  address, or serve locally through `--listen unix:<path>`. Both
  credential flags take file paths, never literal secrets, so keys stay
  out of shell history and process listings. A PSK alone still does not
  make protocol v4 a production transport; chapter 13 states the exact
  boundary of each mode.
]

`--enable-failpoints` makes the server honor fault-injection RPCs. It exists
for test controllers only. Never set it in production.

== Data commands: `sql`, `exec`, `query`

`sql` opens the interactive shell in either embedded or client mode. The
prompt is `zaxon>`. A line starting with `select`, `with`, `values`, or
`explain` runs as a read; every other statement runs as a replicated write.
Dot commands: `.status` prints node status, `.tables` lists user tables
(embedded shell only), and `.quit` or `.exit` leaves.

```console
$ zaxon sql --data ./mydb
zaxon> select count(*) as n from notes
n
-
1
zaxon> .quit
```

`exec` runs one write and prints how many rows it changed, in the
`1 row(s) changed` form you have seen. A SQL failure prints the SQLite
message and exits 1:

```console
$ zaxon exec --data ./mydb --sql "insert into missing values (1)"
-- SQL ERROR --

no such table: missing

Hint: Correct the statement and retry it as a new request.
```

`query` runs read-only SQL and prints a table: a `col | col` header, a
dashed underline, then the rows, with `NULL` for null cells.

```console
$ zaxon query --connect 127.0.0.1:7001 --sql "select a, b from t"
a | b
--+--
1 | x
```

A write statement given to `query` is rejected with "statement is not
read-only; use exec", exit 1. The read level defaults to `linearizable`;
`--level` also accepts `leader` and `any`, and `--freshness-ms` bounds the
staleness of a local learner read. Chapter 8 defines what each level
promises. In embedded mode there is no other node to consult, so every
read is local.

== Session commands: `session`, `exec --session`, `expire-sessions`

`session` opens a client session and prints its ID on one line, as
`session 1`.

#predict([
  You pass `--session` to `exec` but forget `--sequence`. Does the write run
  without retry protection, or does the command refuse? Decide before
  reading on.
])

It refuses, exit 2: "--session and --sequence go together". A session
without a sequence number cannot deduplicate anything, so `zaxon` will not
pretend it can. With both flags, a retry of a decided write replays its
recorded result instead of applying twice:

```console
$ zaxon exec --data ./mydb --session 1 --sequence 1 --sql "insert into notes(body) values ('exactly once')"
1 row(s) changed
$ zaxon exec --data ./mydb --session 1 --sequence 1 --sql "insert into notes(body) values ('exactly once')"
replayed: 1 row(s) changed (recorded result)
```

Skipping ahead exits 1 with a `-- SESSION ERROR --` diagnostic naming the
cause: `SequenceGap`, `UnknownSession`, or `ResultExpired`. The hint is the
rule: use the same live session and its next monotonic sequence.

`expire-sessions --retain <n>` deletes idle sessions, keeping the `n` with
the newest activity, and reports the count as `0 session(s) expired` when
nothing was idle enough to remove. Expiring a session a client still
retries against turns its safe retry into a double apply, so retain
generously. Chapter 8 covers sizing.

== Cluster commands: `status`, `members`, `leader`, `wait`, `stop`

`status` on an embedded node prints an aligned field list: node id, database
id, configuration id, role, node type, decided and applied slots, journal
records, epoch capacity, the journal chain hash, page size, and the current
snapshot name or `(none)`. Against a server, `status` and `members` print
the raw JSON response even without `--json`; the server's answer includes
fields such as the current ballot that the embedded view does not have.

`leader` names the coordinator, or reports `leader: none` when no leader is
known:

```console
$ zaxon leader --connect 127.0.0.1:7001
leader: node 1 at 127.0.0.1:7001
```

`wait` blocks until conditions hold, then reports where the node stands on
one line, as `applied 3, leader 1`. `--applied <slot>` waits for the apply
point to reach that slot and defaults to 0. `--leader` also waits for a
known leader. `--timeout-ms` defaults to 10000. Use `wait` in scripts
between "start the cluster" and "first write". `stop` asks one served node
to shut down cleanly and prints the bare acknowledgement `{"ok":true}`. It
stops one process, not the cluster.

== Maintenance: `snapshot`, `backup`, `integrity-check`, `recover`

`snapshot` compacts: it installs a verified snapshot and seals the current
journal epoch, printing the new configuration ID. `backup --to <path>`
streams a consistent logical copy, a plain SQLite file, verified end to end
with SHA-256 before it is installed at the destination. Against a cluster
it streams from the leader. If the leader dies mid-stream the command
reports "backup interrupted" and installs nothing, so a half-written backup
can never be mistaken for a good one.

`integrity-check` verifies three layers and prints one verdict per layer:

```console
$ zaxon integrity-check --data ./n1
sqlite: pass
chain: pass
payloads: pass
```

Any `FAIL` makes the exit code 3. The client-mode form prints a single
`integrity: pass` or `integrity: FAIL` line. `recover` runs the same checks
after rebuilding the node from its authoritative state, and ends with
`recovery rebuild complete`. It is embedded-only: running it with
`--connect` is refused, exit 2, because rebuilding a node that a live
server owns would race the server. Stop the node, then recover it.

== The sync mode: `--sync`

Every command takes `--sync <mode>`, which sets the process-wide
durability policy before any storage I/O runs. The mode decides how far
a sync must reach before the node treats bytes as durable. `full`, the
default, flushes the drive's volatile write cache on macOS through
`fcntl(F_FULLFSYNC)`, so an acknowledged write survives power loss, not
just a process crash. `os` keeps the plain platform `fsync(2)`, which
on macOS does not reach the drive cache; it is for development and
benchmarks only there. On Linux and the other supported platforms plain
`fsync` already flushes the cache, so the two modes are identical. Any
other value is a usage error, exit 2: `--sync must be os or full`.
Chapter 6 explains why a consensus voter must not run `os` on macOS in
production, and chapter 13 prices the difference.

== Configuration file and environment

Every mode can read a JSON config file, named by `--config <path>` or the
`ZAXON_CONFIG` environment variable. The file accepts exactly these fields,
each optional:

#table(
  columns: (auto, 1fr),
  table.header([*Field*], [*Meaning*]),
  [`data`], [Node data directory, as for `--data`.],
  [`connect`], [Comma-separated endpoint list, as for `--connect`.],
  [`node`], [This node's integer ID.],
  [`role`], [Node role name, as for `--role`.],
  [`listen`], [Listen endpoint for `serve`.],
  [`peers`], [Array of peer specs, each `id@host:port[/role]`.],
  [`cluster_id`], [Extra entropy for the derived database identity.],
  [`auth_file`], [Path to the transport secret provider.],
  [`tls_cert`], [Node certificate PEM for mutual TLS.],
  [`tls_key`], [Node private key PEM for mutual TLS.],
  [`tls_ca`], [Cluster CA PEM that peer certificates must chain to.],
  [`sync`], [Durability sync mode, as for `--sync`: `full` (the
    default) or `os`.],
)

An unknown field is an error, not a warning: the command reports
`-- CONFIGURATION UNREADABLE --` with `UnknownField` and exits 2. A typo in
a config file should fail loudly, not silently misconfigure a database.
Each field also has an environment variable: `ZAXON_DATA`, `ZAXON_CONNECT`,
`ZAXON_NODE`, `ZAXON_ROLE`, `ZAXON_LISTEN`, `ZAXON_PEERS` (comma
separated), `ZAXON_CLUSTER_ID`, `ZAXON_AUTH_FILE`, `ZAXON_TLS_CERT`,
`ZAXON_TLS_KEY`, `ZAXON_TLS_CA`, and `ZAXON_SYNC`.

Precedence is fixed: a command-line flag beats an environment variable,
and an environment variable beats the file. A complete node config:

```json
{
  "data": "/var/lib/zaxon/n2",
  "node": 2,
  "role": "data-voter",
  "listen": "10.0.0.2:7001",
  "peers": ["1@10.0.0.1:7001", "3@10.0.0.3:7001"],
  "cluster_id": "orders-prod",
  "auth_file": "/etc/zaxon/psk"
}
```

With that file in place, `ZAXON_CONFIG=/etc/zaxon/n2.json zaxon serve` is a
complete node start.

#callout(title: [The secret provider file], tone: "note")[
  The provider file must hold at least 32 bytes and at most 4096. One
  trailing line ending is stripped; every other byte, including spaces, is
  part of the key. Give every node the same provider content. A short file
  is rejected with `SecretTooShort`, exit 2.
]

== `--json` for automation

`--json` switches stdout to machine-readable output. Embedded commands emit
compact objects:

```console
$ zaxon exec --data ./mydb --json --sql "insert into notes(body) values ('json row')"
{"changes":1,"slot":7,"replayed":false}
$ zaxon status --data ./mydb --json
{"node_id":1,"database_id":"a13f203d26d80813d0834ff231269878",
 "configuration_id":1,"role":"leader","node_type":"data-voter","leader":1,
 "decided_slot":7,"applied_slot":7,"journal_records":31,
 "epoch_capacity":256,"chain":"8f6a...94f8f","page_size":4096,
 "snapshot":null}
```

The status object is one line on a real terminal, and the chain field is
the full 64-hex-digit hash. `query --json` emits
`{"columns":[...],"rows":[[...]]}` with every cell as a string or `null`.
In client mode `--json` passes the server's response through untouched,
including error responses, which arrive as `{"ok":false,...}` on stdout
while the exit code still reports the failure class. Parse the exit code
first, then the body.

== Diagnostics and exit codes

Every failure prints one diagnostic to stderr in a fixed shape: an
uppercase header between `--` markers, a plain-language description, and a
`Hint:` line naming the next action. The hint is chosen by failure class.
A `not_leader` error says to retry the advertised leader or restore a
quorum; a `stale` read says to wait for catch-up, relax freshness, or query
the leader. The exit code states the failure class:

#table(
  columns: (auto, 1fr),
  table.header([*Code*], [*Meaning*]),
  [0], [Success.],
  [1], [SQL error or session error. The statement or retry was wrong; the
    node is healthy.],
  [2], [Usage error: bad flags, bad config, bad request, or a command not
    available in this mode.],
  [3], [Integrity failure. `integrity-check` or `recover` found a layer
    that does not verify.],
  [4], [Node unavailable: directory locked, no reachable leader, corrupt
    state, or a refused insecure listen.],
)

Scripts should branch on the code, not on the text. The text is for humans
and may improve; the codes are the contract.

#exercise(2, [
  Write a shell script that takes an endpoint list, waits up to 30 seconds
  for a leader, runs one idempotent insert inside a fresh session, and
  retries it once. Assert with the `--json` output that the retry reports
  `"replayed":true` and the same slot both times.
], hint: [
  You need `wait --leader --timeout-ms`, `session --json`, and two
  identical `exec --session --sequence --json` calls. Compare the two
  `slot` values.
])

#teach_back([
  Explain to a colleague why `recover` works only with `--data`, why an
  embedded command on a served directory exits 4, and why both rules follow
  from the same single-owner invariant.
])
