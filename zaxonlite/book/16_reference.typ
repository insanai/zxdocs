#import "theme.typ": *
#import "figures.typ": *

= Desk reference

These are the tables to keep beside a terminal. Every row was verified
against `zaxonlite/src` (`main.zig`, `server.zig`, `client.zig`,
`tls.zig`, `types.zig`, `prepared.zig`, `command.zig`,
`durability.zig`), against
`include/zaxonlite.h`, and against the format contract.

== CLI commands and flags

Chapter 2 is the full command reference. It shows one worked example per
command, so we do not repeat the commands here. Two flags select the mode.
`--data <dir>` runs the command against a local node, in process.
`--connect <endpoint>[,...]` speaks the client RPC protocol to a running
cluster and follows `not_leader` redirects on its own. `--json` switches
any command to machine-readable output on stdout.

An endpoint is `host:port`, or `unix:<path>` for a local server's
Unix-domain socket. The remaining flags are a short list. Each belongs
to one or two commands.

#table(
  columns: (auto, 1fr),
  table.header([*Flag*], [*Meaning*]),
  [`--config <path>`], [JSON configuration file. `ZAXON_CONFIG` names the
    same file through the environment.],
  [`--sql <text>`], [The statement for `exec` and `query`.],
  [`--session <id>`], [Session identity for an idempotent `exec`. Use it
    together with `--sequence`.],
  [`--sequence <n>`], [Monotonic per-session sequence for `exec`.],
  [`--level <level>`], [Read level for `query`: `any`, `leader`, or
    `linearizable` (the default).],
  [`--freshness-ms <n>`], [Maximum age for a local learner read. Valid
    only with level `any`.],
  [`--to <path>`], [Backup destination for `backup`, or owner-only token-bundle
    destination for `enroll-token`. Existing destinations are refused.],
  [`--retain <n>`], [Activity window for `expire-sessions`: keep sessions
    inside the `n` most recent session-write activities. Required.],
  [`--applied <slot>`], [Slot that `wait` waits for. The default is 0.],
  [`--leader`], [Make `wait` also wait for a known leader.],
  [`--timeout-ms <n>`], [Deadline for `wait`. The default is 10000.],
  [`--node <id>`], [This server's node ID for `serve`, or the configured target
    node for `enroll-token`.],
  [`--listen <endpoint>`], [This server's endpoint: `host:port`, or
    `unix:<path>` for owner-only single-node local service. Required by
    `serve`.],
  [`--role <role>`], [`data-voter` (the default), `witness`, `standby`,
    `read-replica`, or `gateway`.],
  [`--peer <spec>`], [One peer as `id@host:port[/role]`. Repeat the flag
    once per peer (`serve`).],
  [`--cluster-id <text>`], [Extra entropy for the derived database
    identity.],
  [`--auth-file <path>`], [Transport secret provider, or `ZAXON_AUTH_FILE`.
    Never a literal key on the command line.],
  [`--dev-psk`], [Allow PSK-only TCP for a local development cluster. Requires
    an owner-only `--auth-file`; listener and peers must use numeric loopback.],
  [`--tls-cert <path>`], [Node certificate PEM for mutual TLS (`serve`
    and client mode). All three TLS flags go together.],
  [`--tls-key <path>`], [Node private key PEM for mutual TLS.],
  [`--tls-ca <path>`], [Cluster CA PEM that every peer certificate must
    chain to.],
  [`--enrollment-ca-key <path>`], [Owner-only CA private key enabling the
    narrow token/CSR issuer on `serve`; omit it on ordinary nodes.],
  [`--token-file <path>`], [Owner-only opaque bearer bundle consumed by
    `enroll`.],
  [`--identity-dir <path>`], [New directory atomically receiving `node.key`,
    `node.crt`, and `ca.crt` from `enroll`.],
  [`--ttl-seconds <n>`], [Enrollment lifetime: 600 by default, at most 86400.],
  [`--revocation-file <path>`], [Reloaded node-ID denylist for `serve`.],
  [`--sync <mode>`], [Durability sync mode, any command: `full` (the
    default; `F_FULLFSYNC` on macOS, survives power loss) or `os`
    (plain `fsync`, development only on macOS). Any other value is a
    usage error, exit 2: `--sync must be os or full`.],
  [`--enable-failpoints`], [Honor failpoint RPCs. Test controllers only.],
  [`--json`], [Machine-readable output on stdout.],
)

Configuration precedence is fixed: explicit flags win, then environment
variables, then the `--config`/`ZAXON_CONFIG` JSON file. The environment
names are `ZAXON_DATA`, `ZAXON_CONNECT`, `ZAXON_LISTEN`, `ZAXON_NODE`,
`ZAXON_ROLE`, `ZAXON_PEERS`, `ZAXON_CLUSTER_ID`, `ZAXON_AUTH_FILE`,
`ZAXON_TLS_CERT`, `ZAXON_TLS_KEY`, `ZAXON_TLS_CA`, and `ZAXON_SYNC`.
Server provider paths also have `ZAXON_ENROLLMENT_CA_KEY` and
`ZAXON_REVOCATION_FILE`.

== Exit codes

#table(
  columns: (auto, 1fr),
  table.header([*Code*], [*Meaning*]),
  [0], [Success.],
  [1], [SQL or session error, including `SequenceGap`, `UnknownSession`,
    and `ResultExpired`.],
  [2], [Usage: an unknown command or option, a missing flag, an unreadable
    configuration or secret provider, or an invalid registry.],
  [3], [Integrity failure reported by `integrity-check` or `recover`.],
  [4], [Unavailable: a locked directory, corrupt state, a failed open or
    listen, no reachable leader, or a malformed peer response.],
)

== Client RPC operations

One JSON object travels per `rpc_request` frame and one per
`rpc_response`. Every success body carries `"ok":true`. New fields are
only ever added, so additive change stays compatible.

#table(
  columns: (auto, 1fr, 1.2fr),
  table.header([*Op*], [*Request fields*], [*Success response fields*]),
  [`exec`], [`sql`; optional `session` and `sequence`, always together],
    [`changes`, `slot`, `replayed`],
  [`query`], [`sql`; optional `level` (default `linearizable`) and
    `freshness_ms` (level `any` only)], [`columns`, `rows`, `level`],
  [`session`], [none], [`session_id`],
  [`wait`], [`applied`, `leader` (bool), `timeout_ms`], [`applied_slot`,
    `decided_slot`, `leader`, `configuration_id`],
  [`status`], [none], [The full status record: identity, role, `leader`,
    `ballot`, decided and applied slots, journal, chain, `snapshot`.],
  [`members`], [none], [`voter_membership`, `nodes` with role and
    capability booleans, `self`, `leader`],
  [`leader`], [none], [A `leader` object (`id`, `host`, `port`), or
    `null`.],
  [`snapshot`], [none], [`configuration_id`. Leader only.],
  [`integrity`], [none], [`ok` mirrors the report; `sqlite_ok`,
    `chain_ok`, `payloads_ok`],
  [`hash`], [none], [`chain`, `content`, `applied_slot`],
  [`expire-sessions`], [`retain`], [`expired`],
  [`issue-enrollment-token`], [`node_id`; optional `ttl_seconds`],
    [`node_id`, `issuer_node_id`, `database_id`, `expires_unix_seconds`,
    `token`. Issuer-only; the caller already passed normal mTLS.],
  [`backup`], [none], [Not JSON: a `backup_begin` frame (size and
    SHA-256), ordered `backup_chunk` frames, `backup_end`. A JSON error
    means the request was rejected.],
  [`failpoint`], [`name`; the server must run with
    `--enable-failpoints`], [`ok`],
  [`stop`], [none], [`ok`, then the server shuts down.],
)

An error response is `{"ok":false,"error":code,"message":text}`. The
`not_leader` code adds the advertised `leader` endpoint so a client can
redirect.

#table(
  columns: (auto, 1fr, auto),
  table.header([*Error code*], [*Meaning*], [*CLI exit*]),
  [`bad_request`], [Malformed JSON, an unknown op, or a missing or
    invalid field.], [2],
  [`sql`], [The statement failed, or a write reached the read path.], [1],
  [`session`], [`UnknownSession`, `SequenceGap`, or `ResultExpired`.], [1],
  [`not_leader`], [A leader-only request was refused. Follow the
    hint.], [4],
  [`stale`], [A learner read exceeds `freshness_ms` or the learner has no
    leader contact.], [4],
  [`forbidden`], [This node type does not serve SQLite reads. Witnesses
    answer this way.], [4],
  [`ambiguous`], [The write's fate is unknown after a leader change.
    Retry idempotently with the same session and sequence.], [4],
  [`retry`], [Transient: an epoch rollover or a leadership change during
    a fence.], [4],
  [`timeout`], [An operation, fence, or wait deadline passed.], [4],
  [`too_large`], [The transaction payload exceeds the 64 MiB wire
    limit.], [4],
  [`unavailable`], [The node failed or durable storage stopped.], [4],
  [`internal`], [An unexpected error. The name travels in
    `message`.], [4],
)

== C ABI

Every `int` function returns the same codes: 0 ok, 1 SQL or session
error, 2 misuse (a null argument, or a write on the read path), 3
integrity failure, 4 unavailable. `zaxonlite_last_error` holds the most
recent message per handle. JSON buffers are released with
`zaxonlite_free`. Declared counts and lengths are validated against
product limits before use (registry ≤ 36 members, secret ≤ 4096 bytes,
value ≤ 64 MiB), and every out-parameter is set to a safe empty value
on every path; chapter 11 states the full boundary contract.

#table(
  columns: (auto, 1fr),
  table.header([*Function*], [*Purpose*]),
  [`zaxonlite_version`], [Return the library version string.],
  [`zaxonlite_open`, `_close`], [Own one node data directory. A second
    open of a locked directory returns 4.],
  [`zaxonlite_exec`], [Run one replicated write transaction and report
    its change count.],
  [`zaxonlite_exec_prepared`], [Run one prepared statement with
    `zaxonlite_value` bindings. TEXT and BLOB values are borrowed for the
    duration of the call.],
  [`zaxonlite_transaction_begin`, `_exec`, `_commit`, `_close`],
    [Collect copied statements, then replicate them atomically. Each
    transaction object is single-use.],
  [`zaxonlite_session_open`], [Open a replicated exactly-once session.],
  [`zaxonlite_exec_idempotent`], [Execute one session sequence at most
    once. Sets `replayed` when it returns the saved result of the last
    sequence.],
  [`zaxonlite_query_json`], [Run a read-only query. Returns a JSON
    buffer of columns and rows.],
  [`zaxonlite_query_prepared_json`], [The same read with
    `zaxonlite_value` bindings.],
  [`zaxonlite_free`], [Release a returned JSON buffer.],
  [`zaxonlite_snapshot`], [Seal the epoch and install a snapshot
    generation.],
  [`zaxonlite_backup`], [Write a consistent logical backup to a path.],
  [`zaxonlite_integrity_check`], [Verify the image, the descriptor chain,
    and every referenced payload.],
  [`zaxonlite_expire_sessions`], [Delete idle sessions outside the
    retained activity window.],
  [`zaxonlite_last_error`], [Return the most recent error message for the
    handle.],
  [`zaxonlite_cluster_open`, `_close`], [Own a transport-owning member
    built from a runtime registry (`zaxonlite_cluster_options`, at most
    36 members, nine of them voters).],
  [`zaxonlite_cluster_exec`, `_query_json`], [Cluster writes and reads
    through the facade.],
  [`zaxonlite_cluster_call_json`, `_last_error`], [Generic JSON RPC and
    error text through the facade.],
)

== Diagnostic catalogue

Every operator-facing failure reaches stderr in one fixed shape, produced
by `zaxonlite/src/diagnostic.zig`: an uppercase boundary header, a plain
description, and a resolution hint.

```text
-- NODE DIRECTORY LOCKED --

Another process owns this data directory.

Hint: Stop that process or choose a different --data directory.
```

Client mode renders a server error code in the same shape, with the code
as the header (for example `-- NOT_LEADER --`) and a code-specific hint.
These are the diagnostics you will meet, with the exit code each one
produces.

#table(
  columns: (auto, 1fr),
  table.header([*Header*], [*Emitted when*]),
  [`-- UNKNOWN OPTION --`], [An argument is not a recognized flag.
    Exits 2.],
  [`-- INVALID COMMAND --`], [A required flag or value is missing or
    malformed. Exits 2.],
  [`-- UNKNOWN COMMAND --`], [The command word is not one `zaxon` knows.
    Exits 2.],
  [`-- UNSUPPORTED CLIENT COMMAND --`], [An embedded-only command was
    given `--connect`. Exits 2.],
  [`-- CONFIGURATION UNREADABLE --`], [`--config` or `ZAXON_CONFIG`
    names a file that cannot be read or parsed as JSON. Exits 2.],
  [`-- AUTHENTICATION PROVIDER UNREADABLE --`], [The `--auth-file`
    provider is missing, unreadable, or shorter than 32 bytes. Exits 2.],
  [`-- INVALID CLUSTER CONFIGURATION --`], [`serve` was given a bad
    registry or role set. Exits 2.],
  [`-- INVALID GATEWAY CONFIGURATION --`], [The gateway's registry or
    role set is invalid. Exits 2.],
  [`-- INVALID LISTEN ADDRESS --`], [The listen endpoint cannot be
    parsed. Exits 2.],
  [`-- SQL ERROR --`], [A write statement failed. Exits 1.],
  [`-- QUERY ERROR --`], [A read failed, or a write reached the read
    path. Exits 1.],
  [`-- SESSION ERROR --`], [Session misuse: `UnknownSession`,
    `SequenceGap`, or `ResultExpired`. Exits 1.],
  [`-- BACKUP FAILED --`], [The backup destination is unusable. Exits 1.],
  [`-- NODE DIRECTORY LOCKED --`], [Another process owns the data
    directory. Exits 4.],
  [`-- NODE OPEN FAILED --`], [Identity, journal, payload, or filesystem
    verification failed on open. Exits 4.],
  [`-- MUTUAL TLS REQUIRED --`], [A TCP storage listener was configured without
    a complete TLS identity and without explicit loopback-only `--dev-psk`.
    Exits 4.],
  [`-- TLS IDENTITY FAILED --`], [The TLS certificate, key, or CA cannot
    be loaded, or the key does not match the certificate. Exits 4 from
    `serve`, 2 from client mode.],
  [`-- LISTEN FAILED --`], [The server endpoint cannot be bound.
    Exits 4.],
  [`-- UNIX SOCKET LISTEN FAILED --`], [The Unix-socket path already
    exists, cannot be bound, or its permissions cannot be restricted.
    Exits 4.],
  [`-- GATEWAY LISTEN FAILED --`], [The gateway endpoint cannot be bound.
    Exits 4.],
  [`-- NO REACHABLE LEADER --`], [No endpoint completed a leader-only
    request. Exits 4.],
  [`-- LEADER REDIRECT REFUSED --`], [A leader was advertised, but the
    transport cannot authenticate the redirect target (PSK or plaintext)
    and the address is not in `--connect`. Exits 4.],
  [`-- MALFORMED RESPONSE --`], [A peer answered outside the JSON
    contract. Exits 4.],
  [`-- BACKUP INTERRUPTED --`], [The streaming backup lost its server.
    The destination was not installed. Exits 4.],
  [`-- REMOTE BACKUP FAILED --`], [The server rejected or aborted the
    backup. The destination was not installed. Exits 4.],
  [`-- COMMAND FAILED --`], [Any unclassified error. Preserve the error
    and the node logs. Exits 4.],
  [`-- UNKNOWN SHELL COMMAND --`], [A shell dot command is unknown. The
    shell continues.],
  [`-- INPUT LINE TOO LONG --`], [A shell input line exceeds 64 KiB. The
    shell continues.],
)

== Limits

#table(
  columns: (1fr, auto, auto),
  table.header([*Limit*], [*Value*], [*Source*]),
  [Voters per consensus group, witnesses included], [1--9],
    [`types.zig`],
  [Epoch capacity], [2,048 slots, 4 reserved for the stop sign],
    [`types.zig`, `node.zig`],
  [Protocol append batch], [16 entries], [`types.zig`],
  [Stop-sign metadata], [256 bytes], [`types.zig`],
  [Wire frame body], [64 MiB], [format contract],
  [Declared snapshot or backup transfer], [4 GiB default, server
    configurable], [`wire.zig`, `server.zig`],
  [Concurrent server connections], [4 × configured members + 16 default],
    [`server.zig`],
  [Handshake completion deadline], [10 000 ms default, 0 disables],
    [`server.zig`],
  [Mutual TLS protocol version], [TLS 1.3 minimum], [`tls.zig`],
  [Zaxon wire protocol version], [6, exact match], [`wire.zig`],
  [Enrollment token lifetime], [600 s default; 86400 s maximum],
    [`enrollment.zig`],
  [Peer certificate common name], [`zaxon-node-<id>`, under 64 bytes],
    [`tls.zig`],
  [C ABI cluster registry], [36 members, at most 9 voters],
    [`embedded.zig`],
  [One transaction payload], [64 MiB minus 73 bytes], [`command.zig`],
  [Explicit transaction], [1024 statements, 64 MiB copied input],
    [`prepared.zig`],
  [Idempotent sessions], [one outstanding sequence, last result only],
    [format contract],
  [Writers per database], [1, serialized through the leader],
    [format contract],
  [Learners and gateways], [runtime-sized registry], [format contract],
  [Shell input line], [64 KiB], [`main.zig`],
)

== Glossary

#table(
  columns: (auto, 1fr),
  table.header([*Term*], [*Meaning*]),
  [Batch], [The unit one slot decides: the WAL frames SQLite committed
    for one write request, named by a random 128-bit batch ID.],
  [Descriptor], [The fixed 153-byte replicated command that names a
    payload by content hash. Paxos never carries transaction bytes.],
  [Payload], [The immutable `ZXPL` object holding one batch's transaction
    records, frame metadata, and page images.],
  [Chain hash], [The cumulative SHA-256 identity of the decided history.
    Equal chains mean identical applied history. It is not a file hash.],
  [Journal], [The per-epoch fsynced record of protocol writes. It is the
    authoritative state from which everything else rebuilds.],
  [Materialized image], [`current.db`, a rebuildable projection of the
    decided history. It is never accepted as evidence over Paxos state.],
  [Epoch], [One bounded configuration of the replicated log: at most 2,048
    slots under one configuration ID, sealed by a stop sign.],
  [Generation], [One installed snapshot, manifest plus database image.
    The newest fully installed one is named by `CURRENT`.],
  [`CURRENT` pointer], [The atomically replaced file naming the single
    installed snapshot generation that recovery may start from.],
  [Data voter], [A voter that may campaign, materializes SQLite, and
    serves SQL.],
  [Witness], [A voter that stores durable payloads but never campaigns
    and serves no SQL.],
  [Campaigner], [A node whose role permits starting elections. In this
    release that means exactly the data voters.],
  [Standby, read replica], [Non-voting learners that keep SQLite copies.
    An operator may promote a standby. A read replica is never
    promoted.],
  [Gateway], [A stateless byte-transparent router. It holds no Paxos
    state, no SQLite state, and no identity file.],
  [Learner commit], [A configured voter's certificate that a slot's entry
    was chosen. It is sent to a learner only after the learner's durable
    payload ACK.],
  [Payload gate], [The transport rule that holds a value-bearing envelope
    until its payload bytes are stored and digest-verified locally.],
  [Fence], [The quorum read barrier. The leader confirms its exact ballot
    with a read quorum before a linearizable read. No append, no sync.],
  [Session, sequence], [A replicated exactly-once identity and its
    monotonic counter. Only the next sequence executes. The last one
    replays its saved result.],
  [Database identity], [The shared 128-bit ID derived from the sorted
    voter IDs, plus the optional cluster ID. The `hello` handshake
    enforces it.],
)

#teach_back([
  Close the book. Write down the four nonzero exit codes and one situation
  that produces each. Then reopen this chapter, find the first mismatch,
  and reread only the row that corrects you.
])
