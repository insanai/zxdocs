#import "theme.typ": *
#import "figures.typ": *

= Desk reference

These are the tables to keep beside a terminal. Every row was verified
against `zaxonlite/src` (`main.zig`, `server.zig`, `client.zig`,
`tls.zig`, `types.zig`, `prepared.zig`, `command.zig`,
`durability.zig`, `registry.zig`, `checkpoint_proof.zig`), against
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
  [`--admin <name>`], [Authorize one `zaxon-admin-<name>` client
    certificate for privileged membership operations on `serve`. Repeat
    the flag once per administrator; the configuration field is `admins`.],
  [`--operation <u64>`], [The operator-chosen operation ID for
    `replace-voter`. Retrying with the same ID is idempotent.],
  [`--expected-config <id>`], [The configuration `replace-voter` expects
    to change. A stale value is refused, never reinterpreted.],
  [`--old-node <id>`], [The voter `replace-voter` retires.],
  [`--new-node <id>@<host>:<port>`], [The replacement voter's ID and
    endpoint for `replace-voter`.],
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
  [`exec`], [`sql`; optional `session` and `sequence`, always
    together; optional `format` (`typed-v1`) with tagged `params`],
    [`changes`, `slot`, `replayed`; typed responses echo `format` and
    add `last_insert_rowid` when set],
  [`query`], [`sql`; optional `level` (default `linearizable`),
    `freshness_ms` (level `any` only), and `format` (`typed-v1`) with
    tagged `params`], [`columns`, `rows`, `level`; typed responses
    carry tagged cells instead of strings],
  [`search`], [`fts_table` with `text`, `vec_table` with base64
    `embedding` (little-endian float32), or both; optional `k` (default
    10), `candidate_count` (default `min(max(8k, 64), 4096)`, hard cap
    4096), `fusion` (`rrf` default, or `dbsf`), `text_weight`,
    `vector_weight`; optional `metadata_table`, `metadata_id_column`
    (default `id`), and one to 16 `metadata_columns`; plus
    `level`/`freshness_ms` as for `query`],
    [`columns`, `rows`, `level`; rows carry item IDs, scores, and selected
    application metadata, never implicit embedding BLOBs],
  [`enable-search-feature`], [none], [`slot`,
    `search_feature_version`. Records the search-feature version in an
    image that predates it; run only after every member serves a
    compatible binary. New databases record it at bootstrap.],
  [`session`], [none], [`session_id`],
  [`wait`], [`applied`, `leader` (bool), `timeout_ms`], [`applied_slot`,
    `decided_slot`, `leader`, `configuration_id`],
  [`status`], [none], [The full status record: identity, role, `leader`,
    `ballot`, decided and applied slots, journal, chain, `snapshot`, and
    the search capability manifest (`fts5_enabled`,
    `sqlite_vec_version`, `search_feature_version`, `simd_backend`,
    `mmap_size`, `candidate_hard_limit`), `write_gate` (`fifo-v1`),
    and `typed_v1` (`true`). On registry-backed servers it
    adds the replacement `phase`, `quorum_available`, and
    `installation_state`.],
  [`members`], [none], [`voter_membership` (`decided` on registry-backed
    servers, `static` otherwise), `nodes` with role and capability
    booleans, `self`, `leader`],
  [`membership`], [none], [Read-only registry view: the decided
    configuration, `registry_digest`, `highest_allocated_node_id`, the
    nodes, the replacement `phase`, `quorum_available`, and
    `installation_state`. A flag-fixed node answers `no_registry`.],
  [`replace-voter`], [`operation`, `expected_config`, `old_node`,
    `new_node`, `endpoint`], [`operation`, `phase` (`proposed` or
    `complete`), the resulting configuration ID. Privileged: requires a
    listed `zaxon-admin-<name>` client certificate; node certificates
    and PSK connections are refused.],
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
  [`zaxonlite_exec_prepared_result`], [The same write with a
    structured result: `changes`, `replayed`, `last_insert_rowid`
    when observably set, and typed RETURNING rows complete before the
    acknowledgment.],
  [`zaxonlite_transaction_begin`, `_exec`, `_commit`, `_close`],
    [Collect copied statements, then replicate them atomically. Each
    transaction object is single-use.],
  [`zaxonlite_live_begin`, `_exec`, `_savepoint`,
    `_release_savepoint`, `_rollback_to_savepoint`, `_commit`,
    `_rollback`, `_active`], [Gate C live transaction on a
    single-member local handle: a real SQLite transaction with
    read-your-writes and ordinal savepoints, captured as one WAL
    transition at commit.],
  [`zaxonlite_session_open`], [Open a replicated exactly-once session.],
  [`zaxonlite_exec_idempotent`], [Execute one session sequence at most
    once. Sets `replayed` when it returns the saved result of the last
    sequence.],
  [`zaxonlite_query_json`], [Run a read-only query. Returns a JSON
    buffer of columns and rows.],
  [`zaxonlite_query_prepared_json`], [The same read with
    `zaxonlite_value` bindings.],
  [`zaxonlite_query_prepared_result`], [Run a read-only prepared query
    into an opaque typed result handle.],
  [`zaxonlite_result_column_count`, `_row_count`, `_column_name`,
    `_value`, `_close`], [Bounds-checked accessors over a typed
    result. `_value` lends TEXT and BLOB bytes until `_close`; close
    accepts NULL.],
  [`zaxonlite_search`], [Run a typed lexical, vector, or hybrid search
    through the validated native planner into a typed result.],
  [`zaxonlite_statement_describe`], [Prepare without executing and
    report `parameter_count`, `column_count`, `read_only`, and
    `has_tail`.],
  [`zaxonlite_statement_parameter_name`], [Copy one bound parameter's
    name (1-based; empty for a positional parameter).],
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
  [`zaxonlite_last_error_category`], [Return the ABI-stable category
    (0 to 10) of the handle's most recent error.],
  [`zaxonlite_cluster_open`, `_close`], [Own a transport-owning member
    built from a runtime registry (`zaxonlite_cluster_options`, at most
    36 members, nine of them voters).],
  [`zaxonlite_cluster_open_v2`], [The same facade from a
    `struct_size`-versioned options struct: PSK provider file,
    loopback-only development PSK, Unix-socket service.],
  [`zaxonlite_cluster_exec`, `_query_json`], [Cluster writes and reads
    through the facade.],
  [`zaxonlite_cluster_call_json`, `_last_error`], [Generic JSON RPC and
    error text through the facade.],
  [`zaxonlite_remote_open`, `_close`], [Own a pooled external client
    to an existing cluster: 1 to 64 slots, no data directory, no
    listener, database identity pinned per slot.],
  [`zaxonlite_remote_exec`, `_query`], [Exactly-once writes on one
    FIFO write lane with a replicated session; typed reads at level 0
    (`any`), 1 (`leader`), or 2 (`linearizable`).],
  [`zaxonlite_remote_resolve_pending`], [Drive a retained pending
    write to a definitive outcome after its deadline expired.],
  [`zaxonlite_remote_status_json`, `_last_error`,
    `_last_error_category`], [Raw status JSON, the most recent error
    message, and its stable category for a remote handle.],
)

== The Python SDK

Chapter 12 is the guide; these are the desk facts. The package lives
at `zaxonlite/languages/python`. From that directory, `uv sync` and
then `uv pip install -e .` build the extension against the static
library. The module globals are `apilevel` `"2.0"`, `threadsafety`
`2`, and `paramstyle` `"qmark"`. `zxlite.connect` takes a data
directory for a local embedded node, `unix:<path>` for a served local
socket, or a `zxlite://` DSN with comma-separated seeds for a remote
cluster.

#table(
  columns: (auto, 1fr),
  table.header([*Keyword*], [*Meaning*]),
  [`timeout`], [Bounds the write-queue admission wait, not a lock
    spin. Expiry raises `OperationalError` with category
    `write_queue_timeout`; the statement provably never executed, so
    an immediate retry is safe.],
  [`isolation_level`], [`None` (autocommit, the default), or
    `DEFERRED` for a Gate C live transaction. Local single-member
    connections only; remote connections are autocommit-only.],
  [`read_level`], [`any`, `leader`, or `linearizable` (the default).
    Never downgraded by retry or load balancing.],
  [`pool_size`], [Remote connection slots, 1 to 64; the default is
    `min(32, max(4, 2 * seeds))`. The pool scales reads only; writes
    travel one FIFO lane.],
)

Exceptions follow DB-API 2.0, mapped from the stable native
categories: constraint raises `IntegrityError`; busy, interrupt,
session, storage, and availability raise `OperationalError`; misuse
and validation raise `ProgrammingError`; every exception exposes the
token as `exception.category`.

== Search SQL functions

Every connection registers FTS5, the pinned sqlite-vec module, and four
Zig functions before preparing any statement, so the same SQL works on
leaders, followers, read replicas, restored snapshots, and backups. All
four are deterministic, allocation-free, and return `SQLITE_CONSTRAINT`
with a plain message on a contract violation. NULL input produces NULL.

#table(
  columns: (auto, 1fr),
  table.header([*Function*], [*Contract*]),
  [`rrf(rank[, k[, weight]])`], [Weighted reciprocal rank contribution
    `weight / (k + rank)`. `rank` is a positive one-based integer, `k`
    finite and positive (default 60), `weight` finite and nonnegative
    (default 1). Sum contributions per item and order descending.],
  [`dbsf(score, mean, stddev[, weight])`], [Distribution-based score
    contribution `weight * (0.5 + (score - mean) / (6 * stddev))`. A
    zero deviation yields the neutral `0.5 * weight`. Values are not
    clipped. Orient scores so higher is better first, for example
    `-bm25(...)` and `-distance`.],
  [`stddev_samp(x)`], [Sample standard deviation as an aggregate or
    window function (Welford state; sliding frames supported). NULL rows
    are ignored; an empty set is NULL and a singleton is zero, so `dbsf`
    applies its neutral rule.],
  [`zaxon_vec_distance_cosine(a, b)`], [Exact cosine distance over two
    float32 BLOBs of equal nonzero length divisible by four. Uses the
    compiled 128-bit SIMD kernel with a scalar tail; non-finite
    elements, zero magnitude, and malformed BLOBs are errors. Accepts
    vec0 `float` columns directly.],
  [`zaxon_search_debug()`], [Returns `simd=neon128`, `simd=sse128`,
    `simd=wasm128`, or `simd=scalar` for the compiled backend;
    `vec_debug()` reports the sqlite-vec build beside it.],
)

The vector candidate count in raw SQL (`... and k = :candidate_count`)
is a documented contract with a 4096 ceiling: zaxonlite cannot see a
bound parameter consumed inside the vec0 virtual table, so raw queries
are bounded by the server row, byte, and VM-step budgets instead. Note
that the VM-step budget under-counts work done inside virtual-table
scans; the row and byte limits and the statement deadline are the
operative bounds for vector queries. The typed `search` operation is the
enforced path: it validates `candidate_count` before any SQL exists.

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
  [`-- INVALID MMAP SIZE --`], [`--mmap-size` exceeds the 1 GiB runtime
    ceiling. Exits 2 before the database or listener opens.],
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
  [Voters required for a decided replacement], [at least 3],
    [`registry.zig`],
  [Node-ID allocation fence], [`u32`, monotonic, never wraps],
    [`registry.zig`],
  [Replacement operation ring], [32 newest decided operations],
    [`registry.zig`],
  [Registry endpoint text], [64 bytes, printable space-free ASCII],
    [`registry.zig`],
  [Registry blob on the wire], [8 KiB], [`wire.zig`],
  [Vector KNN candidate count], [4,096; enforced by the typed `search`
    operation, documented contract for raw SQL], [`search_api.zig`],
  [Mapped-I/O limit], [0 default on every target; opt-in up to 1 GiB],
    [`sqlite/core.zig`],
  [Search-maintenance payload], [16 MiB target, 32 MiB operational soft
    ceiling, `64 MiB - 73` hard limit], [`command.zig`, ZDS 0009],
  [Administrator name], [`[a-z0-9-]`, at most 32 bytes], [`tls.zig`],
  [Epoch capacity], [2,048 slots, 4 reserved for the stop sign],
    [`types.zig`, `node.zig`],
  [Protocol append batch], [16 entries], [`types.zig`],
  [Stop-sign metadata], [512 bytes], [`types.zig`],
  [Wire frame body], [64 MiB], [format contract],
  [Declared snapshot or backup transfer], [4 GiB default, server
    configurable], [`wire.zig`, `server.zig`],
  [Concurrent server connections], [4 × configured members + 16 default],
    [`server.zig`],
  [Handshake completion deadline], [10 000 ms default, 0 disables],
    [`server.zig`],
  [Mutual TLS protocol version], [TLS 1.3 minimum], [`tls.zig`],
  [Zaxon wire protocol version], [8, exact match], [`wire.zig`],
  [Checkpoint proof (`ZXP2`)], [768 bytes encoded],
    [`checkpoint_proof.zig`],
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
  [Writers per database], [1, serialized through the leader; FIFO
    admission], [format contract],
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
  [Database identity], [The shared 128-bit ID derived at bootstrap from
    the sorted voter IDs, plus the optional cluster ID. The `hello`
    handshake enforces it. It never changes afterward, including across
    a decided voter replacement.],
  [Decided registry], [The canonical `ZXRG` membership record for one
    configuration, stored under `registries/` and named by the
    `REGISTRY` pointer. On registry-backed servers it, not the startup
    flags, is the membership authority.],
  [Allocation fence], [`highest_allocated_node_id` in the registry: the
    monotonic bound under which no node ID may ever be issued again. It
    is what makes retirement permanent.],
  [Operation ring], [The 32 newest decided replacement outcomes kept in
    the registry. It makes an operator's retry by operation ID
    idempotent and rejects conflicting reuse.],
)

#teach_back([
  Close the book. Write down the four nonzero exit codes and one situation
  that produces each. Then reopen this chapter, find the first mismatch,
  and reread only the row that corrects you.
])
