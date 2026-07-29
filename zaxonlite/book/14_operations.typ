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
  file instead of a pile of flags, state the exact limitations of the
  legacy pre-shared key, execute one-time certificate enrollment, read
  `status` and `members` as monitoring signals, act on
  the failure playbook without improvising, run the backup and disaster
  recovery runbooks, replace one data voter through the decided
  registry, and roll a new binary through a live cluster.
])

#checkpoint("bring-up")[
  Chapter 1 built the binary, ran one durable node, and drove a three-voter
  cluster through a killed leader. We assume you can do all of that without
  looking. Chapter 2 holds the full command reference. This chapter teaches
  only what an operator needs beyond both.
]

== What changes off the laptop

The quickstart ran everything on `127.0.0.1`. Production TCP now fails closed
unless mutual TLS is configured. Automated token enrollment is available for
members already in the registry; it is bootstrap, not a hidden shared
secret or a membership protocol. A realistic deployment
changes at least these four things.

+ Listen and peer addresses become real network addresses, and `zaxon` then
  refuses to start until you configure the mutual-TLS identity. A PSK may be
  layered inside TLS but cannot replace it.
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

== The shell history file

The interactive `zaxon sql` shell records executed statements so `ctrl+r`
search survives restarts, and statements routinely contain material an
operator would not commit to disk knowingly — tokens pasted into inserts,
credentials in `pragma` or setup statements. Four controls bound the
exposure; runbooks that handle secrets should name which one they rely on.

- The file is written with owner-only permissions (`0600`). In embedded
  mode it lives inside the data directory as `.zaxon_history`, so the
  protections already required for the data directory cover it. In client
  mode nothing is persisted unless `ZAXON_HISTORY` names a path.
- `--no-history` disables persistence for one session; `.history off`
  disables it from inside the shell; `.history clear` empties it.
- A statement typed with a leading space is never recorded — the standard
  escape hatch for one sensitive statement.
- Scripted (non-terminal) invocations never read or write history at all.

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
  [`connect`], [`--connect`, `ZAXON_CONNECT`], [Comma-separated server
    endpoints, each `host:port` or `unix:<path>`; selects client mode.],
  [`node`], [`--node`, `ZAXON_NODE`], [This node's integer id, for `serve`.],
  [`role`], [`--role`, `ZAXON_ROLE`], [`data-voter`, `witness`, `standby`,
    `read-replica`, or `gateway`.],
  [`listen`], [`--listen`, `ZAXON_LISTEN`], [The listen endpoint for `serve`:
    `host:port`, or `unix:<path>` for single-node local service.],
  [`peers`], [`--peer` (repeat), `ZAXON_PEERS`], [An array of
    `id@host:port[/role]` peer specifications.],
  [`cluster_id`], [`--cluster-id`, `ZAXON_CLUSTER_ID`], [Extra entropy for
    the derived database identity.],
  [`auth_file`], [`--auth-file`, `ZAXON_AUTH_FILE`], [The path to the
    pre-shared-key provider file. Always a path, never the key.],
  [`tls_cert`], [`--tls-cert`, `ZAXON_TLS_CERT`], [The node certificate
    PEM for mutual TLS. All three TLS fields go together.],
  [`tls_key`], [`--tls-key`, `ZAXON_TLS_KEY`], [The node private key
    PEM.],
  [`tls_ca`], [`--tls-ca`, `ZAXON_TLS_CA`], [The cluster CA PEM that
    every peer certificate must chain to.],
  [`enrollment_ca_key`], [`--enrollment-ca-key`,
    `ZAXON_ENROLLMENT_CA_KEY`], [Owner-only CA key enabling the deliberately
    configured token/CSR issuer. Omit on ordinary nodes.],
  [`revocation_file`], [`--revocation-file`, `ZAXON_REVOCATION_FILE`],
    [Reloaded configured-node-ID denylist.],
  [`sync`], [`--sync`, `ZAXON_SYNC`], [Durability sync mode: `full`
    (the default) or `os` (development only on macOS).],
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
  "auth_file": "/etc/zaxon/psk",
  "tls_cert": "/etc/zaxon/node.crt",
  "tls_key": "/etc/zaxon/node.key",
  "tls_ca": "/etc/zaxon/ca.crt"
}
```
]

With `ZAXON_CONFIG=/etc/zaxon/n1.json` exported, starting the member is just
`zaxon serve`. Operator commands on the same host, such as `zaxon status` or
`zaxon integrity-check`, find the directory the same way. A malformed value
from any source is a usage error with exit code 2, never a silent default.
That covers an unreadable file, a non-integer `ZAXON_NODE`, and an unknown
role alike.

== Durability against power loss: the sync mode

The default sync mode, `full`, is the safe one, and production needs no
flag at all. On macOS it makes every authoritative sync flush the
drive's volatile cache with `F_FULLFSYNC`, so an acknowledged write
survives a power cut and a voter can never forget a promise it made.
Chapter 6 explains why that is a safety property of the consensus, not
a data-loss preference. On Linux plain `fsync` already reaches stable
media, the two modes are equivalent, and this section changes nothing.

The safety has a measured price on macOS. Each replicated write pays
one full flush per voting node at its commit point — the journal barrier,
which the payload install rides (chapter 6). Protocol v8 queues the payload
and phase-two accept before the leader barrier, so follower storage and flush
overlap it without allowing an accepted reply into the core early. On this
Apple-silicon host the current 256-byte, three-voter mTLS run records roughly
15.94 ms p50 and 63 writes per second under `full`; chapter 18 reads the exact
row from JSON. Reads are untouched. Sustained full-mode write load can also stall the leader's
tick loop long enough for leadership to move, visible as occasional
large latency maxima. Use `--sync os` only for development loops and
benchmarks on macOS, never for a directory whose votes you intend to
keep.

== The PSK layer

The optional inner layer authenticates with a pre-shared key. Both sides prove
possession of the secret in a challenge-response handshake. The responder
contributes a fresh 32-byte random nonce, so an earlier handshake cannot be
replayed. After the handshake, every frame carries an HMAC-SHA256 tag over
the frame kind, a strictly increasing sequence number, and the body. A bad
tag, a skipped sequence, or a peer that never authenticates closes the
connection.

Know exactly what that buys—and what it does not.

- Protected: proof that the remote endpoint holds the cluster-wide PSK,
  frame integrity, and replay rejection on one connection.
- Not protected: node identity. The unauthenticated hello supplies the claimed
  node ID and peer/client kind. Any PSK holder can impersonate a configured
  voter.
- Not provided: database-user authorization. This is intentional: the
  embedding or socket-owning application is the single database principal and
  applies end-user policy before calling Zaxonlite.
- Not protected: confidentiality. SQL text, results, pages, snapshots and
  backups travel in cleartext.

An encrypted tunnel can hide bytes from the network, but it does not bind the
PSK holder to a configured node identity. Production startup therefore refuses
PSK-only TCP. The explicit `--dev-psk` exception is restricted to numeric
loopback for the one-machine quickstart and local development; it requires an
owner-only provider and cannot be combined with mTLS or gateway mode. Because
leader advertisements cannot be identity-bound in this mode, clients supply
every member in `--connect` and rotate only through that seed list. Local
single-node service already has its production form: a Unix-domain socket
protected by filesystem permissions, described below. For production TCP, the
mutual TLS transport in the next section supplies both per-node identity and
confidentiality; the one-time enrollment flow below automates certificate
issuance after initial CA and issuer bootstrap. Application authorization
stays outside Zaxonlite; see the security remediation plan.

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
  loader requires a regular non-symlink file with no group/world permission
  bits (mode 0600). The CLI
  loader zeroes its original allocation, but embedded mode keeps an arena copy
  that is not explicitly wiped on close.
]

Every production TCP listener requires the complete TLS identity and exits 4
otherwise. There is no silent fallback to PSK or plaintext. `--dev-psk` is an
explicit opt-in and accepts only the exact numeric loopback hosts `127.0.0.1`
and `::1` for the listener and every peer. The internal
`--insecure-test-tcp` escape hatch is rejected unless failpoints are enabled;
it exists only for deterministic fault harnesses. The refusal diagnostic names
the Unix-socket and local-development alternatives.

== The mutual TLS transport

The second transport mode gives every node its own certificate. When
`serve` is started with `--tls-cert <pem>`, `--tls-key <pem>`, and
`--tls-ca <pem>` — always all three together — every TCP connection the
process accepts or dials runs TLS 1.3 at minimum with mutual
verification: both sides must present a certificate that chains to the
cluster CA, and a connection without one is refused. Client commands
take the same three flags, the same `tls_cert`/`tls_key`/`tls_ca`
configuration fields, and the same `ZAXON_TLS_CERT`, `ZAXON_TLS_KEY`,
and `ZAXON_TLS_CA` environment variables.

Identity is bound by certificate common name. A peer connection must
present the certificate issued for the node id it claims in its hello,
with common name exactly `zaxon-node-<id>`; the check runs on both the
accepting and the dialing side, so neither direction trusts a claimed id
on its own. A client certificate needs only to chain to the cluster CA;
its name is not interpreted. TLS also encrypts the wire, which the PSK
mode never did, and the two modes compose: when both are configured, the
PSK challenge-response runs inside the TLS channel. Gateway mode does
not support `--tls` yet and rejects the flags with a usage error.

Bootstrap is deliberately small. Create the cluster CA once, then use it out
of band to issue one initial `zaxon-node-<id>` identity for the issuer and one
operator client identity. The issuer automates all later configured-node
certificates through short-lived, one-time token/CSR enrollment. The `openssl`
CLI is sufficient for that initial step:

```console
$ openssl ecparam -name prime256v1 -genkey -noout -out ca.key
$ chmod 600 ca.key
$ openssl req -new -x509 -key ca.key -sha256 -days 365 \
    -subj '/CN=zaxon-cluster-ca' \
    -addext basicConstraints=critical,CA:TRUE \
    -addext keyUsage=critical,keyCertSign,cRLSign -out ca.crt
$ openssl ecparam -name prime256v1 -genkey -noout -out n1.key
$ chmod 600 n1.key
$ openssl req -new -key n1.key -out n1.csr -subj '/CN=zaxon-node-1'
$ printf '%s\n' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature' \
    'subjectAltName=DNS:zaxon-node-1' \
    'extendedKeyUsage=serverAuth,clientAuth' > n1.ext
$ openssl x509 -req -in n1.csr -CA ca.crt -CAkey ca.key \
    -CAcreateserial -sha256 -extfile n1.ext -out n1.crt -days 365
```

Issue the operator client certificate the same way with a distinct common name such as
`zaxon-client`; it needs `clientAuth` and, because the same reference identity
may serve embedded members, may also carry `serverAuth`. A Zaxon client refuses
a server certificate whose common name is not the canonical
`zaxon-node-<positive-id>` shape, so a CA-issued client principal cannot be
reused as a storage endpoint identity.

With one such identity per node, the member from the configuration file
above starts as:

```console
$ zaxon serve --data /var/lib/app/n1 --node 1 --listen 10.0.0.1:9901 \
    --peer 2@10.0.0.2:9901 --peer 3@10.0.0.3:9901 \
    --tls-cert /etc/zaxon/n1.crt --tls-key /etc/zaxon/n1.key \
    --tls-ca /etc/zaxon/ca.crt \
    --enrollment-ca-key /etc/zaxon/ca.key
```

The enrollment CA key must be a regular, non-symlink file with no group or
world permissions and must match `--tls-ca`. It is not needed for consensus or
normal mTLS, so keep it on as few designated issuer nodes as your availability
needs require. Issuance is not a membership operation: the target must already
appear in the issuer's registry, and must not be denied by the node-ID
revocation file. On a registry-backed server that means the decided
registry, so a replacement's token exists only after its stop sign is
chosen.

An operator who already has a valid client identity creates an owner-only
bearer bundle for node 2:

```console
$ zaxon enroll-token --connect 10.0.0.1:9901 --node 2 \
    --to node2.token --ttl-seconds 600 \
    --tls-cert operator.crt --tls-key operator.key --tls-ca ca.crt
```

The bundle contains the issuer endpoint, full CA certificate, database and
node bindings, expiry, and a random 256-bit secret. The issuer stores only a
domain-separated hash of that secret. Transfer the file through an
authenticated operational channel and keep mode 0600; possession is sufficient
to redeem it until expiry. On node 2:

```console
$ zaxon enroll --token-file node2.token --identity-dir /etc/zaxon/node2
$ zaxon serve --data /var/lib/app/n2 --node 2 --listen 10.0.0.2:9901 \
    --peer 1@10.0.0.1:9901 --peer 3@10.0.0.3:9901 \
    --tls-cert /etc/zaxon/node2/node.crt \
    --tls-key /etc/zaxon/node2/node.key \
    --tls-ca /etc/zaxon/node2/ca.crt
```

`enroll` pins the bundled CA and exact issuer common name, generates the P-256
private key and signed CSR locally, and accepts only a pinned-CA-signed
certificate matching that key and `zaxon-node-2`. It atomically installs
`node.key`, `node.crt`, and
`ca.crt` into a new owner-only directory and removes the token bundle after
success. The private key never crosses the network.

The issuer verifies the CSR and every binding, atomically moves its token
record from pending to used, syncs that directory, and only then signs. Thus a
crash after consumption can lose the response but cannot issue twice. Treat
any ambiguous enrollment failure as consumed and request a new token; the
issuer intentionally keeps no result cache or retry protocol.

and a client reaches it with the client certificate:

```console
$ zaxon status --connect 10.0.0.1:9901 --tls-cert client.crt \
    --tls-key client.key --tls-ca ca.crt
```

An unreadable certificate, a key that does not match, a private-key symlink or
broad private-key mode, or a missing CA
file fails startup with `-- TLS IDENTITY FAILED --`. Keep the key files
readable by the service user only; like the PSK, they are named by path
and never by value. The implementation links the system OpenSSL 3
libraries rather than bundling a TLS stack; macOS builds default to the
Homebrew `openssl@3` prefix. Other targets take `-Dopenssl-prefix` pointing at
an OpenSSL 3 SDK built for that target. Windows SDKs are linked by their
posix names, `ssl` and `crypto`, except under the MSVC ABI, which expects
`libssl` and `libcrypto`.

`--revocation-file <path>` (or `ZAXON_REVOCATION_FILE`) supplies the simple
static-membership revocation override: one configured node ID per line, with
`#` comments. The server reloads it once per second, rejects new handshakes,
and closes matching live inbound and outbound sockets immediately. A malformed
reload retains the last valid set. Revocation is by node ID, not certificate
serial. A canonical `zaxon-node-<id>` certificate is checked even when used on
a client connection; unrelated operator-client common names remain the single
application authority described above. Admitting a replacement under a denied
node ID requires the operator to
remove it from the denylist after replacing credentials. Removing a data
voter permanently has its own online procedure: the decided one-for-one
replacement in this chapter's replacement runbook. It is
operator-initiated, never automatic.

#callout(title: [Current release restriction], tone: "danger")[
  Do not treat PSK-only TCP as the production trust boundary: it has no
  per-node identity and no confidentiality. `--dev-psk` merely confines that
  tradeoff to one host. The mutual TLS transport supplies both properties.
  One-time issuance is automated only for a configured target;
  initial CA/issuer provisioning and later rotation remain operator work. The
  node-ID denylist provides immediate revocation. Admission is globally
  and per-peer capped, handshakes and established idle sockets have deadlines,
  transfers are bounded, and remote queries default to 10,000 rows, 16 MiB,
  1 MiB of SQL text, and a 10-million SQLite VM-instruction budget. Zaxonlite
  does not require separate operator credentials: the application is the
  one database authority. Follow the release gates in
  `docs/zds/records/0003-zaxonlite-security-remediation-plan.typ`.
]

#callout(title: [Plaintext at rest], tone: "warning")[
  The current database, captured payloads, journals, snapshots, and backups are
  plaintext. Zaxonlite reads the WAL and applies page images through direct I/O
  outside SQLite's VFS, so SQLCipher or an encrypted VFS is not presently a
  drop-in option. Use platform full-disk or filesystem encryption when powered-
  off media theft is in scope. An encrypted edge profile is future work and
  needs its own direct-I/O, recovery, snapshot, backup, key, and rekey tests.
]

== Local service over a Unix-domain socket

`zaxon serve --listen unix:<path>` serves a single local node over a
Unix-domain socket instead of TCP, and filesystem permissions become the
local authorization boundary. The server restricts the socket to owner-only
permissions (mode 0600) immediately after binding, so only the owning user
can connect; widening access is a deliberate host configuration, not a
default. A pre-existing file at the socket path is refused — never silently
unlinked or taken over — so a stale socket left by a crash requires explicit
operator removal after confirming no server owns it. An orderly shutdown
removes the socket path. The mode serves exactly one node: configured peers
are rejected, because cluster links require TCP, and gateway mode is
TCP-only. Clients name the socket the same way everywhere an endpoint is
accepted: `--connect unix:<path>`, the `connect` configuration field, or
`ZAXON_CONNECT`.

== Monitoring

`status --json` is the machine surface. It reports `node_type`, the Paxos
`role`, the current leader, `decided_slot` and `applied_slot`, the journal
record count, the epoch capacity, the chain hash, and the installed snapshot
generation. A served node also reports its ballot. In client mode,
`members --json` returns the runtime registry with one entry per node: id,
address, role, the capability flags (`votes`, `campaigns`, `stores_log`,
`serves_reads`, `serves_writes`, `promotion_eligible`), plus `self` and
`leader` markers. Embedded `members` lists only the static member ids. On a
registry-backed server, `members` reports `voter_membership` as `decided`,
`status` adds the replacement `phase`, `quorum_available`, and
`installation_state`, and `zaxon membership status` shows the decided
registry itself. The replacement runbook below reads all three.

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

== Replacing a data voter

A failed voter's disk does not always come back. The decided replacement
retires one data voter and admits one new one, one operation at a time,
without rebuilding the database or changing its identity. Its scope is
deliberately narrow: it is operator-initiated, never automatic; it changes
exactly one voter per operation and never the voter count; it requires at
least three voters, so a majority of the old configuration survives the
change; and it exists only on registry-backed servers. Embedded and
flag-fixed clusters keep fixed membership.

The registry is the authority. A registry-backed cluster records its
membership in a decided registry (chapter 16), replicated and chosen
through the same Paxos log as every write. Peer flags bootstrap a new data
directory. Once a decided registry exists, stale peer flags are ignored.

=== Authorization

Replacement is a privileged operation. It requires a mutual TLS client
certificate whose common name is `zaxon-admin-<name>`, with the name in
`[a-z0-9-]` and at most 32 bytes, and that name must appear in the server's
allow-list: `--admin <name>`, repeated per administrator, or the `admins`
configuration field. A node certificate is refused, so a compromised member
cannot reshape the cluster. PSK and anonymous connections are refused, and
the dev-PSK mode structurally cannot reach the operation at all. Issue the
admin certificate from the cluster CA like any client certificate, with the
admin common name.

=== The runbook

Suppose voter 3 is dead and node 7 at `10.0.0.7:9901` replaces it. The new
ID must be new: the registry's allocation fence permanently retires every
ID it has ever seen, so a replacement never reuses an old one.

+ Verify preconditions: at least three voters in the decided registry, and
  a leader plus a write quorum of the old configuration reachable. Check
  `quorum_available` in `zaxon membership status`. That field is an
  observation of recent authenticated peer contact, including self,
  against the majority read and write quorums; it is a health signal, not
  an authorization.
+ Choose an operation ID you have never used, and run, with the admin
  certificate:

  ```console
  $ zaxon replace-voter --connect 10.0.0.1:9901 --operation 42 \
      --expected-config 5 --old-node 3 --new-node 7@10.0.0.7:9901 \
      --tls-cert admin.crt --tls-key admin.key --tls-ca ca.crt
  ```

  The command follows the leader on its own. `--expected-config` pins the
  configuration you inspected; if the cluster has moved on, the request is
  refused rather than reinterpreted. Retrying with the same operation ID
  is idempotent: the registry's operation ring replays the recorded
  outcome. Reusing a retained ID for a different request is a conflict and
  is refused.
+ After the operation reports its stop sign chosen, issue the enrollment
  token: `zaxon enroll-token --node 7 ...` as in the enrollment section.
  Issuance requires node 7 to be in the decided registry, which is exactly
  what the chosen stop sign established.
+ On the new host, redeem the token and record the join descriptor:

  ```console
  $ zaxon enroll --token-file node7.token \
      --identity-dir /etc/zaxon/node7 --data /var/lib/app/n7
  ```

  Besides the certificate install, `--data` writes the one-shot `JOIN`
  descriptor binding the database ID, the configuration, and the registry
  digest the new node must see.
+ Start `zaxon serve` on the new host with the decided peers. During its
  snapshot install the node fetches the registry blob
  from a member, verifies it against the bound digest, and installs it
  durably. It votes only after that installation is durable.
+ Watch `zaxon membership status` until the phase reaches `complete`.
  Update the survivor configuration files for operator clarity. Recovery
  does not depend on that update because the durable registry is authoritative.

=== What to expect during the change

The operation moves through observable phases: `prepared` and `proposed`
while the coordinator persists and proposes the stop sign, `chosen` once
Paxos has decided it, a brief `activating` during the in-process swap,
`active-degraded` while the new configuration is active but the
replacement is not yet an active voter, and `complete` when it votes. A
replaced voter reports `retired`. `installation_state` tracks the new
node's snapshot transfer: `not-started`, `transferring`, `verifying`,
`installed`, `active`, or `failed`; `not-applicable` elsewhere.

Plan for five effects. First, one checkpoint transfer to the new voter: the
replacement is admitted across a sealed epoch, so it installs a snapshot
before it votes. Second, a bounded write pause at the epoch boundary while
the stop sign seals and the next configuration activates. Third, client
read TCP connections stay open across the in-process swap; clients do not
reconnect. Fourth, reduced fault tolerance until the phase reaches
`complete`: between the old voter's retirement and the new voter's first
durable vote, the cluster tolerates fewer failures than its size suggests,
so do not stack a rolling upgrade on top of a replacement. Fifth, the
database identity is stable: identity is derived once at bootstrap, and no
replacement changes it.

=== After the change

Update the survivors' flags promptly so their files describe the running
cluster. A survivor restarted before that edit still opens the decided
registry and converges to the new membership. Stale bootstrap flags cannot
resurrect removed membership or block crash recovery.

The old node ID is retired forever by the allocation fence. If the removed
voter comes back from the dead, it stays sealed on its final configuration
and is rejected by admission, even with a valid certificate. It can be
decommissioned at leisure.

#callout(title: [One at a time], tone: "warning")[
  The registry serializes replacements: one pending operation per cluster,
  decided before the next may start. Do not script parallel replacements,
  and do not treat `active-degraded` as done. The operation is finished
  when the phase is `complete` and `quorum_available` is true with the new
  voter counted.
]

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
  Wire compatibility is exact-major: protocol version 8 speaks only to
  version 8. A release that changes the wire version cannot use this rolling
  procedure. It requires an explicitly dual-version bridge release, and
  there is no automatic downgrade. Downgrading is supported only when the
  older binary declares every installed durable format and wire version
  compatible.
]

#exercise([14.1], [
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
