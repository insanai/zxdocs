#import "theme.typ": *

= Clients and gateways: the wire protocol in practice

#objectives([
  By the end of this chapter you should be able to implement a Zaxonlite
  client in any language from the frame format up, authenticate it, name
  every RPC op the server accepts and its request and response fields,
  follow a `not_leader` redirect, and deploy against a gateway knowing
  exactly what the gateway does and does not protect.
])

Anything that can frame bytes over TCP can be a client. The reference
implementation is `zaxonlite/src/client.zig`, which the `zaxon` CLI
uses. The server side is `clientLoop` and `dispatch` in
`zaxonlite/src/server.zig`. This chapter is the contract between them.
We build it up in the order a connection does: frame, hello, handshake,
request, response, redirect.

== Connection bring-up

Every frame on the wire is `u32 total_after_length` (little-endian),
then `u8 kind`, then the body. The length counts the kind byte plus the
body, so it is never zero. The bound is 64 MiB, and anything larger is a
protocol error. The first frame on any connection must be a `hello`:

#field_table(
  [0, 2], [`version`], [Protocol version. Must equal 7 exactly. Any
    other value is rejected (`UnsupportedProtocolVersion`) and the
    connection closes. There is no downgrade negotiation, because a
    silent fallback would turn a configuration error into a security
    downgrade.],
  [2, 1], [`kind`], [`ConnectionKind`: 0 = peer, 1 = client. Clients
    send 1.],
  [3, 4], [`node_id`], [The sender's node id. Clients send 0.],
  [7, 16], [`database_id`], [The cluster's database identity, derived
    once at bootstrap and carried by the node's durable state
    afterwards. Clients send 0.],
  [23, 8], [`configuration_id`], [The sender's epoch. Clients send 0.],
)

The encoded hello is 31 bytes. The server answers nothing on success.
After a peer or client hello, and after the handshake below when one is
configured, it waits for the frames appropriate to that connection. An
enrollment hello is the narrow exception described below: it permits exactly
one bounded `enrollment_request`, not arbitrary RPC.

== Authentication: the PSK handshake and per-frame protection

When the server is configured with a pre-shared secret, the client's
`hello` is immediately followed by a challenge-response handshake. The
implementation is `zaxonlite/src/transport_auth.zig`, specified in the
format contract under Network protocol v7. From the client's
perspective:

+ Read one `auth_challenge` frame. It carries a fresh 32-byte nonce and
  the server's proof
  `HMAC-SHA256(secret, "zaxon.auth.server.v1" || hello || nonce)`,
  where `hello` is exactly the 31 bytes the client just sent. Verify
  the proof. A mismatch means the server does not hold the secret.
+ Send one `auth_response` frame carrying the 32-byte client proof over
  the domain `"zaxon.auth.client.v1"`. Both sides then derive the
  connection key with a third domain, `"zaxon.auth.session.v1"`.

Every later frame body in each direction is then

```text
u64 sequence_le || application_body || hmac_sha256
```

where the MAC covers the frame domain `"zaxon.auth.frame.v1"`, the
frame kind, the sequence, and the body. Each direction starts at
sequence zero, and the receiver accepts exactly the next sequence. An
invalid tag closes the connection (`AuthenticationFailed`). A wrong
sequence closes it too (`ReplayDetected`). The fresh responder nonce
prevents replay of an earlier handshake. The sequence prevents replay,
reorder, and truncation within a connection.

#callout(title: [Shared-secret integrity, not per-node identity], tone: "warning")[
  The PSK handshake proves that both endpoints possess the same PSK and
  provides frame integrity and replay rejection. It does not bind the
  hello's `node_id` to a distinct credential. It also does not encrypt:
  every body crosses the network in the clear. Zaxonlite intentionally
  treats an admitted application caller as having full database authority;
  end-user permissions belong in that application, not in this RPC
  protocol. Production TCP never relies on this PSK alone. The CLI permits
  it only with explicit `--dev-psk`, and then only when the listener and all
  peers are numeric loopback. A single local node can serve over an owner-only
  Unix-domain socket instead of TCP (chapter 2); for production TCP, the
  mutual TLS transport below adds per-node identity and confidentiality.
]

== Mutual TLS

When the server carries a TLS identity, the TCP connection completes a
mutual TLS 1.3 handshake before the first frame. The client presents a
certificate and key (`--tls-cert`, `--tls-key`) and verifies the server
against the cluster CA (`--tls-ca`); the server verifies the client
certificate against the same CA and refuses a connection without one. A
client certificate needs only to chain to the CA — its common name is not
interpreted. Peer connections are stricter: a peer's certificate common
name must be exactly `zaxon-node-<id>` for the node id its hello claims
(chapter 7). Everything in this chapter is unchanged inside the channel:
the same hello, the same optional PSK handshake, the same frames. A
plaintext client dialing a TLS listener fails the handshake and never
reaches the frame protocol.

The sole exception bootstraps that missing node certificate. A server
explicitly configured with `--enrollment-ca-key` may complete TLS without a
client certificate, but the first frame must be an enrollment hello bound to a
configured target and the next and only frame must be an `enrollment_request`.
The joiner pins the CA carried in its owner-only bundle and requires the exact
issuer common name, so this exception does not weaken ordinary peer or client
connections. The request contains a one-time secret, the database and target
bindings, and a signed CSR; it cannot execute SQL or any RPC. Chapter 13
describes token issuance and failure recovery.

== The RPC contract

One `rpc_request` frame carries one JSON object. The server replies with
one `rpc_response`. Success responses carry `"ok":true`. Failures are
`{"ok":false,"error":"<code>","message":"<text>"}`. Additive response
fields are compatible, so ignore fields you do not use. The dispatch in
`server.zig` accepts exactly these ops:

#table(
  columns: (auto, 1fr),
  table.header([*`op`*], [*Purpose*]),
  [`status`], [Reports one node's identity, role, ballot, and progress.],
  [`members`], [Lists the member registry with per-node capabilities.],
  [`leader`], [Names the current leader, if one is known.],
  [`exec`], [Executes a replicated write, optionally under a session.],
  [`query`], [Runs a read-only query at a chosen consistency level.],
  [`session`], [Opens a replicated client session.],
  [`wait`], [Blocks until the node reaches a condition you name.],
  [`snapshot`], [Takes an online snapshot and seals the journal epoch.],
  [`integrity`], [Verifies the image, chain, and payload store.],
  [`hash`], [Reports the state hashes for cross-node comparison.],
  [`expire-sessions`], [Deletes idle sessions.],
  [`issue-enrollment-token`], [Issuer-only: creates a short-lived bundle secret
    for one non-revoked configured peer. The caller is already authenticated by
    normal mTLS.],
  [`membership`], [Reports the decided registry, replacement phase, and
    quorum health. Registry-backed servers only.],
  [`replace-voter`], [Privileged: replaces one data voter with one fresh
    data voter through a decided configuration change.],
  [`failpoint`], [Arms a named fault. Test builds only.],
  [`stop`], [Requests a graceful shutdown.],
  [`backup`], [Streams a verified copy of the database. Not an
    `rpc_response`. See the backup section below.],
)

The subsections that follow give each op's request fields and success
response. A field not marked optional is required.

Protocol v7 applies no permission matrix to this list, with one exception:
`replace-voter` requires an administrator certificate, described in the
membership section below. Everything else matches the single-application
design: possession of the embedded handle or access to the service means
full database authority. An application that serves unrelated users must
authenticate them and expose only its own permitted operations. Failpoints
remain a test-only capability and must be disabled in real data
directories.

=== Observing the cluster: status, members, leader, hash

These four ops take no request fields beyond `op` itself.

`status` answers with `node_id`, `database_id`, `configuration_id`,
`role`, `node_type`, `leader`, `phase`, `quorum_available`,
`installation_state`, `ballot` (an object with `round`, `priority`, and
`node`), `decided_slot`, `applied_slot`, `journal_records`,
`epoch_capacity`, `chain`, `page_size`, and `snapshot`. The three
membership fields are defined in the membership section below; on a
registry-less host `phase` is `idle` and `installation_state` is
`not-applicable`. `status` describes
the one node you asked, so it is the op you send with
`require_leader = false` when you want a follower's view.

`members` answers with `voter_membership:"decided"` on a registry-backed
server and `voter_membership:"static"` on a registry-less local host,
plus a `nodes` array. Each entry carries `id`, `host`, `port`, `role`,
`votes`, `campaigns`, `stores_log`, `serves_reads`, `serves_writes`,
`promotion_eligible`, `self`, and `leader`.

`leader` answers with `leader:{id,host,port}`, or `leader:null` when no
leader is known.

`hash` answers with `chain`, `content`, and `applied_slot`. Two nodes
that report the same applied slot must report the same hashes. That is
how the test suites catch divergence.

=== Writing: exec

The request carries `sql`, and optionally `session` and `sequence`. The
session fields come as a pair: both or neither. The success response
carries `changes`, `slot`, and `replayed`. Chapter 8's exactly-once
contract rides on those two request fields, and we return to them below.

=== Reading: query

The request carries `sql`, an optional `level`, and an optional
`freshness_ms` that is valid only with level `any`. The success response
carries `columns` (an array of names), `rows` (an array of rows, each
cell a string or null), and the `level` that was actually served.

=== Sessions and waiting: session, wait

`session` takes no request fields and answers with `session_id`.
Opening a session is a replicated write, which is why the guarantee it
backs survives leader changes.

`wait` takes three optional fields: `applied` (a minimum applied slot),
`leader` (a boolean requiring this node to hold leadership), and
`timeout_ms`. It answers with `applied_slot`, `decided_slot`, `leader`,
and `configuration_id`. This is the op behind `zaxon wait` in the
quickstart.

=== Maintenance: snapshot, integrity, expire-sessions

`snapshot` takes no fields and answers with `configuration_id`, the new
epoch. `integrity` takes no fields and answers with `ok`, `sqlite_ok`,
`chain_ok`, and `payloads_ok`. `expire-sessions` takes `retain` and
answers with `expired`, the count removed.

=== Membership: membership, replace-voter

Both ops target a registry-backed server, one that persists its
membership as a decided registry (chapter 7). A registry-less local
host answers both with the error `no_registry`.

`membership` takes no request fields and is read-only. It answers with
`database_id`, `configuration_id`, `source:"decided"`,
`registry_digest`, `highest_allocated_node_id`, `phase`,
`quorum_available`, `installation_state`, and a `nodes` array of
`{id, role, endpoint}` records. `phase` names the replacement lifecycle
position: `idle`, `prepared`, `proposed`, `chosen`, `active-degraded`,
`complete`, or `retired`. `quorum_available` is an operational
observation, not an authorization: recently authenticated peers,
including the answering node, satisfy the majority quorums.
`installation_state` tracks the replacement voter's state transfer:
`not-applicable`, `not-started`, `transferring`, `verifying`,
`installed`, `active`, or `failed`.

`replace-voter` carries `operation`, `expected_config`, `old_node`,
`new_node`, and `endpoint`. It is the one privileged op in the table:
the connection must present an administrator certificate over mutual
TLS, with common name `zaxon-admin-<name>` for a name in the server's
allow-list, or the server answers `unauthorized`. The development PSK
transport cannot reach it. A request the registry refuses answers
`replace_rejected` with the reason in the message. The success response
reports the operation ID, the `phase` reached, and the resulting
configuration ID. Retrying a retained operation ID is idempotent.
Chapter 7 explains the lifecycle these fields track.

=== Operating: failpoint, stop

`failpoint` takes `name` and answers `{"ok":true}`. The server rejects
it unless it was started with `--enable-failpoints`; when enabled, every
admitted application caller can fault the node over the wire. `stop` takes
no fields, answers
`{"ok":true}`, and then shuts down gracefully.

=== The error codes you must handle

#table(
  columns: (auto, 1fr),
  table.header([*Error*], [*Meaning and what to do*]),
  [`bad_request`], [Malformed JSON or fields. Fix the client.],
  [`not_leader`], [This node cannot serve the request. Follow the
    embedded leader hint.],
  [`sql`], [SQLite rejected the statement. The statement had no durable
    effect.],
  [`session`], [Unknown session, sequence gap, or expired result.],
  [`ambiguous`], [The write's fate is unknown. Retry idempotently with
    the same session and sequence.],
  [`timeout`], [The operation ran out of time. Retry.],
  [`retry`], [The epoch is rolling over, or leadership changed during a
    read fence. Retry.],
  [`too_large`], [The payload exceeds the 64 MiB wire limit.],
  [`stale`], [A freshness-bounded `any` read could not be served fresh
    enough.],
  [`forbidden`], [This node type serves no SQLite reads.],
  [`unavailable`], [The node is not in a state to serve this.],
  [`internal`], [An unexpected server error. Inspect the message.],
)

== Redirects, read levels, and freshness

Writes, sessions, and non-`any` reads are answered only by the leader.
Any other node replies

```json
{"ok":false,"error":"not_leader","leader":{"id":1,"host":"10.0.0.5","port":9901}}
```

with `leader:null` when no leader is known. The reference client
(`callCluster`) tries endpoints round-robin, follows the embedded leader
hint, sleeps 150 ms between attempts, and gives up after 12 attempts
with `NoLeaderReachable`. A hint is followed only when it names one of
the caller's configured endpoints under PSK-only transport. With mTLS, an
unmatched numeric address can become a target, but only after its certificate
common name proves the advertised node ID under the trusted cluster CA. A
wrong name fails before the request is replayed. With `require_leader = false`
the first reachable node's answer is returned as-is. That is how you `status`
a follower.

`query` takes three levels. `any` is a local read with no leadership
required. `leader` reads the leader's applied state. `linearizable`, the
default, first completes an exact-ballot quorum read fence, so the
leader proves it is still the leader before answering.

#predict([
  You send a `level:"any"` read with no `freshness_ms` to a replica that
  has been partitioned from the cluster for an hour. Does the read fail?
  Decide before reading on.
])

It succeeds. Without a freshness bound, `any` explicitly permits an
arbitrarily stale local snapshot. If you need a bound, send
`freshness_ms`. A learner then rejects the read with `stale` in three
cases: it has never heard from a leader, its last leader contact is
older than the bound, or the leader's last reported decided slot is
ahead of the learner's applied slot.

== Sessions over the wire

`{"op":"session"}` performs a replicated write and returns `session_id`.
Subsequent writes carry `session` and `sequence` inside `exec`. The
response's `replayed` field reports whether the recorded result was
returned instead of executing SQL. After `ambiguous` or a connection
loss, the recovery is always the same: reconnect anywhere, follow
redirects, and resend the *same* session and sequence. Exactly-once
holds across leader changes because the session table is replicated
state.

== A worked exchange

Frame kinds elided. Each line is one JSON body as produced by
`server.zig` and consumed by `client.zig`:

```console
-> {"op":"exec","sql":"insert into c(b) values ('tea')"}
<- {"ok":false,"error":"not_leader","leader":{"id":1,"host":"127.0.0.1","port":9901}}
   (client reconnects to 127.0.0.1:9901, repeats the hello + handshake)
-> {"op":"session"}
<- {"ok":true,"session_id":7}
-> {"op":"exec","sql":"insert into c(b) values ('tea')","session":7,"sequence":1}
<- {"ok":true,"changes":1,"slot":42,"replayed":false}
-> {"op":"exec","sql":"insert into c(b) values ('tea')","session":7,"sequence":1}
<- {"ok":true,"changes":1,"slot":42,"replayed":true}
-> {"op":"query","sql":"select count(*) from c","level":"linearizable"}
<- {"ok":true,"columns":["count(*)"],"rows":[["1"]],"level":"linearizable"}
```

Read the two `exec` lines closely. The retry carries the same session
and the same sequence, and the server answers with the same slot and
`replayed:true`. No SQL ran the second time.

== Backup streaming

`{"op":"backup"}` is the one request not answered by an `rpc_response`
on success. The leader replies `backup_begin`, carrying a `u64 size` and
a 32-byte SHA-256 of the whole image. Then come ordered `backup_chunk`
frames, each a `u64 offset` plus bytes, contiguous from zero. Then
`backup_end`. The reference client writes to an exclusive temporary
file, verifies the declared digest over every received byte, fsyncs, and
only then renames into place and syncs the directory. Receiving an
`rpc_response` instead of `backup_begin` means the node declined, with
`not_leader` or `retry`. Under an authenticated session every backup
frame is sequence-protected like any other.

== Gateways

A gateway (`zaxonlite/src/gateway.zig`) is a stateless TCP router that
deliberately operates *below* the wire protocol. It never parses frames
and never terminates authentication. It holds no secret, no Paxos state,
and no SQLite state. Each inbound connection is proxied byte-for-byte to
one backend, chosen round-robin with failover to the next backend when a
dial fails, and copied in both directions until either side closes.
Five consequences are worth stating directly.

- *Authentication and encryption are end-to-end.* The TLS handshake, hello,
  optional PSK exchange, and protected frames pass through unmodified. The
  client authenticates the storage node itself. A compromised gateway can drop
  or delay traffic, but cannot read, forge, replay, or alter it undetected.
- *Redirects still happen.* A gateway does not track the leader. If it
  routes your write to a follower you receive `not_leader` with the
  leader's real address, and the reference client then dials that
  address directly.
- *Backup streams need no special path.* They are bytes like everything
  else.
- *TLS is passthrough, not terminated.* The gateway does not take its own TLS
  identity. A client starts TLS with the selected storage node through the
  raw proxy; that backend still requires a CA-valid client certificate, and
  the client still requires a canonical `zaxon-node-<id>` server certificate.
  Passing `--tls-*` to the gateway itself is therefore a usage error. A PSK,
  when configured, also remains inside the end-to-end TLS stream.
- *Admission is bounded.* At most 128 raw connections are proxied at once.
  Storage backends independently enforce their global and per-peer limits and
  handshake/idle deadlines. The gateway never turns into an unbounded list of
  sockets while a client stalls its TLS handshake.

To deploy against one, list the gateway's `host:port` as an endpoint and
give the client the same TLS CA and client identity it uses when dialing a
storage node directly. Restarting a
gateway costs only open connections. In the role registry a gateway is
`ZAXONLITE_GATEWAY` (`gateway` on the wire). The embedded facade starts
one automatically when the local member has that role, backending onto
every registry member whose role serves reads or writes.

#exercise("10.1", [
  Your client sends `{"op":"query","sql":"select 1","level":"any",
  "freshness_ms":200}` to a read replica and receives
  `{"ok":false,"error":"stale",...}`. List the three distinct conditions
  in the server that produce this, and state which of them can clear
  without any new client action.
], hint: [two involve the learner heartbeat, and one involves never
  having heard from a leader at all.])

#teach_back([
  From memory, write down the byte layout of an authenticated `exec`
  request frame, from the `u32` length to the final HMAC byte, and state
  what the receiver checks and in which order before the JSON body
  reaches `dispatch`. Then check yourself against `transport_auth.zig`'s
  `Session.readFrame`.
])
