#import "theme.typ": *

= Conformance: guarantee to evidence

#objectives([
  By the end of this chapter you should be able to trace any
  user-visible guarantee to the function that enforces it, the
  automated oracle that checks it, and the normative clause that
  states it, to name the guarantees that still lack an oracle, and to
  apply the one-change rule when a guarantee moves.
])

Every guarantee in this book stands on three legs. A normative clause
states it. A piece of code enforces it. An automated oracle checks it.
Remove any leg and the guarantee wobbles: a clause without code is a
wish, code without a clause is an accident, and both without an oracle
are a claim. This chapter is the Zaxonlite analogue of the core
library's Lamport conformance table. Each row names one guarantee and
its three legs. Line numbers drift, so the rows anchor on function
names, test names, and scenario steps instead.

Chapter 18 described the suites as layers. Here each row names the
specific evidence inside them. Unit tests pin codecs and single-file
invariants. `integration_test.zig` drives one real node through
restart and recovery. `cluster_test.zig` drives three real
`zaxon serve` processes over the public RPC surface with no back
door. The role, fault, and gateway suites cover the remaining
topologies, `replacement_cluster_test.zig` drives the decided voter
replacement end to end, and `fuzz.zig` attacks decoders, journal files, and
whole-node schedules. In the clause column, "Format §_n_" names a
numbered section of `docs/zds/records/0004-zaxonlite-format.typ`, and "plan" names a
section of `docs/zds/records/0002-zaxonlite-product-plan.typ`. "ZDS 0008"
names `docs/zds/records/0008-zaxonlite-voter-replacement.typ`, which
carries the replacement's clauses in its own record; nothing in the
format record is renumbered. "ZDS 0010" names
`docs/zds/records/0010-zaxonlite-python-sdk.typ`, which carries the
typed boundary, write-queueing, live-transaction, and remote-client
clauses. Where no automated
oracle exists, the row says so directly. An unchecked guarantee is a
claim, not evidence, and we would rather you know which rows are
which.

== Durability and the write path

#table(
  columns: (1fr, 1.55fr),
  table.header([*Guarantee*], [*Evidence*]),
  [An acknowledged write is durable and decided. Only a phase-two accept
    request may precede the sender's local barrier; it carries no claim that
    the sender's own vote is durable.],
  [*Enforced.* In `protocol.zig`, `preDurableMessages` exposes only accept
    requests. In `node.zig`, every promise and vote record is appended before
    the required `journal.sync`; the host mutex prevents an early reply from
    re-entering the leader until its own vote is durable. Promise evidence,
    accepted replies, commits, and client replies remain behind
    `confirmWritesDurable`. In `server.zig`, `runWrite` replies only after the slot
    is chosen and applied. Every sync routes through `durability.zig`,
    whose default `full` mode issues `F_FULLFSYNC` on macOS so the
    flush reaches stable media, not just the drive's volatile cache;
    the development-only `os` mode keeps plain `fsync` there.

    *Checked.* The protocol test pins the narrow pre-barrier message class. The
    `crash_test.zig` cases `after_accept_sync` and the legacy-named
    `after_commit_sync_before_apply` (now chosen-before-apply) require a
    recovered count of exactly 1. The cluster scenario's final step asserts every
    acknowledged write is present exactly once, 153 rows after total
    restart. The crash campaigns simulate process death, under which
    the two sync modes are identical; the power-loss durability of
    `full` rests on the platform's `F_FULLFSYNC` contract and has no
    automated oracle.

    *Clause.* Format §5; plan "Ordering rules", steps 2 to 4;
    chapter 6's sync policy.],

  [Payload bytes are verified and durable before any value-bearing
    Promise, Accept, or Commit enters the Paxos transition. Normal
    Phase 2 avoids an extra storage-ACK round trip without weakening
    that receiver-side invariant.],
  [*Enforced.* `server.zig` `drainOutbox` queues `payload_data`
    immediately before the dependent envelope on the same ordered
    stream. `onPayloadData` verifies and durably stores the object
    before the reader can consume the following envelope. A separately
    arriving or fault-reordered envelope is parked by `holdEnvelope`
    and released only after storage; this fallback also covers Phase-1
    recovery. `payload_stored` caches readiness for subsequent sends,
    and `wire.zig` `envelopePayloadHash` covers promise, accept, and
    commit alike.

    *Checked.* The `wire.zig` test "envelope payload hash
    extraction"; `fault_cluster_test.zig` under loss, duplication,
    reordering, fragmentation, and delayed durable sync, ending in
    equal counts; the `payload_store.zig` test "payload store detects
    corruption and missing objects".

    *Clause.* Format §3, the receiver-side payload-storage
    invariant.],

  [A session sequence executes exactly once. An ambiguous retry
    returns the recorded result and never re-executes.],
  [*Enforced.* `node.zig` `checkSession` and `execIdempotent` replay
    the last sequence and answer `ResultExpired`, `SequenceGap`, and
    `UnknownSession` without executing SQL. The session row rides
    inside the captured transaction.

    *Checked.* `integration_test.zig` "idempotent sessions execute a
    sequence exactly once"; the cluster failpoint arc, where the
    leader dies after quorum choice and the retry at the new leader
    must apply exactly once.

    *Clause.* Plan "User-visible guarantees", the timed-out write;
    format §7.],

  [Session storage stays bounded by activity, not by history.],
  [*Enforced.* `node.zig` `expireSessions`, using the replicated
    `write_seq` retention window.

    *Checked.* `integration_test.zig` "idle sessions expire after the
    retention window".

    *Clause.* Plan "Bounded client sessions and retry semantics".],

  [Concurrent writers are admitted strictly first-in-first-out, and a
    write that times out while still queued is provably unexecuted
    and reported as such.],
  [*Enforced.* `server.zig` `runWrite` parks contending writers on
    the intrusive `WriterTicket` queue; `releaseWriterGate` grants
    the oldest ticket, so a sustained stream of writers cannot starve
    one caller past its deadline. A deadline that expires before
    admission raises `OpTimeoutQueued`, answered as
    `{"error":"timeout","queued":true}` — distinct from the
    fate-unknown bare `timeout` and `ambiguous` — and `remote.zig`
    treats exactly that response as safe to resend.

    *Checked.* The Python contention suite
    (`tests/dbapi/test_threads.py`) drives 32 concurrent writers with
    every write applied exactly once and asserts the typed
    `write_queue_timeout` category with a safe retry; the C ABI
    smoke test and the cluster suites drive concurrent writes over
    the public surfaces. No oracle observes the admission order
    itself yet.

    *Clause.* ZDS 0010, "Write queueing without database locks".],

  [Gate C live transactions are local and single-member only, and an
    open live transaction holds the node handle exclusively.],
  [*Enforced.* `node.zig` `beginLive` returns
    `error.ClusterTransactionUnsupported` on a multi-member node, and
    while a live transaction is open the one-shot write, snapshot,
    and membership paths refuse with `error.TransactionOpen`. Commit
    captures exactly one WAL transition and acknowledges only after
    the decided slot is applied; rollback publishes nothing.

    *Checked.* `integration_test.zig` "live transaction:
    read-your-writes, returning, savepoints, durability" and "live
    transaction: rollback publishes nothing"; the C ABI smoke test's
    live-transaction section, savepoints included.

    *Clause.* ZDS 0010, Gate C local live transactions.],
)

== Reads

#table(
  columns: (1fr, 1.55fr),
  table.header([*Guarantee*], [*Evidence*]),
  [The default read is linearizable. It includes every write
    acknowledged before it began, across leader changes.],
  [*Enforced.* `server.zig` `opQuery` defaults the level to
    `linearizable`. `awaitReadFence` confirms the exact ballot with a
    distinct-member read quorum before querying applied state:
    `onFenceRequest` answers from the durable promise and
    `onFenceAck` counts members.

    *Checked.* `cluster_test.zig` `linearizableCount` after every
    phase, at 100, 150, and 153 rows. Fence failure paths return
    `timeout` or `retry`, never stale data. No differential run
    against the committed barrier exists; see the gaps below.

    *Clause.* Format §7, the fresh exact-ballot quorum fence; plan
    "Linearizable read arguments".],

  [Stale reads are opt-in and bounded. `freshness_ms` is legal only
    at level `any`, and a learner past its bound refuses.],
  [*Enforced.* `server.zig` `opQuery` rejects `freshness_ms` outside
    level `any`. On learners it refuses when leader contact exceeds
    the bound, or when `applied_slot` lags
    `observed_leader_decided`, which `onLearnerHeartbeat` feeds.

    *Checked.* `role_cluster_test.zig` `expectReplica`, where a
    2000 ms bound answers, and `expectStale`, where a 100 ms bound
    returns `"error":"stale"` after the voters stop.

    *Clause.* Format §7, explicit stale consistency; format §3,
    `learner_heartbeat`.],

  [A witness serves no SQLite reads.],
  [*Enforced.* `node.zig` `query` returns `error.RoleCannotRead` when
    the role's `capabilities().serves_reads` is false, per
    `roles.zig`. The server maps it to `forbidden`.

    *Checked.* `role_cluster_test.zig` `expectCannotRead` expects
    `"error":"forbidden"` from the witness endpoint.

    *Clause.* Plan "Node roles and scaling law".],
)

== Crash recovery and storage

#table(
  columns: (1fr, 1.55fr),
  table.header([*Guarantee*], [*Evidence*]),
  [Recovery is snapshot plus committed-suffix replay. The
    materialized image is never accepted as newer evidence than
    Paxos state.],
  [*Enforced.* `node.zig` `rebuildMaterializedImage` deletes
    `current.db`, the WAL, and the SHM, copies the verified snapshot
    generation, then replays the contiguous committed suffix with
    chain validation. The image is never an input to recovery.

    *Checked.* `integration_test.zig` "journal is authoritative:
    materialized image rebuilds from scratch", "a stale materialized
    image converges to the journal state", "recovery discards a
    corrupt materialized image even with an empty suffix", and
    "snapshot seals the epoch and recovery uses snapshot plus
    suffix"; the cluster step "delete a follower image; node rebuilds
    from snapshot plus suffix".

    *Clause.* Format §6; plan "Restart sequence".],

  [Only a torn final record is truncated. Interior journal corruption
    is fatal, and the node refuses to vote.],
  [*Enforced.* `journal.zig` `replay` and `parseRecord`: a record
    that fails validation is recoverable only when
    `recordTouchesEof`. Any interior magic, version, sequence, or CRC
    failure is `CorruptJournal`.

    *Checked.* The `journal.zig` tests "journal truncates a torn tail
    but keeps the durable prefix" and "journal rejects interior
    corruption"; `integration_test.zig` "torn journal tail is
    truncated and the node reopens"; `fuzz.zig` `fuzzJournal` with
    seeded file damage.

    *Clause.* Format §5, which truncates only an incomplete final
    record.],

  [No crash point yields a false success. Once the accept or commit
    prefix is synced, recovery completes the value.],
  [*Enforced.* `failpoint.zig` hooks each pipeline boundary, from
    `before_payload_sync` through `before_client_reply`, marking the
    contract the write path must honor.

    *Checked.* The `crash_test.zig` five-failpoint matrix with
    per-case recovered-count bounds; `fuzz.zig` `fuzzNode` with
    random SQL, crashes, and rebuild convergence. Not every chapter-6
    crash row is automated in both roles yet; see the gaps below.

    *Clause.* Plan "Successful-write durability theorem"; the
    chapter 6 crash matrix.],

  [A node never serves or votes with missing durable payload bytes.],
  [*Enforced.* `node.zig` `rebuildMaterializedImage` fails with
    `PayloadMissing` for a committed descriptor without bytes;
    `server.zig` `onLearnerCommit` verifies the store before
    `learnChosen`; `payload_store.zig` `verify` re-hashes on demand.

    *Checked.* The `payload_store.zig` corruption and missing-object
    tests; the `fuzz.zig` journal and store damage schedules.

    *Clause.* Plan "Restart sequence", step 4; format §5.],
)

== Identity, membership, and transport

#table(
  columns: (1fr, 1.55fr),
  table.header([*Guarantee*], [*Evidence*]),
  [A data directory is pinned to one node ID, database, and role.
    Reuse under another identity is refused.],
  [*Enforced.* `node.zig` `loadOrCreateIdentity` raises
    `NodeIdMismatch`, `NodeRoleMismatch`, and `DatabaseMismatch`;
    `server.zig` startup rejects zero and duplicate registry IDs.

    *Checked.* `integration_test.zig` "a data directory cannot
    silently change learner role". The duplicate-ID and zero-ID
    startup refusals have no automated test today.

    *Clause.* Format §6: a node ID cannot be reused, and a role
    mismatch is fatal.],

  [A learner accepts a chosen slot only from a configured voter.
    Enforcement is layered in the core and in the server.],
  [*Enforced.* The core `src/protocol.zig` `learnChosen` raises
    `NotLearner` and membership-checks the certifying sender. The
    server guard in `zaxonlite/src/server.zig` `onLearnerCommit`
    requires the sender's configured role to have
    `capabilities().votes`; heartbeats pass the same guard in
    `onLearnerHeartbeat`.

    *Checked.* `role_cluster_test.zig`
    `expectRogueStandbyCommitRejected`: a well-formed
    `learner_commit`, authenticated as the standby, is rejected by
    the read replica. Also the `wire.zig` test "learner commit round
    trips and rejects invalid certificates".

    *Clause.* Format §3: a configured voter certifies one chosen
    slot.],

  [No silent wire-version downgrade. Wrong protocol versions and replayed or
    tampered optional-PSK frames are refused. Production TCP uses mTLS; the
    explicit PSK-only development mode is numeric-loopback-only.],
  [*Enforced.* `wire.zig` `Hello.decode` accepts exactly version 8
    and raises `UnsupportedProtocolVersion` otherwise; `server.zig`
    refuses TCP storage listeners without TLS unless `--dev-psk` is paired
    with an owner-only secret and all addresses are numeric loopback;
    `transport_auth.zig` `Session.readFrame` enforces the exact next
    sequence with `ReplayDetected` and MAC equality with
    `AuthenticationFailed`.

    *Checked.* The `wire.zig` test "hello rejects a future protocol
    version"; the `transport_auth.zig` test "authenticated session
    rejects replay and tampering"; the cluster step "reject a client
    with the wrong transport secret".

    *Clause.* Format §1 to §3: no negotiation down, exact-major wire.
    The identity and application-owned authorization boundaries are documented
    in chapters 7, 12, and 13 and in the security remediation plan.],

  [Every production storage TCP connection is mutual
    TLS 1.3: both sides present certificates chaining to the cluster
    CA, and a peer connection's certificate common name must match the
    node id claimed in its hello, on the accept side and the dial side
    alike.],
  [*Enforced.* `tls.zig` `Context.initCommon` sets a TLS 1.3 minimum
    and verifies with `SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT`
    in both directions. `server.zig` `serveConnection` compares an
    accepted peer hello's node id against the certificate's
    `zaxon-node-<id>` common name, and the peer dial loop applies the
    same comparison to the dialed member. A client certificate must chain to
    the CA; the client additionally refuses a server certificate whose common
    name is not the canonical `zaxon-node-<positive-id>` form.

    *Checked.* The `cli_test.zig` mutual-TLS section generates a CA,
    node, client, and foreign-CA certificate with the `openssl` CLI,
    then proves RPC round trips over mTLS, refusal of a plaintext
    client, and refusal of a foreign-CA certificate that carries the
    right name. `tls.zig` unit tests pin the common-name format and
    credential refusal.

    *Clause.* Security remediation plan, SEC-001: per-node transport
    identity.],

  [A `not_leader` redirect cannot silently change node identity: PSK-only
    clients stay within their seeds, while mTLS redirects pin the advertised
    node ID to the target certificate.],
  [*Enforced.* `client.zig` `callClusterWithTransport` follows unmatched
    hints only with mTLS, copies and validates the numeric address, and requires
    the target to present `zaxon-node-<advertised-id>`. PSK-only clients fall
    back to round-robin over the caller's endpoint list.

    *Checked.* The CLI suite starts three mTLS voters and proves a leader-only
    write sent to one follower reaches a leader outside the seed list. Client
    unit coverage proves the same hint remains seed-only without mTLS. No
    automated oracle sends an adversarial hint
    today; see the gaps below.

    *Clause.* Security remediation plan, SEC-011: validated client
    redirects.],

  [One serialized writer per database. Concurrent endpoints never
    create multi-leader writes.],
  [*Enforced.* The `server.zig` `runWrite` FIFO writer gate
    (`writer_gate_busy` plus the `WriterTicket` queue) allows one
    replicated write at a time, and admission is strictly
    first-in-first-out: `releaseWriterGate` hands the gate to the
    oldest queued ticket, never to a newcomer, and status advertises
    `write_gate` `fifo-v1`. `node.zig` `WriteInFlight` and
    the exclusive directory lock, `tryLock(.exclusive)` raising
    `error.NodeLocked`, guard the node; non-leaders answer
    `not_leader`.

    *Checked.* `integration_test.zig` "a second process cannot open a
    locked node directory"; the cluster scenario submits writes
    through all three endpoints and counts every row exactly once;
    the C ABI smoke test and the cluster suites drive concurrent
    writes over the public surfaces.

    *Clause.* Format §7: one serialized writer per database.],

  [Voter and campaigner bounds hold: at most nine voters, at least
    one voter, at least one campaigning data voter, and learners
    never enter the voter set.],
  [*Enforced.* `server.zig` startup validation emits "too many Paxos
    voters (maximum is 9)", "at least one Paxos voter is required",
    and "at least one data voter must be able to campaign";
    `roles.zig` `capabilities` classifies roles; the core
    `Membership.init` rejects non-intersecting quorums.

    *Checked.* The `roles.zig` test "roles keep learners out of the
    Paxos voter set"; `role_cluster_test.zig` elects only among
    campaigners. The nine-voter and zero-campaigner refusals
    themselves have no automated test today.

    *Clause.* Format §7; plan "Node roles and scaling law".],

  [On a registry-backed server the decided registry, not the startup
    flags, is the membership authority. Stale flags cannot override it or
    block restart, and every crash window in the rollover
    write order recovers to a consistent registry.],
  [*Enforced.* `registry.zig` defines the canonical `ZXRG` encoding and
    its SHA-256 digest; the on-disk blob adds a digest trailer and fails
    closed on corruption. `node.zig` derives restart membership from
    the decided registry and ignores stale bootstrap peer flags.
    The rollover write order is fixed: snapshot proof, `CURRENT`,
    `REGISTRY`, identity.

    *Checked.* Registry unit tests pin the canonical encoding as stable
    across input order and reject corruption. Integration crash-window
    tests re-run bootstrap when the pointer write is missing, recover a
    `REGISTRY`/identity rollback, and fail closed on a corrupt pointer.
    The replacement scenario restarts a survivor with stale flags and
    proves restart equivalence by registry digest on every member.

    *Clause.* ZDS 0008.],

  [A voter replacement is decided, one for one, privileged, and
    idempotent. It never changes the voter count, requires at least
    three voters, and retrying an operation ID replays its recorded
    outcome while conflicting reuse is refused.],
  [*Enforced.* The replacement travels as a stop sign through the same
    Paxos log as every write; `registry.zig` enforces the three-voter
    floor and retains the 32 newest outcomes in the operation ring,
    replaying a matching digest and refusing a differing one.
    `server.zig` requires a listed `zaxon-admin-<name>` client
    certificate and refuses node certificates and PSK connections.

    *Checked.* Registry unit tests cover idempotent retry,
    `OperationHistoryExpired`, `OperationIdExhausted`, and the
    three-voter rule. The replacement scenario refuses a node
    certificate and an unlisted admin, retries the decided operation
    idempotently, and rejects conflicting reuse of a retained ID. The
    library's `sim/reconfiguration.zig` drives sixteen seeded
    changed-member schedules through drop, duplication, and reordering
    with a restart oracle.

    *Clause.* ZDS 0008.],

  [A replacement activates only on sealed-set confirmation, and a
    retired voter never returns. Quorum confirmation counts distinct
    voters of the sealed set only; the proposed next voter never counts
    toward its own admission. The allocation fence retires the old node
    ID forever, and the returning process stays sealed on its final
    configuration and is refused admission even with a valid
    certificate.],
  [*Enforced.* `checkpoint_proof.zig` binds the `ZXP2` proof to equal
    sealed and next voter counts and the next-registry digest;
    confirmation counting in `server.zig` admits sealed-set voters only.
    `registry.zig` keeps `highest_allocated_node_id` monotonic, and
    admission rejects a sealed final-configuration member.

    *Checked.* The sealed-set quorum counting unit test; registry
    fence and ring monotonicity tests; the replacement scenario's
    sealed-voter restart, enrollment with registry fetch and verified
    install, a crash inside the transport swap converging by restart,
    a client connection held open across the swap, and a quorum that
    survives a survivor stop with the replacement voting.

    *Clause.* ZDS 0008.],

  [The typed-v1 client RPC preserves SQLite's five storage classes
    end to end, and a server without the typed contract is refused,
    never silently degraded to strings.],
  [*Enforced.* `server.zig` decodes tagged `params` and emits tagged
    result cells, carrying a non-finite real as its raw IEEE-754 bits
    (`{"t":"r","x":"<16 hex>"}`) because JSON cannot carry it as a
    number; `remote.zig` refuses a server whose status lacks
    `typed_v1` with `error.TypedV1Unsupported`.

    *Checked.* The C ABI smoke test's cluster typed-v1 query and
    exec-with-params checks; the Python type suite
    (`tests/dbapi/test_types.py`) round-trips the five storage
    classes through the SDK.

    *Clause.* ZDS 0010, the typed-boundary invariants.],

  [A remote client pool serves exactly one database. Every slot's
    first status probe must observe the pinned database identity or
    that slot fails.],
  [*Enforced.* `remote.zig` pins the identity from
    `expected_database_id`, or from the first successful status
    probe, and every slot's first probe compares against the pin,
    failing with `error.DatabaseMismatch` on any difference.

    *Checked.* The C ABI smoke test's remote-pool section against a
    dev-PSK loopback server.

    *Clause.* ZDS 0010, invariant 16.],
)

== Known verification gaps

Chapter 18 listed the suites. These are the holes the suites leave,
stated so that this chapter cannot be read as a completeness claim:

- The PSK mode proves only shared-secret possession and is no longer a
  production TCP mode. Mutual TLS 1.3 supplies per-node identity and
  confidentiality (SEC-001); mTLS redirect targets are pinned to their
  advertised node ID while PSK-only clients stay within supplied seeds
  (SEC-011). A reloaded node-ID denylist tears down active peer links and
  client connections carrying the same canonical node credential.
  The CLI test issues a bound one-time token through an authenticated mTLS
  client, generates and redeems a CSR, checks owner-only installation, uses the
  new identity for mTLS status, and rejects replay of a copied bundle. Initial
  CA and issuer credentials remain operator-provisioned. Gateways deliberately
  pass TLS through to a storage backend and cap raw connections at 128. No automated oracle
  sends an adversarial redirect hint yet. Zaxonlite intentionally has
  one application principal rather than database-user/RPC roles.
- Public SQL is now screened by the narrow authorizer in `guard.zig`, which
  protects the outer transaction, the attached-file boundary, capture-critical
  pragmas such as `wal_autocheckpoint`, and `__zaxon_*` metadata, with the
  capture contract re-verified before every payload extraction. The guard's
  decision table and contract check have unit tests, and a build test asserts
  `SQLITE_OMIT_LOAD_EXTENSION`. It remains an invariant guard for a trusted
  application, not a multi-tenant SQL sandbox, and no fuzzing targets it yet.
- Transferred snapshots carry the canonical stop sign inside the `ZXP2`
  proof, and the receiver requires matching proof-digest reports from a
  read quorum of the sealed voter set before validating and activating the
  image. Membership-changing snapshot transfer is supported through that
  proof plus the decided registry: a one-for-one voter replacement is
  admitted across a sealed epoch with sealed-set confirmation. The scope
  stays narrow: operator-initiated, one voter at a time, at least three
  voters, registry-backed servers only. Embedded clusters keep fixed
  membership, and nothing replaces a voter automatically.
- Connection admission is globally and per-peer capped, handshakes and idle
  sockets have deadlines, transfers are bounded at 4 GiB, and remote queries
  have SQL-text, row, result-byte, and SQLite VM-step budgets. Several aggregate
  recovery-size campaigns and streaming JSON results remain release evidence
  work. Existing fuzzing is not a full denial-of-service oracle.

- The chapter-6 crash matrix is not fully automated in both the
  one-node and three-node roles. Completing it is a release blocker.
- The 10,000-crash, 100-consecutive-cluster-run, and 1-GiB recovery
  gates are explicitly deferred. The checked large fixture is 1 MiB.
- The committed `read_barrier` command is the slow reference read,
  but no current suite issues it as a differential oracle against the
  fence path. Fence evidence today is the cluster's linearizable
  counts plus the safety argument in chapter 6.
- The core Paxos library is model-checked in `specs/Paxos.tla`, and a
  bounded host-level model of the voter replacement,
  `specs/VoterReplacement.tla`, sits beside it. The rest of the
  Zaxonlite layering has no machine-checked specification. The
  journal, payload store, capture and apply, and session table rest
  on the plan's proof section plus the oracles above.
- The startup configuration refusals for the nine-voter cap, zero
  campaigners, and duplicate node IDs are enforced but untested by
  automation.
- Fault schedules beyond the deterministic adverse run, meaning long
  random interleavings of loss, reordering, and crashes, remain
  future work.

When a guarantee changes, edit the normative clause, the code, the
oracle, and this table in one reviewable change. That is the same
rule the core library applies to its handlers, simulator oracles, and
TLA actions, and it is the discipline that keeps this chapter true.

#teach_back([
  Close the book by teaching its central habit. Pick any row of this
  chapter and explain it to a colleague three times: once as the
  promise a user relies on, once as the code path that enforces it,
  and once as the test that would fail if the code path broke. Then
  name one row whose oracle is still missing, and describe the test
  you would write to close it. When you can do that for a guarantee
  you did not build, you have what this book set out to give you.
])
