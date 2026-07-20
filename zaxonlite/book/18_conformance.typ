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

Chapter 17 described the suites as layers. Here each row names the
specific evidence inside them. Unit tests pin codecs and single-file
invariants. `integration_test.zig` drives one real node through
restart and recovery. `cluster_test.zig` drives three real
`zaxon serve` processes over the public RPC surface with no back
door. The role, fault, and gateway suites cover the remaining
topologies, and `fuzz.zig` attacks decoders, journal files, and
whole-node schedules. In the clause column, "Format §_n_" names a
numbered section of `docs/zaxonlite-format.typ`, and "plan" names a
section of `docs/zaxonlite-product-plan.typ`. Where no automated
oracle exists, the row says so directly. An unchecked guarantee is a
claim, not evidence, and we would rather you know which rows are
which.

== Durability and the write path

#table(
  columns: (1fr, 1.55fr),
  table.header([*Guarantee*], [*Evidence*]),
  [An acknowledged write is durable and decided. No message or reply
    precedes its journal fsync.],
  [*Enforced.* In `node.zig`, `consumeEffects` runs `journal.sync`
    before `confirmWritesDurable` and before any envelope enters the
    `outbox`. In `server.zig`, `runWrite` replies only after the slot
    is chosen and applied.

    *Checked.* The `crash_test.zig` cases `after_accept_sync` and
    `after_commit_sync_before_apply` require a recovered count of
    exactly 1. The cluster scenario's final step asserts every
    acknowledged write is present exactly once, 153 rows after total
    restart.

    *Clause.* Format §5; plan "Ordering rules", steps 2 to 4.],

  [Payload bytes are verified and durable before any value-bearing
    Promise, Accept, or Commit enters the Paxos transition. The
    storage-ACK gate covers Phase-1 promises too.],
  [*Enforced.* `server.zig` `onEnvelopeFrame` verifies the store, or
    parks the envelope in `holdEnvelope` and requests the payload. On
    the sending side, `drainOutbox` and `gatePayload` hold frames
    until `payload_stored`. `wire.zig` `envelopePayloadHash` covers
    promise, accept, and commit alike.

    *Checked.* The `wire.zig` test "envelope payload hash
    extraction"; `fault_cluster_test.zig` under loss, duplication,
    reordering, fragmentation, and delayed durable sync, ending in
    equal counts; the `payload_store.zig` test "payload store detects
    corruption and missing objects".

    *Clause.* Format §3, the payload-storage-ACK invariant.],

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

  [No silent wire-version downgrade. Wrong protocol versions, missing
    shared secrets, and replayed or tampered frames are refused. This does
    not authenticate a distinct configured node identity.],
  [*Enforced.* `wire.zig` `Hello.decode` accepts exactly version 4
    and raises `UnsupportedProtocolVersion` otherwise; `server.zig`
    refuses non-loopback listeners or peers without a secret;
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

  [One serialized writer per database. Concurrent endpoints never
    create multi-leader writes.],
  [*Enforced.* The `server.zig` `runWrite` `writer_busy` gate allows
    one replicated write at a time; `node.zig` `WriteInFlight` and
    the exclusive directory lock, `tryLock(.exclusive)` raising
    `error.NodeLocked`, guard the node; non-leaders answer
    `not_leader`.

    *Checked.* `integration_test.zig` "a second process cannot open a
    locked node directory"; the cluster scenario submits writes
    through all three endpoints and counts every row exactly once.

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
)

== Known verification gaps

Chapter 17 listed the suites. These are the holes the suites leave,
stated so that this chapter cannot be read as a completeness claim:

- Protocol v4 proves only shared-PSK possession. It has no credential-bound
  node identity or confidentiality. Zaxonlite intentionally has one
  application principal rather than database-user/RPC roles, but the current
  transport tests do not establish the planned mTLS boundary.
- Public SQL has no narrow authorizer protecting Zaxonlite's outer transaction,
  attached-file boundary, WAL-hook settings such as `wal_autocheckpoint`, or
  `__zaxon_*` metadata. This is a replication invariant gap reachable through
  the normal API, not a multi-tenant SQL sandbox requirement. Loadable
  extensions are already compiled out with `SQLITE_OMIT_LOAD_EXTENSION`.
- Transferred snapshot manifests are digest-checked but are not verified
  against the existing Paxos-decided stop sign before installation. Normal
  rollover already decides the physical manifest hash; the missing work is
  retained proof plus read-quorum confirmation during transfer, not a new
  certificate/signature phase.
- Connection readers, handshake/idle time, query work/results, and several
  transfer/recovery sizes lack production resource budgets. Existing fuzzing
  is not a denial-of-service or admission-control oracle.

- The chapter-6 crash matrix is not fully automated in both the
  one-node and three-node roles. Completing it is a release blocker.
- The 10,000-crash, 100-consecutive-cluster-run, and 1-GiB recovery
  gates are explicitly deferred. The checked large fixture is 1 MiB.
- The committed `read_barrier` command is the slow reference read,
  but no current suite issues it as a differential oracle against the
  fence path. Fence evidence today is the cluster's linearizable
  counts plus the safety argument in chapter 6.
- The core Paxos library is model-checked in `specs/Paxos.tla`, but
  the Zaxonlite layering has no machine-checked specification. The
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
