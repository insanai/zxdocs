#import "theme.typ": *
#import "figures.typ": *

#part_page("IV", [Operating], [
  We turn the laptop cluster from chapter 1 into a deployment someone can be
  paged for. Configuration, security, monitoring, and rehearsed runbooks come
  first; the worked examples then turn those habits into reflexes.
])

= Operations

#objectives([
  By the end of this chapter you should be able to configure a member from a
  file instead of a pile of flags, secure a networked cluster with a
  pre-shared key, read `status` and `members` as monitoring signals, act on
  the failure playbook without improvising, run the backup and disaster
  recovery runbooks, and roll a new binary through a live cluster.
])

#checkpoint("bring-up")[
  Chapter 1 built the binary, ran one durable node, and drove a three-voter
  cluster through a killed leader. We assume you can do all of that without
  looking. Chapter 2 holds the full command reference. This chapter teaches
  only what an operator needs beyond both.
]

== What changes off the laptop

The quickstart ran everything on `127.0.0.1`. A production deployment
changes four things, and nothing else.

+ Listen and peer addresses become real network addresses, and `zaxon` then
  refuses to start until you configure an authentication key.
+ Each `--peer` may carry a role suffix, as in `2@10.0.0.2:9901/data-voter`,
  and every storage node must receive the same registry.
+ Two clusters whose members use the same ids would derive the same database
  identity, so each deployment gets its own `--cluster-id`.
+ Flag piles give way to one configuration file per host.

The rest of this chapter walks through each change, then through the
runbooks you should rehearse before you need them.

== Roles, from the operator's chair

Earlier chapters explained why the role system exists. The operator's view
fits in five sentences. A `data-voter` votes, campaigns, stores SQL, and
serves clients. A `witness` votes but refuses every SQL request, so a small
third failure domain can break ties without holding data. A `standby` and a
`read-replica` follow the log without voting; the standby is promotion
material, the replica serves reads. A `gateway` stores nothing and forwards
clients to the nodes that do. Every node is told its own role with `--role`
and learns everyone else's from the peer suffixes.

One rule matters operationally: an existing data directory pins its role.
Restarting a node with a different `--role` is rejected. Changing a member's
role is a controlled migration, not a flag edit.

== The command surface

Chapter 2 is the complete command and flag reference. Operators need three
facts on top of it.

+ Client mode accepts a comma-separated endpoint list and follows
  `not_leader` redirects on its own, so scripts should name every member and
  ignore leadership entirely.
+ Commands that take `--data` open the node in-process and hold the
  directory lock, so run them on a stopped node; a directory locked by a
  running server exits with code 4 and never risks corruption.
+ Runbooks branch on exit codes, so learn them once.

#table(
  columns: (auto, 1fr),
  table.header([*Exit code*], [*Meaning*]),
  [0], [The command succeeded.],
  [1], [The SQL statement or the session request failed.],
  [2], [The invocation or the configuration was malformed.],
  [3], [An integrity check found a mismatch.],
  [4], [The node was unavailable: locked, corrupt, or without a reachable
    leader.],
)

== Configuration: flags, environment, file

Every option can come from three places. The precedence is strict:
command-line flags override `ZAXON_*` environment variables, and those
override the JSON configuration file. The file is named by `--config <path>`
or by the `ZAXON_CONFIG` environment variable. Without either, no file is
read. `version` and `help` never load configuration.

The file is one strict JSON object of at most 1 MiB. Unknown fields are
rejected. This is a deliberate safety choice: a typo fails loudly with exit
code 2 instead of being silently ignored. Every field is optional.

#table(
  columns: (auto, auto, 1fr),
  table.header([*Field*], [*Flag and environment*], [*Meaning*]),
  [`data`], [`--data`, `ZAXON_DATA`], [The node data directory, created when
    missing; selects embedded mode.],
  [`connect`], [`--connect`, `ZAXON_CONNECT`], [Comma-separated `host:port`
    server endpoints; selects client mode.],
  [`node`], [`--node`, `ZAXON_NODE`], [This node's integer id, for `serve`.],
  [`role`], [`--role`, `ZAXON_ROLE`], [`data-voter`, `witness`, `standby`,
    `read-replica`, or `gateway`.],
  [`listen`], [`--listen`, `ZAXON_LISTEN`], [The `host:port` listen endpoint,
    for `serve`.],
  [`peers`], [`--peer` (repeat), `ZAXON_PEERS`], [An array of
    `id@host:port[/role]` peer specifications.],
  [`cluster_id`], [`--cluster-id`, `ZAXON_CLUSTER_ID`], [Extra entropy for
    the derived database identity.],
  [`auth_file`], [`--auth-file`, `ZAXON_AUTH_FILE`], [The path to the
    pre-shared-key provider file. Always a path, never the key.],
)

A complete member configuration looks like this:

#code_file("/etc/zaxon/n1.json")[
```json
{
  "data": "/var/lib/app/n1",
  "node": 1,
  "role": "data-voter",
  "listen": "10.0.0.1:9901",
  "peers": ["2@10.0.0.2:9901/data-voter", "3@10.0.0.3:9901/data-voter"],
  "cluster_id": "prod-eu-1",
  "auth_file": "/etc/zaxon/psk"
}
```
]

With `ZAXON_CONFIG=/etc/zaxon/n1.json` exported, starting the member is just
`zaxon serve`. Operator commands on the same host, such as `zaxon status` or
`zaxon integrity-check`, find the directory the same way. A malformed value
from any source is a usage error with exit code 2, never a silent default.
That covers an unreadable file, a non-integer `ZAXON_NODE`, and an unknown
role alike.

== Securing a deployment

The transport authenticates with a pre-shared key. Both sides prove
possession of the secret in a challenge-response handshake. The responder
contributes a fresh 32-byte random nonce, so an earlier handshake cannot be
replayed. After the handshake, every frame carries an HMAC-SHA256 tag over
the frame kind, a strictly increasing sequence number, and the body. A bad
tag, a skipped sequence, or a peer that never authenticates closes the
connection.

Know exactly what that buys.

- Protected: peer authentication, frame integrity, and replay rejection.
- Not protected: confidentiality. SQL text, query results, and page images
  travel in the clear. Where the data itself must be hidden from the
  network, run the endpoints over an encrypted tunnel such as WireGuard, an
  SSH tunnel, or a mesh VPN until native TLS is added.

The secret comes only from a provider file, named by `--auth-file <path>`,
by `ZAXON_AUTH_FILE`, or by the `auth_file` configuration field. The file
may be at most 4096 bytes. One conventional trailing line ending is not part
of the key; every other byte is, including spaces. The key must be at least
32 bytes, and shorter providers are rejected before any socket opens. Every
node and every client of one cluster must present the same secret.

#callout(title: [Secrets are paths, never values], tone: "warning")[
  There is no flag that accepts a literal key, and there never will be:
  command lines leak through process listings and shell history. Give the
  provider file tight permissions, readable by the service user only. The
  process zeroes the key bytes in memory when it is done with them.
]

Unauthenticated operation is confined to one machine. `serve` refuses to
start, with exit code 4, when the listen address or any peer address is
non-loopback and no secret is configured. Loopback means `127.0.0.0/8` or
`::1`. Binding `0.0.0.0` counts as non-loopback even on a single-host
cluster. This is a startup check, not a warning, and there is no flag to opt
out of authentication on a network address. The rule protects safety: an
unauthenticated peer that could vote or certify commits could silently
diverge the cluster.

== Monitoring

`status --json` is the machine surface. It reports `node_type`, the Paxos
`role`, the current leader, `decided_slot` and `applied_slot`, the journal
record count, the epoch capacity, the chain hash, and the installed snapshot
generation. A served node also reports its ballot. In client mode,
`members --json` returns the runtime registry with one entry per node: id,
address, role, the capability flags (`votes`, `campaigns`, `stores_log`,
`serves_reads`, `serves_writes`, `promotion_eligible`), plus `self` and
`leader` markers. Embedded `members` lists only the static member ids.

Watch four signals.

+ No leader means no writes, so alert on a failing
  `zaxon wait --leader` quickly.
+ A growing gap between `decided_slot` and `applied_slot` means the node
  decides faster than it applies, and reads on that node fall behind.
+ The `chain` value must be equal across members at the same applied slot,
  because equality means identical applied history; a mismatch is an
  emergency, not a curiosity.
+ The journal record count against the epoch capacity shows how full the
  current epoch is, which tells you when a `snapshot` is due.

== Failure playbook

#predict([
  A power cut tears the last journal record in half on one member. On
  restart, should that node refuse to start, repair the record, or drop it?
  Decide before you read the table.
])

#table(
  columns: (1fr, 1.6fr),
  table.header([*Symptom*], [*What happens, and what to do*]),
  [One member down], [Writes and linearizable reads continue on the
    remaining two. Restart the member; it catches up on its own, from the
    journal suffix or through a snapshot transfer across a sealed epoch.],
  [Two members down], [No quorum. Writes and fenced reads refuse, while
    `--level any` reads still answer locally. Add `--freshness-ms` when a
    disconnected or lagging node should refuse instead. Restore a member.],
  [`current.db` lost or replaced with an old copy], [Nothing is lost. On the
    next start the node discards the image and rebuilds it from the snapshot
    plus the journal, validating the batch marker. Just restart it.],
  [Journal tail torn by power loss], [The tail is truncated automatically on
    open. This is safe because the lost suffix was never acknowledged to any
    client.],
  [Journal corrupt in the middle], [The node refuses to open, because an
    interior gap would mean serving history it cannot prove. Reimage from
    the healthy quorum: empty the directory and restart, and snapshot
    transfer plus catch-up rebuild everything.],
  [Disaster of last resort], [`zaxon backup --to app.db` on any surviving
    member yields a plain SQLite file that opens anywhere.],
)

The torn-tail row answers the prediction: the node drops the half-written
record. Refusing would sacrifice liveness for data no client was ever
promised, and repairing would mean inventing bytes.

== Backup, restore, and disaster recovery

Take backups from the live cluster with `zaxon backup --to <path>`. In
embedded mode this is a local `VACUUM INTO`. In client mode the command
locates the leader and streams the copy over the authenticated transport,
verifying an end-to-end SHA-256 before installing the destination file. An
interrupted stream installs nothing, so a retry against the endpoint list is
always safe. Either way the result is a plain, consistent SQLite database
that any SQLite tool can open.

#predict([
  You have last night's `backup.db`. You copy it into a member's data
  directory as `current.db` and start the node. Which rows does the node
  serve? Decide, then read on.
])

The node serves the cluster's rows, not the backup's. Every open discards
the materialized image and rebuilds it from the snapshot plus the journal.
The journal is authoritative; the `.db` file is a cache. There is no import
command, so restoring a logical backup means building a new cluster.

+ Provision fresh data directories on every member, which creates a new
  database identity.
+ Start the new cluster and wait for a leader.
+ Replay the backup's schema and rows through `zaxon sql` or through your
  application's own loader.
+ Verify row counts, then run `zaxon integrity-check` before pointing
  clients at it.

For a node whose directory survives but whose health is in doubt:

+ Copy the directory and work only on the copy, never on the sole original.
+ Run `zaxon recover --data <dir>`, which rebuilds the image from the
  verified snapshot plus the committed journal suffix and then runs the full
  integrity check, reporting pass or fail per section.
+ Exit code 0 means the node is sound, so restart it.
+ Exit code 3, or a node that refuses to open because its durable journal
  prefix is damaged, means the local history is gone; restore a verified
  logical backup or reimage the member from the healthy quorum.

#callout(title: [Journal editing is unsupported], tone: "danger")[
  Never fill a gap, patch a checksum, or truncate an interior record by hand
  to make a node open. The journal is the authoritative history. A
  hand-edited journal can vote, and a voting node with invented history can
  silently diverge the cluster. That is a safety violation, not an
  inconvenience. A node that cannot replay its own prefix must be restored
  from backup or reimaged. Those are the only supported paths.
]

== Rolling upgrade

The upgrade contract is frozen in the format chapter. The runbook form:

+ Verify first: run `zaxon integrity-check` on every member and take one
  remote logical backup that you have actually opened.
+ Record the baseline: capture each member's `zaxon version` and, from
  `status --json`, its database id, configuration id, and applied slot.
+ Stop one follower, install the new binary, restart it, and wait for it to
  catch up with `zaxon wait --applied <slot>`.
+ Repeat for the remaining followers, one at a time.
+ Upgrade the leader last: stopping it triggers a normal election, and
  writers follow the redirect.
+ Verify again: run `zaxon integrity-check` on every member and compare
  `chain` values, which must be equal at the same applied slot.

If any step fails, stop that node and diagnose. Never delete or rewrite a
journal to force a member to join.

#callout(title: [Wire-version bridge], tone: "warning")[
  Wire compatibility is exact-major: protocol version 4 speaks only to
  version 4. A release that changes the wire version cannot use this rolling
  procedure. It requires an explicitly dual-version bridge release, and
  there is no automatic downgrade. Downgrading is supported only when the
  older binary declares every installed durable format and wire version
  compatible.
]

#exercise([13.1], [
  Rehearse both recovery paths on the chapter 1 loopback cluster. First
  reimage: stop one voter, delete its entire data directory, restart it with
  its original command, and prove with `status --json` that its `chain`
  converges to the other members' value. Then restore: take a `backup`, stop
  all three voters, delete all three directories, rebuild the cluster, and
  reload the backup through `zaxon sql`. State exactly which writes each
  path preserved, and why the second path produced a new database identity.
], hint: [
  Reimaging keeps the replicated history and the identity, because the
  quorum still holds both. A logical restore replays only rows into a
  brand-new history.
])

#teach_back([
  Explain to a colleague why Zaxonlite ships no journal repair tool. Use the
  words authoritative, acknowledged, quorum, and reimage. Then explain what
  a hand-patched journal could do to the cluster that a deleted one cannot.
])
