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
`query --level any` read. Under mTLS, a leader hint may name a node outside
the seed list: the client follows it only when the new connection presents
`zaxon-node-<advertised-id>` from the trusted CA. Under PSK-only development
transport, a shared secret cannot prove that per-node binding, so hints are
followed only when they exactly match a configured endpoint; supply every
member in `--connect`. When the cluster did advertise a leader but policy
forbade following it, the client prints `-- LEADER REDIRECT REFUSED --`
naming the advertised address and the fix: add it to `--connect` or switch
to mTLS. When no endpoint answered at all, the client prints one
`-- NO REACHABLE LEADER --` diagnostic instead. Both exit 4.

When the servers require mutual TLS, client mode takes the same three
certificate flags as `serve`: `--tls-cert`, `--tls-key`, and `--tls-ca`.
Chapter 13 covers provisioning.

== Server mode: `serve`

`serve` needs three things: a directory, a node ID, and a listen endpoint.
Peers are optional; without them you get a single-voter cluster.

```console
$ openssl rand -hex 32 > demo.psk && chmod 600 demo.psk
$ zaxon serve --data ./n1 --node 1 --listen 127.0.0.1:7001 \
    --peer 2@127.0.0.1:7002 --peer 3@127.0.0.1:7003 \
    --auth-file ./demo.psk --dev-psk
```

After binding, `serve` writes a compact startup card to stderr: node and role,
data and listen paths, transport, member count, configuration, and durability.
It then reports peer connections and only stable leader changes. A terminal
that shows `writes are ready` is ready for leader-only client work; a leader
loss says explicitly that the node is waiting for voter quorum.

Each `--peer` is `id@host:port[/role]`. A peer whose ID equals `--node` is
ignored, so all members can share one peer list. The optional role suffix
and the node's own `--role` accept `data-voter`, `witness`, `standby`,
`read-replica`, or `gateway`. A node run with `--role gateway` owns no
database state at all: it only routes client traffic to members that serve
reads or writes. Chapter 7 explains what each role may do.

With more than one member, a first boot of `serve` derives a database
identity from the membership, plus `--cluster-id` when given. The
derivation runs only at bootstrap, when the data directory holds no
decided registry yet. From then on the durable registry carries the
database identity and the membership; startup flags that conflict with it
are a startup error (`RegistryMismatch`), never a re-derivation. Two
clusters with the same member list but different `--cluster-id` values
refuse to mix. That fence protects safety against cross-cluster replay.

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

`--dev-psk` is the one explicit PSK-only mode. It requires `--auth-file` and
refuses startup unless the listener and every peer use numeric loopback. It
exists for the one-machine quickstart and local development: it has frame
authentication and integrity, but neither confidentiality nor distinct node
identity. It cannot be set on a gateway or combined with mTLS.

#callout(title: [TCP transport boundary], tone: "warning")[
  Every non-loopback TCP listener requires mTLS. Loopback also defaults to
  mTLS unless the operator explicitly selects `--dev-psk` with an owner-only
  PSK provider. A single local node can instead use `unix:<path>`. Credential
  flags take file paths, never literal secrets, so keys stay out of shell
  history and process listings. PSK-only protocol v6 remains a local
  development transport, not a production trust boundary.
]

`--enable-failpoints` makes the server honor fault-injection RPCs. It exists
for test controllers only. Never set it in production.

`--enrollment-ca-key <path>` deliberately turns a storage node into a
certificate issuer. The file must be a regular, non-symlink, owner-only CA
private key matching `--tls-ca`; most nodes should omit it. Enrollment adds
no member by itself: it issues identities only for nodes the decided
registry names, and a replacement voter can be issued a token only after
the configuration that includes it is chosen. Chapter 13 gives the
two-command enrollment procedure and the crash semantics.

`--admin <name>`, repeatable, authorizes one administrator principal for
the privileged membership operations below. The name authorizes the mutual
TLS common name `zaxon-admin-<name>`, issued by the same cluster CA. A
server with an empty allow-list refuses every membership change, and the
development PSK transport cannot reach those operations at all.

== Data commands: `sql`, `exec`, `query`

`sql` opens the interactive shell in either embedded or client mode. A
statement starting with `select`, `with`, `values`, or `explain` runs as a
read; every other statement runs as a replicated write.

On a terminal the shell is a rich REPL (ZDS 0005): statements end with `;`
and may span lines under a `...>` continuation prompt, the input line is
edited in place with readline keys (`ctrl+a`/`ctrl+e`, word movement,
`ctrl+w`/`ctrl+u`/`ctrl+k`, and `ctrl+y` yank), SQL keywords highlight as you
type, the up/down arrows walk history, and `ctrl+r` is reverse incremental
history search. Results render as aligned tables with `NULL` shown dimmed;
results taller than the screen open in a pager (arrows scroll, `q` returns).

```console
$ zaxon sql --data ./mydb
zaxonlite unreleased — interactive shell
Statements end with ';'. Type .help for commands and keys.
zaxon> select id, author from notes where id < 3;
┌────┬────────┐
│ id │ author │
├────┼────────┤
│  1 │ vik    │
│  2 │ NULL   │
└────┴────────┘
(2 rows)
zaxon> .quit
```

`.help` lists the dot commands, which include `.tables`, `.schema [name]`,
`.status`, `.members`, `.mode table|expanded|auto|json|csv` (`expanded`
prints one block per record for wide rows; `auto` switches to it when a
table would overflow the terminal), `.timer on|off`, and
`.history [off|clear]`. `ctrl+c` cancels the statement being typed. During a
remote statement it abandons the local wait and warns that the statement may
still apply server-side; check its effects before retrying a write. `ctrl+d`
on an empty line leaves. `--no-color`, `NO_COLOR`, or `TERM=dumb` disable
styling.

When stdin or stdout is not a terminal — pipes, scripts, CI — the shell
keeps its historical plain form, byte for byte: a bare `zaxon> ` prompt,
one statement per line with no `;` requirement, dot commands `.status`,
`.tables` (embedded only), and `.quit`/`.exit`, and header-width tables:

```console
$ echo "select count(*) as n from notes" | zaxon sql --data ./mydb
zaxon> n
-
1
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

== Membership commands: `membership status`, `replace-voter`

Both commands are client-mode only, and both target a network-hosted TCP
cluster, which persists its membership as a decided registry: the
consensus-decided mapping from configuration ID to node IDs, roles, and
endpoints. A unix-socket local node keeps flag-fixed membership and
answers with the error `no_registry`.

`membership status` is read-only. It prints the server's JSON view of the
decided registry: the database and configuration IDs, the registry digest,
the decided nodes with roles and endpoints, the node-ID allocation fence,
and three live fields. `phase` names the replacement lifecycle position:
`idle`, `prepared`, `proposed`, `chosen`, `active-degraded`, `complete`,
or `retired`. `quorum_available` is an operational observation, not an
authorization: recently authenticated peers, including this node, satisfy
the majority quorums. `installation_state` tracks the replacement voter's
state transfer: `not-applicable`, `not-started`, `transferring`,
`verifying`, `installed`, `active`, or `failed`.

`replace-voter` asks the cluster to replace exactly one data voter with
one fresh data voter through a decided configuration change:

```console
$ zaxon replace-voter --connect 10.0.0.1:9901 \
    --operation 7 --expected-config 4 \
    --old-node 2 --new-node 5@10.0.0.5:9901 \
    --tls-cert admin.crt --tls-key admin.key --tls-ca ca.crt
```

All four flags are required. `--operation` is a caller-chosen `u64` that
must exceed every previously decided operation ID; repeating a retained
operation is an idempotent retry, and an expired one is rejected.
`--expected-config` must name the configuration you observed, so a request
can never race a membership change you have not seen. `--new-node` names a
fresh node ID above the allocation fence, with the endpoint the cluster
should dial.

The command is privileged. It requires mutual TLS with an administrator
certificate whose common name is `zaxon-admin-<name>` for a name in the
server's allow-list (`--admin`, or the config file's `admins` field).
Replacement also needs at least three voters, because the survivors alone
must still satisfy the sealed configuration's read quorum. Chapter 7
explains the replacement lifecycle; chapter 13 gives the operational
procedure.

== Identity bootstrap: `enroll-token`, `enroll`

`enroll-token` is a client-mode operator command. It uses an existing mTLS
identity to ask one configured issuer for a token bound to `--node`, then
writes an owner-only opaque bundle to `--to`. `--ttl-seconds` defaults to 600
and cannot exceed 86400:

```console
$ zaxon enroll-token --connect 10.0.0.1:9901 --node 2 --to node2.token \
    --tls-cert operator.crt --tls-key operator.key --tls-ca ca.crt
```

Transfer that bearer file securely to node 2. There, `enroll` pins the bundled
CA and issuer identity, creates the node key and CSR locally, redeems the token
once, verifies the certificate, and installs a new identity directory with one
atomic rename:

```console
$ zaxon enroll --token-file node2.token --identity-dir /etc/zaxon/node2
```

The new directory contains `node.key`, `node.crt`, and `ca.crt`; its private
key and directory are owner-only. An existing destination is never replaced,
and the bundle is removed after success. The issuer consumes the token before
signing, so a lost response or installation failure is deliberately
fail-closed: issue a new token rather than retrying the old one.

On an enrolling replacement voter, run `enroll` with `--data <dir>` as
well. It then writes a one-shot `JOIN` descriptor into the (possibly not
yet created) data directory, recording the decided database ID, the
configuration, and the registry digest, so the node's first start adopts
the cluster's identity instead of deriving one from flags.

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
  [`enrollment_ca_key`], [Owner-only CA private key enabling token/CSR
    issuance on this server. Omit it on ordinary nodes.],
  [`revocation_file`], [Node-ID denylist reloaded by a serving node.],
  [`admins`], [Array of administrator names for privileged membership
    operations, as for repeated `--admin` flags.],
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
`ZAXON_ENROLLMENT_CA_KEY` and `ZAXON_REVOCATION_FILE` name the two additional
server-only provider paths.

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
  "auth_file": "/etc/zaxon/psk",
  "tls_cert": "/etc/zaxon/node.crt",
  "tls_key": "/etc/zaxon/node.key",
  "tls_ca": "/etc/zaxon/ca.crt"
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
 "epoch_capacity":2048,"chain":"8f6a...94f8f","page_size":4096,
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
