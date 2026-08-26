#let zds-number = "XXXXX"
#let zds-title = "Global Slots and Certified Log Trimming"
#let zds-state = "prediscussion"
#let zds-created = "2026-08-26"
#let zds-discussion = "Remove the 2,044-commit rollover by separating Paxos progress, log retention, and SQLite state transfer"
#let zds-labels = ("consensus", "paxos", "zaxonlite", "storage", "verification",)
#let zds-authors = ("paxos-zig project",)
#let zds-category = "Engineering Discussion"
#let zds-status = "Internal Draft"
#let zds-last-updated = "None"

#import "../../shared/zds.typ": zds-document
#import "@preview/fletcher:0.5.8" as fletcher: diagram, edge, node

#let ink = rgb("334155")
#let blue = (fill: rgb("dbeafe"), stroke: rgb("2563eb"))
#let cyan = (fill: rgb("cffafe"), stroke: rgb("0891b2"))
#let green = (fill: rgb("dcfce7"), stroke: rgb("16a34a"))
#let amber = (fill: rgb("fef3c7"), stroke: rgb("d97706"))
#let red = (fill: rgb("fee2e2"), stroke: rgb("dc2626"))
#let violet = (fill: rgb("ede9fe"), stroke: rgb("7c3aed"))
#let slate = (fill: rgb("f1f5f9"), stroke: rgb("64748b"))

#let flow-node(pos, title, detail, palette, width: auto) = node(
  pos,
  align(center)[
    #text(9pt, weight: "bold", fill: palette.stroke.darken(20%))[#title]
    #linebreak()
    #text(7.1pt, fill: ink)[#detail]
  ],
  fill: palette.fill,
  stroke: 0.9pt + palette.stroke,
  shape: fletcher.shapes.rect,
  corner-radius: 5pt,
  inset: 7pt,
  width: width,
)

#let edge-label(body) = text(7.1pt, fill: rgb("475569"), style: "italic")[#body]

#let zds-figure(body) = context {
  if target() == "html" {
    html.frame(align(center, body))
  } else {
    align(center, body)
  }
}

#let claim(kind, title, palette, body) = block(
  width: 100%,
  breakable: false,
  fill: palette.fill,
  stroke: (left: 3pt + palette.stroke),
  radius: 4pt,
  inset: (x: 11pt, y: 8pt),
)[
  #text(9.2pt, weight: "bold", fill: palette.stroke.darken(20%))[#kind — #title]
  #v(4pt)
  #body
]

#show: doc => zds-document(
  zds-number,
  zds-title,
  doc,
  authors: zds-authors,
  state: zds-state,
  created: zds-created,
  discussion: zds-discussion,
  labels: zds-labels,
  category: zds-category,
  status: zds-status,
  last-updated: zds-last-updated,
)

= Abstract

The current Paxos core allocates state for a compile-time maximum number of
slots. Zaxonlite sets that limit to 2,048 entries and reserves the final four
positions. Near slot 2,044, the host checkpoints SQLite, copies the complete
database, synchronizes the copy, hashes every byte, seals the Paxos
configuration, and restarts slot numbering in a new configuration.

That mechanism is safe but combines three independent concerns: bounded RAM,
log reclamation, and state transfer. Its routine cost is proportional to
database size while its frequency is proportional to writes. A multi-terabyte
SQLite database therefore cannot use the current rollover as an ordinary
maintenance operation.

This record proposes a different boundary:

- one monotonic 64-bit global slot space;
- a fixed-size, slot-tagged in-memory consensus window;
- a segmented durable journal indexed by absolute slot;
- a durable applied frontier and hash-chain anchor;
- consensus-certified prefix trimming; and
- on-demand state transfer only when a replica cannot recover from retained
  log segments.

Membership configurations remain explicit, but no longer exist to recycle
slots. Normal trimming never copies or hashes the SQLite database. The design
keeps Paxos safety, bounds memory independently of database lifetime, and
makes common-path reclamation depend on the amount of obsolete log data rather
than the size of materialized application state.

= Decision Summary

#block(width: 100%, breakable: false, fill: rgb("f8fafc"), stroke: 0.8pt + rgb("cbd5e1"), radius: 6pt, inset: 11pt)[
  *Proposed direction.* Replace epoch-capacity rollover with global slots and
  certified log trimming. Keep stop signs only for real membership changes.

  *Safety authority.* Paxos chooses commands and trim records. A node may
  delete a prefix only after it has durable application evidence and a chosen
  trim certificate bound to that exact history prefix.

  *Recovery authority.* The local SQLite image plus its durable applied anchor
  is a checkpoint. Exact captured page images are replayed from segmented
  journals. A node behind the retained prefix installs a verified online
  backup and then replays the suffix.

  *Performance intent.* The steady write path retains one Paxos decision and
  the existing durability barrier. Segment rotation and trimming are
  independent of SQLite database size. Physical database transfer is paid
  only for bootstrap, repair, replacement, or irrecoverable lag.
]

= Introduction

Paxos needs an unbounded logical sequence, not unbounded volatile memory. A
finite implementation may retain a bounded moving window so long as old
decisions remain recoverable and a reused physical cell cannot be confused
with its former logical slot. Database systems make the same distinction:
ARIES separates the log sequence number, the durable log, and the page state;
Raft snapshots and Multi-Paxos trimming separate replicated progress from log
retention; production systems such as Spanner, DynamoDB, Aurora, and Delos
compose consensus with independently managed storage layers.

The present implementation instead treats a compile-time array bound as the
end of a logical log. Zaxonlite repairs that exhaustion by creating a complete
snapshot generation and a new Paxos configuration. This works for a small
database, but it makes the cost per write grow with the database:

$ C_("old")(D, E) = (C_("copy")(D) + C_("hash")(D) + C_("sync") + C_("transition")) / E $

where $D$ is database size and $E$ is the fixed number of writes per epoch.
For sequential copy and hashing bandwidths $B_c$ and $B_h$,

$ C_("old")(D, E) >= D / E dot (1 / B_c + 1 / B_h) $

so the amortized cost diverges linearly as $D$ grows while $E$ stays 2,044.
Changing the constant merely moves the failure point.

The desired architecture has an unbounded logical history, bounded working
memory, bounded retained recovery history, and rare state transfer. Those are
compatible properties when each boundary has its own proof.

= Terminology and Scope

- *global slot* $s$: a monotonically increasing `u64` Paxos instance number;
  it never resets during the lifetime of a database
- *configuration*: a versioned voter set; it changes only through an explicit
  membership decision
- *consensus window* $W$: the maximum number of unresolved or locally retained
  Paxos slots represented in fixed memory
- *segment*: an immutable, contiguous range of durable journal records
- *chosen frontier* $C$: the greatest slot for which every slot through $C$ is
  locally known chosen
- *applied frontier* $A_i$: the greatest contiguous chosen slot durably
  reflected in replica $i$'s SQLite image and applied-anchor record
- *persisted frontier* $P_i$: the greatest contiguous slot durably present in
  replica $i$'s journal
- *trim frontier* $T$: the greatest slot whose older journal prefix a node is
  authorized to discard
- *history anchor* $H_s$: a cryptographic commitment to the ordered command
  prefix through slot $s$
- *recovery holder*: an independent failure domain with a verified state image
  through $T$ and the ability to serve a suffix or state transfer
- *soft trim*: deletion safe because every current data replica is known
  durably applied through the prefix
- *hard trim*: deletion safe under the configured failure model because a
  quorum certificate proves enough independent recovery holders

This record is limited to the Paxos slot limit, journal retention, checkpoint
authority, recovery, and the zaxonlite coupling that causes periodic full
database copies. Vector indexing, `vec0`, ranking fusion, query execution,
sharding, and cross-database transactions are explicitly out of scope.

= Problem Statement

The implementation has four coupled bounds.

1. `src/protocol.zig` defines `Slot = u32` and allocates accepted, committed,
   recovered, proposal, acknowledgement, message, write, and bit-set storage
   from `options.max_slots`.
2. `src/replicated_log.zig` maps `max_entries` directly to that lifetime slot
   limit, and `src/learner.zig` retains a fixed array indexed from slot one.
3. `zaxonlite/src/types.zig` chooses `max_entries = 2048`.
   `epochNearlyFull()` reserves four entries, so ordinary writes stop near
   2,044.
4. `zaxonlite/src/node.zig` resolves that stop by checkpointing SQLite,
   copying `current.db`, synchronizing the copy, hashing the whole copy, and
   completing a same-member configuration rollover.

#zds-figure(
  diagram(
    spacing: (15mm, 11mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [2,044 writes], [array nearly full], amber),
    flow-node((1, 0), [SQLite], [checkpoint WAL #linebreak() copy all $D$ bytes], red),
    flow-node((2, 0), [Snapshot], [full sync #linebreak() SHA-256 all $D$], red),
    flow-node((3, 0), [Stop sign], [seal same voters #linebreak() elect again], amber),
    flow-node((4, 0), [New epoch], [slots reset #linebreak() arrays cleared], blue),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), edge-label[$Theta(D)$], "-|>"),
    edge((2, 0), (3, 0), "-|>"),
    edge((3, 0), (4, 0), "-|>"),
    edge((4, 0), (0, 0), edge-label[repeat after 2,044], "-|>", bend: -42deg),
  ),
)

The full snapshot is not required for Paxos agreement. It exists because the
volatile representation cannot advance past its compile-time array. A
membership primitive is therefore being used as a memory-reclamation
primitive, and application state size appears in the normal consensus cost.

== Why a larger epoch is insufficient

Let the epoch contain $E$ commands and let the database reach size $D$. Even
if $E$ is raised by a factor of $k$, the amortized snapshot term is only
divided by $k$. It is not eliminated. A sufficiently large $D$ again dominates.
A larger fixed array also increases every node's static memory and derived
effect capacities, even when only a small pipeline is active.

== Why SQLite's size limit does not solve it

SQLite can address very large files, but that says nothing about how a host
replication layer retains consensus metadata. SQLite's pager, WAL, and backup
interfaces already support incremental operation. Zaxonlite introduces the
2,044-commit discontinuity above SQLite. The correction belongs at the
replication and recovery boundary.

= Goals and Non-Goals

== Goals

- Support a database lifetime of at least $2^64 - 1$ logical slots without
  periodic slot reset.
- Bound consensus RAM by configured concurrency and recovery windows, not by
  lifetime commit count.
- Remove complete database copy, complete database hash, and same-member
  reconfiguration from normal log reclamation.
- Preserve Paxos agreement and prefix consistency across trimming, crash,
  recovery, and membership change.
- Keep exact captured SQLite page-image replay deterministic and idempotent.
- Permit slow or replaced replicas to recover by log suffix when possible and
  verified state transfer when necessary.
- Preserve one through nine voters and the present data-voter/witness roles.
- Specify wire and durable format migration without decoder guessing.
- Make safety arguments executable through a small formal model and crash
  matrices.
- Hold the steady-state Paxos benchmark regression to a reviewed threshold and
  eliminate database-size-correlated rollover latency.

== Non-Goals

- No vector or ANN index design.
- No Byzantine consensus or adversarial quorum certificates.
- No multi-writer SQLite execution.
- No automatic sharding or distributed SQL planner.
- No requirement to retain all historical values in RAM or on every node.
- No guarantee that a node offline beyond the retention horizon can recover
  without transferring state.
- No replacement of SHA-256 as the existing integrity primitive.
- No mandatory disaggregated storage service.

= Design Overview

The proposal separates five monotonic layers.

#zds-figure(
  diagram(
    spacing: (16mm, 10mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [Global slots], [`u64` #linebreak() never reset], blue),
    flow-node((1, 0), [Tagged window], [$W$ live cells #linebreak() bounded RAM], cyan),
    flow-node((2, 0), [Segmented log], [absolute ranges #linebreak() durable suffix], violet),
    flow-node((3, 0), [SQLite state], [page images through #linebreak() durable $A_i$], green),
    flow-node((4, 0), [Trim proof], [chosen $T, H_T$ #linebreak() delete prefix], amber),
    flow-node((3, 1), [State transfer], [online backup at $S$ #linebreak() only on demand], slate),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), "-|>"),
    edge((2, 0), (3, 0), "-|>"),
    edge((3, 0), (4, 0), "-|>"),
    edge((3, 0), (3, 1), edge-label[repair / join], "-|>"),
  ),
)

Slots identify decisions. The in-memory window accelerates active decisions.
Segments retain a recoverable suffix. SQLite materializes the chosen prefix.
The applied anchor proves how far that materialization is durable. A trim
record authorizes deletion. None of those concepts changes the voter set.

= System Model and Axioms

Let a configuration contain $N = 2f + 1$ voters and let a write quorum contain
$q = f + 1$ voters. Nodes are non-Byzantine and may crash, restart, lose
messages, duplicate messages, or receive them out of order.

#claim([Axiom 1], [Quorum intersection], blue, [
  Any two quorums of size $q$ intersect because
  $2q = 2f + 2 > 2f + 1 = N$.
])

#claim([Axiom 2], [Ordered stable storage], violet, [
  If a node acknowledges durable write $y$ after ordering durable write $x$
  before it with the platform's supported barrier, recovery cannot expose
  $y$ while losing $x$. Torn or incomplete final records are detected by
  length, sequence, and checksum.
])

#claim([Axiom 3], [Deterministic page application], green, [
  A committed zaxonlite payload contains page numbers and complete page
  images. Applying the same valid payload twice writes identical bytes to
  identical offsets. It is therefore idempotent with respect to the resulting
  SQLite image.
])

#claim([Axiom 4], [Paxos safety], blue, [
  For a fixed global slot and configuration history, at most one command value
  is chosen. Phase one recovers a previously chosen or potentially chosen
  value before a leader may choose another.
])

#claim([Axiom 5], [Authenticated configuration], amber, [
  Only an authenticated current voter contributes to a Paxos quorum or a trim
  readiness certificate. Membership transitions obey the stop-sign and
  decided-registry rules of ZDS 0008.
])

= Detailed Design

== Global slot space

`Slot` becomes `u64`. The first post-migration command uses slot one. Each
successful allocation increments `next_slot`; no configuration transition
resets it. Slot zero remains the genesis anchor and sentinel.

The database identity names one global slot line. Configuration ID and slot
are carried separately:

```text
Instance = { database_id, configuration_id, global_slot }
```

A membership stop occupies an ordinary global slot. The next configuration
begins at the following global slot. Its phase-one recovery includes the
retained suffix and anchor inherited from the sealed configuration.

Overflow is explicit. A database at `maxInt(u64)` returns
`GlobalSlotExhausted`; it never wraps to zero. At one million commits per
second, exhausting 64 bits requires more than 584,000 years.

== Slot-tagged consensus window

The core option `max_slots` is replaced by `window_slots = W`, where $W$ is a
power of two. It limits concurrent unresolved and locally cached instances,
not lifetime history. A physical cell is selected by

$ j(s) = s and (W - 1) $

and contains an explicit tag:

```text
WindowCell(Value) {
    slot: u64,
    state: empty | accepted | chosen | delivered,
    ballot: Ballot,
    value: ?Value,
    acknowledgements: MemberSet,
}
```

A lookup for $s$ succeeds only when `cell.slot == s`. A cell may be cleared
and retagged for $s + W$ only after $s <= T_("memory")$, where the core has
delivered the value and the host has durably consumed every effect needed to
recover it.

#zds-figure(
  diagram(
    spacing: (13mm, 11mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [cell 0], [tag 104 #linebreak() chosen], green),
    flow-node((1, 0), [cell 1], [tag 105 #linebreak() delivered], green),
    flow-node((2, 0), [cell 2], [tag 106 #linebreak() accepted], amber),
    flow-node((3, 0), [cell 3], [tag 107 #linebreak() empty], slate),
    flow-node((1, 1), [advance], [$T_("memory") >= 105$], blue),
    flow-node((2, 1), [reuse cell 1], [retag 109 #linebreak() never aliases 105], cyan),
    edge((1, 0), (1, 1), "-|>"),
    edge((1, 1), (2, 1), "-|>"),
  ),
)

#claim([Lemma 1], [Tagged-cell non-aliasing], cyan, [
  For distinct logical slots $s != t$ with $j(s) = j(t)$, a lookup for $s$
  cannot return state belonging to $t$.

  *Proof.* The lookup predicate requires both equal physical index and equal
  tag. The stored tag is one integer. It cannot equal distinct integers $s$
  and $t$ simultaneously. Therefore reuse changes a cell's occupant but
  cannot change the identity of a successful lookup. $square$
])

The leader applies backpressure before overwriting an active cell:

$ "next_slot" - T_("memory") < W $

`WindowFull` is a transient flow-control result. It is not a terminal log
limit and does not trigger a snapshot or configuration change.

== Bounded Phase One and catch-up

The present promise can derive capacities proportional to `max_slots`.
Version 2 replaces an all-history promise with a bounded range:

```text
PromiseV2 {
    ballot
    anchor = { trim_slot, history_hash }
    accepted_range = [lo, hi]
    accepted[]
    chosen_through
    more
}
```

The leader begins with the greatest compatible trim anchor reported by a
quorum, then requests chunks of at most `recovery_chunk_slots`. It may propose
new commands only after recovering every unresolved slot from the anchor
through the high-water mark. `more` causes another bounded exchange; it does
not authorize skipping a range.

Catch-up similarly requests `[from, min(from + chunk - 1, C)]`. Messages,
effects, and writes are bounded by window and chunk sizes. No network frame or
stack object is proportional to database lifetime.

== Segmented consensus journal

The one-file-per-configuration journal becomes a sequence of immutable data
segments plus a small active segment:

```text
consensus/
  MANIFEST
  0000000000000001-0000000000010000.zxj
  0000000000010001-0000000000020000.zxj
  active.zxj
  APPLIED.0
  APPLIED.1
  TRIM
```

Each v2 segment header contains:

```text
magic = ZXS2
format_version = 2
database_id
first_global_slot: u64
previous_segment_digest: [32]u8
```

Each record retains canonical kind, sequence, length, bytes, and checksum. A
sealed trailer contains `last_global_slot`, record count, segment digest, and
a sparse table from every $k$th slot to byte offset. Segment names are hints;
headers and hashes are authoritative.

Rotation writes and syncs the trailer, writes a new manifest generation,
atomically selects it, syncs the directory, and only then opens the next
active segment. A crash exposes either the old manifest plus old active file
or the new complete generation. Recovery never infers a missing interior
segment from filenames.

The segment digest chain is an integrity and gap-detection mechanism, not a
Byzantine proof. Existing authenticated transport and quorum rules remain the
source of consensus authority.

== Ordered history anchor

Let `entry_digest(s)` be SHA-256 over the canonical chosen entry descriptor
and payload digest for slot $s$. Define

$ H_0 = "SHA256"("zaxon-global-history-v1" || "database_id") $

$ H_s = "SHA256"("zaxon-global-entry-v1" || H_(s-1) || "LE64"(s) || "entry_digest"(s)) $

Every applied anchor, segment boundary, trim record, and state-transfer
manifest binds a pair $(s, H_s)$. The hash chain commits to order and content;
it does not claim to be a complete hash of the SQLite file.

#claim([Lemma 2], [Prefix-anchor uniqueness], violet, [
  Assuming SHA-256 collision resistance and canonical encoding, two histories
  with the same database ID and the same anchor $(s, H_s)$ contain the same
  ordered entry digests through $s$, except with negligible collision
  probability.

  *Proof sketch.* Choose the greatest position at which the histories differ.
  The inputs to that position's hash differ while its output, required by all
  later equal anchors, must be equal. This yields a collision in SHA-256 or in
  a canonical entry digest. $square$
])

== Durable SQLite applied anchor

Each data replica maintains two alternating fixed-size records, `APPLIED.0`
and `APPLIED.1`:

```text
magic = ZXAP
version = 1
generation: u64
database_id
global_slot: u64
history_hash: [32]u8
sqlite_page_size: u32
sqlite_page_count: u64
checksum: [32]u8
```

After applying chosen page images through $s$, the node orders durability as:

```text
payload and chosen journal record durable
  -> write exact page images to current.db
  -> make database writes durable
  -> write inactive APPLIED generation for (s, H_s)
  -> durability barrier
  -> publish A_i = s and acknowledge trim readiness
```

The node selects the valid record with the greatest generation. It never
trusts a marker whose database identity, file geometry, checksum, or history
anchor fails validation. A corrupt or missing marker causes conservative
replay or state transfer; it never advances the frontier.

The anchor is a sidecar rather than a SQLite metadata row because the Paxos
slot is known only after the leader has captured the transaction's page
images. Reapplying exact page images is idempotent under Axiom 3, so a crash
after database persistence but before anchor persistence is harmless.

#claim([Lemma 3], [Applied-anchor crash safety], green, [
  After recovery chooses durable anchor $(A_i, H_(A_i))$, replaying the
  contiguous chosen suffix $A_i + 1$ through $C$ produces the same materialized
  SQLite bytes as one failure-free application of the prefix through $C$.

  *Proof.* Ordered storage prevents a selected anchor from being newer than
  durable page writes. Any page writes newer than the selected anchor came
  from a suffix command whose journal record is already durable. Recovery
  reapplies that command. Exact page-image writes are idempotent, so applying
  a partially or fully applied command again has the same final bytes. By
  induction over the contiguous suffix, the recovered image equals the
  failure-free image. $square$
])

== Progress frontiers

For every active data replica $i$:

$ 0 <= T_i <= A_i <= C_i <= P_i < "next_slot" $

Witnesses persist Paxos records but do not materialize SQLite; they report
$P_i$ and never claim $A_i$. A leader includes its observed chosen frontier in
heartbeats. Data replicas piggyback `(applied_slot, history_hash)` on durable
acknowledgements.

#zds-figure(
  diagram(
    spacing: (14mm, 10mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [$T$], [trimmed prefix #linebreak() anchor retained], violet),
    flow-node((1, 0), [$A_min$], [all healthy data #linebreak() replicas applied], green),
    flow-node((2, 0), [$C$], [contiguous chosen #linebreak() prefix], blue),
    flow-node((3, 0), [$P$], [durable journal #linebreak() high water], cyan),
    flow-node((4, 0), [`next_slot`], [first unallocated #linebreak() instance], amber),
    edge((0, 0), (1, 0), edge-label[$<=$], "-|>"),
    edge((1, 0), (2, 0), edge-label[$<=$], "-|>"),
    edge((2, 0), (3, 0), edge-label[$<=$], "-|>"),
    edge((3, 0), (4, 0), edge-label[$<$], "-|>"),
  ),
)

== Soft trim: the common path

The common path follows the conservative rule used by complete Multi-Paxos
implementations:

$ T_("all") = min_(i in D) A_i $

where $D$ is the set of current data replicas. If every data replica reports
the same $H_(T_("all"))$, the leader may propose:

```text
Trim {
    trim_id: u64
    through_slot: u64
    history_hash: [32]u8
    mode: all_applied
    configuration_id
}
```

Once chosen and durably recorded, each node writes `TRIM`, advances its
in-memory floor, and removes only complete segments whose last slot is at or
below $T$. Segment deletion occurs after the new trim record and manifest are
durable. A partial final segment is retained or rewritten by a separately
synced generation; it is never truncated in place past uncertain bytes.

#claim([Lemma 4], [All-applied trim safety], green, [
  Deleting journal entries through $T_("all")$ cannot prevent any current data
  replica from reconstructing its materialized state.

  *Proof.* By definition, every current data replica has durably applied every
  slot through $T_("all")$. By Lemma 3, its applied anchor is a recovery base and
  replay is required only after that anchor. Therefore no deleted entry is
  required by a current data replica's local recovery. $square$
])

Soft trim is preferred because it needs no special availability argument. A
temporarily slow replica delays disk reclamation but not command choice until
the configured retention budget is approached.

== Hard trim: certified recovery quorum

A permanently offline data replica must not retain the cluster's disk forever.
For hard trim, define $R_T$ as independent recovery holders that have durably
stored and verified:

- a materialized state through at least $T$ with anchor $H_T$; and
- either every segment after $T$ or the ability to obtain the chosen suffix
  from the active quorum.

Each holder signs an authenticated, configuration-bound readiness message:

```text
ReadyToTrim {
    database_id
    configuration_id
    through_slot: u64
    history_hash: [32]u8
    state_generation
    holder_id
}
```

The leader may propose `Trim(mode: recovery_quorum)` only with $q = f + 1$
distinct valid readiness records for the identical anchor. The chosen trim
record contains the digest of that certificate. A witness is not a recovery
holder unless it also stores and can serve a verified materialized image.
An external archive may count only when configured as an independent durable
failure domain and covered by an explicit availability policy.

#claim([Lemma 5], [Recovery-holder survival], amber, [
  If $q = f + 1$ independent holders certify $(T, H_T)$ and at most $f$ of
  them fail, at least one certified recovery source remains.

  *Proof.* Removing at most $f$ elements from a set of $f + 1$ leaves at least
  one element. $square$
])

#claim([Lemma 6], [Future-quorum intersection], blue, [
  In the unchanged configuration, every future Paxos quorum intersects the
  quorum whose authenticated readiness certificate is bound into the chosen
  trim.

  *Proof.* Both sets have size $f + 1$ in a universe of $2f + 1$. A disjoint
  pair would require $2f + 2$ distinct voters, a contradiction. $square$
])

Lemma 6 prevents a future leader from inventing an incompatible prefix;
Lemma 5 ensures a state source survives the assumed failures. Both are
required. A quorum of log-only witnesses is insufficient for state recovery.

== Trim state machine

#zds-figure(
  diagram(
    spacing: (15mm, 11mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [Observe], [collect $A_i, H_(A_i)$ #linebreak() and disk budget], slate),
    flow-node((1, 0), [Candidate], [choose complete #linebreak() segment boundary $T$], cyan),
    flow-node((2, 0), [Certify], [all applied or #linebreak() $f+1$ holders], amber),
    flow-node((3, 0), [Choose], [Paxos decides #linebreak() `Trim(T,H_T)`], blue),
    flow-node((4, 0), [Anchor], [`TRIM` + manifest #linebreak() durable], violet),
    flow-node((5, 0), [Reclaim], [unlink old segments #linebreak() payload GC], green),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), "-|>"),
    edge((2, 0), (3, 0), "-|>"),
    edge((3, 0), (4, 0), "-|>"),
    edge((4, 0), (5, 0), "-|>"),
  ),
)

Trim IDs are monotonic and idempotent. A lower trim is ignored after
validation. A same-ID different-anchor record is fatal corruption. Nodes may
physically delete at different times, but no node advertises a higher trim
floor than its durable `TRIM` record.

== Payload garbage collection

Sealed segment trailers contain a sorted set or compact manifest of referenced
payload digests. A payload object is reachable if any retained segment,
unsealed active record, pending state transfer, or chosen-but-not-applied entry
references it. It may be deleted only when:

$ "last_reference_slot" <= T_i and A_i >= "last_reference_slot" $

and no retained manifest names it. Garbage collection writes a candidate
reachability generation, verifies it against retained segments, atomically
publishes it, and then unlinks unreachable objects. Crashes may leak objects;
they may not delete reachable ones.

== Recovery protocol

Startup follows a strict ladder.

1. Select the valid highest `APPLIED` generation and its $(A_i, H_(A_i))$.
2. Select the valid journal manifest and durable `TRIM` anchor.
3. If $A_i >= T_i$, replay the contiguous journal suffix from $A_i + 1$.
4. If the suffix has a gap, stop before voting and request range repair.
5. If $A_i < T_("cluster")$ or the local SQLite image is lost, install state from
   a certified recovery holder.
6. Verify the transferred database digest and manifest anchor at slot $S$,
   atomically select it, then replay $S + 1$ through the current chosen
   frontier.

State transfer uses SQLite's online backup interface to create a transactionally
consistent source image while writes continue. The sender records an anchor
$S$ before the backup, streams chunks with an end-to-end digest, and retains
the suffix after $S$ until the receiver acknowledges durable installation.
If the backup view corresponds to a later SQLite state than $S$, the sender
must choose the exact applied anchor associated with that view; it may not
guess an earlier slot from wall-clock timing.

#zds-figure(
  diagram(
    spacing: (15mm, 11mm),
    node-outset: 2pt,
    edge-stroke: 0.8pt + rgb("64748b"),
    flow-node((0, 0), [Open], [verify SQLite #linebreak() and `APPLIED`], slate),
    flow-node((1, 0), [$A_i >= T$?], [local base still #linebreak() recoverable], amber),
    flow-node((2, 0), [Replay suffix], [exact page images #linebreak() $A_i+1 ... C$], green),
    flow-node((1, 1), [Install state], [verified backup #linebreak() at anchor $S$], violet),
    flow-node((2, 1), [Replay tail], [$S+1 ... C$], cyan),
    flow-node((3, 0), [Ready], [integrity check #linebreak() then vote], blue),
    edge((0, 0), (1, 0), "-|>"),
    edge((1, 0), (2, 0), edge-label[yes], "-|>"),
    edge((1, 0), (1, 1), edge-label[no], "-|>"),
    edge((1, 1), (2, 1), "-|>"),
    edge((2, 0), (3, 0), "-|>"),
    edge((2, 1), (3, 0), "-|>", bend: 18deg),
  ),
)

== Membership change

Stop signs remain the only membership-change primitive. A chosen stop sign
names the next registry as in ZDS 0008, but it does not require a database
snapshot and does not reset slots. Before a new voter activates, it installs a
certified state and suffix through the activation frontier. Surviving voters
carry the same global trim anchor into the next configuration.

Cross-configuration hard trim requires the readiness certificate to identify
the holder set and both registry digests. Removed holders do not count toward
the new configuration's future recovery quorum unless an explicit external
archive policy preserves their state.

== Backpressure and storage budget

The system has flow-control limits, not a lifetime command limit:

$ "next_slot" - T_("memory") < W $

$ P_("leader") - min_(i in "write_quorum") P_i <= L_("replication") $

$ C - min_(i in "healthy_data") A_i <= L_("apply") $

Crossing a soft threshold starts segment sealing, trim collection, or replica
repair. Crossing a hard local disk threshold rejects new writes with
`RecoveryRetentionExceeded` until a safe trim, state transfer, or operator
capacity change succeeds. The node never deletes unproven history to remain
available.

= Safety Proof

#claim([Theorem 1], [Agreement survives window reuse and trimming], blue, [
  Under Axioms 1, 2, 4, and 5, no two different commands can be chosen for the
  same global slot after any sequence of window reuse, segment deletion,
  crash recovery, and unchanged-configuration trims.

  *Proof sketch.* Before trimming, ordinary Paxos agreement follows Axiom 4.
  Window reuse cannot substitute one slot's accepted state for another by
  Lemma 1. A trim record is itself chosen by Paxos and binds the unique prefix
  anchor from Lemma 2. Every later phase one begins from a quorum-compatible
  anchor and recovers all unresolved slots above it. For soft trim, every data
  node already materializes the prefix by Lemma 4. For hard trim, every future
  quorum intersects the certificate quorum by Lemma 6 and at least one state
  source survives the failure bound by Lemma 5. Thus deletion removes bytes,
  not the chosen-prefix fact needed to constrain future proposals. Any
  conflicting choice would contradict Paxos agreement, quorum intersection,
  or hash collision resistance. $square$
])

#claim([Theorem 2], [Recovered-state prefix correctness], green, [
  A data replica that reaches `Ready` after the recovery ladder materializes
  exactly the ordered chosen command prefix through its reported applied
  frontier.

  *Proof.* A local base is safe by Lemma 3. A transferred base is accepted only
  after its state digest and history anchor match a certified holder. In both
  branches the node replays one contiguous sequence of chosen, digest-bound
  page-image payloads. Induction on the suffix and Axiom 3 give the exact
  prefix state. A gap or mismatch stops activation, so no other path reaches
  `Ready`. $square$
])

#claim([Theorem 3], [Lifetime-independent volatile memory], cyan, [
  For fixed member bound $M$, consensus window $W$, and recovery chunk $R$,
  volatile consensus memory is independent of lifetime slot count $n$.

  *Proof.* The window holds $W$ tagged cells and at most $W$ acknowledgement
  sets of size $O(M)$. Phase one, catch-up, effects, and pending writes hold at
  most $O(R)$ records plus member metadata. All older values reside in
  segments or materialized state. Therefore memory is
  $O(W dot ("sizeof"("Value") + M) + R dot "sizeof"("Record") + M)$, with no $n$ term.
  $square$
])

#claim([Theorem 4], [Routine reclamation is database-size independent], violet, [
  Excluding exceptional state transfer, the work to rotate and trim a journal
  segment does not depend on SQLite database size $D$.

  *Proof.* Rotation writes one bounded trailer, sparse index, manifest, and
  active header. Trimming persists one bounded anchor/certificate and unlinks
  complete segment files plus unreachable payloads. No operation reads,
  copies, or hashes `current.db`. Its work is $O("records_in_segment")$ when
  sealing or $O("segments_deleted" + "payloads_reclaimed")$ when trimming, with no
  $D$ term. $square$
])

== Conditional liveness

#claim([Theorem 5], [Progress under bounded lag], amber, [
  If a stable leader communicates with a healthy write quorum, durable storage
  eventually completes, application throughput eventually exceeds offered
  write throughput, and the configured windows admit at least one new slot,
  then commands continue to be chosen without snapshot rollover.

  *Argument.* Stable Multi-Paxos chooses each proposed slot. Eventual
  persistence and application advance $P$, $C$, and $A$. Their advance frees
  tagged cells and eventually enables soft trim or a valid hard-trim
  certificate. No transition requires copying the database. As usual, this is
  conditional liveness: permanent overload or exhausted storage invokes
  explicit backpressure rather than unsafe deletion. $square$
])

= Durable and Wire Formats

This change is format-breaking and must be versioned as one coherent feature.

#table(
  columns: (1.2fr, 0.6fr, 0.6fr, 2fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 6pt,
  table.header([*Boundary*], [*Old*], [*New*], [*Reason*]),
  [Paxos slot], [`u32`], [`u64`], [Global non-resetting instance number.],
  [Wire protocol], [`8`], [`9`], [64-bit slots, range promises, trim and
    readiness messages.],
  [Journal], [`1`], [`2`], [Segment headers, absolute ranges, digest chain,
    sparse index, and trim anchor.],
  [Applied state], [implicit], [`ZXAP` v1], [Crash-safe SQLite recovery
    frontier.],
  [Checkpoint proof], [`ZXP2`], [`ZXP3`], [Global anchor, state-transfer slot,
    trim certificate digest, and 64-bit fields.],
  [Snapshot manifest], [`1`], [`2`], [State transfer rather than epoch reset;
    global slot and history anchor.],
)

All integer encodings are canonical little endian. Decoders reject unknown
versions, non-canonical ranges, integer overflow, slot zero where prohibited,
and anchors beyond a locally proven chosen frontier. Wire version remains
exact-major after activation.

= API Changes

The core's conceptual options become:

```zig
pub const Options = struct {
    max_members: usize = 9,
    window_slots: usize = 4096,
    recovery_chunk_slots: usize = 256,
    max_batch: usize = 16,
};
```

The core adds host-owned progress callbacks or explicit inputs:

```zig
advanceMemoryFloor(through: Slot) !void
installTrimAnchor(anchor: TrimAnchor) !void
beginRecovery(anchor: TrimAnchor) !void
requestRange(peer: MemberId, first: Slot, count: u32, effects: *Effects) !void
```

`decidedThrough()`, proposal results, effects, promises, catches-up, learner
messages, status, C ABI surfaces, and client JSON widen slots to `u64`.
Historical random access below the memory floor moves out of the core into the
host journal API. A call for an unavailable old slot returns `Trimmed` with the
current anchor; it never indexes a reused cell.

= Specific Change Surface

The expected implementation touches approximately 30 to 40 files. Eight to
ten contain substantial algorithm or storage work; the rest are format,
tests, benchmark, status, and documentation propagation. This estimate is a
review aid, not permission to broaden implementation silently.

#block(width: 100%)[
  #table(
    columns: (1.45fr, 2.35fr),
    stroke: 0.5pt + rgb("d7dee8"),
    inset: 6pt,
    table.header([*File or area*], [*Required change*]),
    [`src/protocol.zig`],
    [Widen `Slot`; replace lifetime arrays and bit sets with tagged window
      cells; bound phase one and effects; add anchor/range validation and
      transient window backpressure.],
    [`src/replicated_log.zig`],
    [Replace `max_entries` lifetime semantics with window semantics; retain
      stop signs only for membership; expose memory-floor and trim-anchor
      integration.],
    [`src/learner.zig`],
    [Use a tagged delivery window and absolute released/applied frontiers.],
    [`src/host_managed.zig`, `src/root.zig`, `src/errors.zig`],
    [Export `u64` slots and new host contract; distinguish `WindowFull`,
      `Trimmed`, anchor mismatch, and true exhaustion.],
    [`zaxonlite/src/types.zig`],
    [Replace `max_entries = 2048` with consensus-window, recovery-chunk,
      segment, and retention-budget options.],
    [`zaxonlite/src/journal.zig`],
    [Implement journal v2 segments, active recovery, sparse index, digest
      chain, manifests, atomic rotation, and safe segment deletion.],
    [`zaxonlite/src/applied_anchor.zig` (new)],
    [Canonical alternating `ZXAP` records, generation selection, geometry and
      history verification, and durable publication.],
    [`zaxonlite/src/trim.zig` (new)],
    [Frontier observation, readiness validation, trim-certificate encoding,
      policy, and idempotent durable trim state.],
    [`zaxonlite/src/node.zig`],
    [Remove capacity-triggered snapshot rollover; maintain global frontiers
      and history anchor; apply/persist ordering; range recovery; trim and
      payload-GC orchestration; on-demand state transfer.],
    [`zaxonlite/src/wal.zig`],
    [Document and enforce the page-write/apply-anchor durability order while
      preserving deterministic exact-page replay.],
    [`zaxonlite/src/checkpoint_proof.zig`],
    [Add proof v3 for global state-transfer anchors and recovery-holder
      evidence; retain strict database and registry binding.],
    [`zaxonlite/src/payload_store.zig`],
    [Move reachability from epoch journals to retained segment manifests and
      active transfer leases.],
    [`zaxonlite/src/wire.zig`],
    [Protocol v9; widen every slot; add bounded range, applied-frontier,
      readiness, trim-certificate, and transfer-anchor frames.],
    [`zaxonlite/src/server.zig`, `client.zig`, `main.zig`, `cli/render.zig`],
    [Propagate 64-bit status and errors; expose global slot, trim, retained
      range, apply lag, segment bytes, and transfer state.],
    [`zaxonlite/src/*test.zig`, `src/*test coverage`, `sim/`, `specs/`],
    [Replace reset-based expectations; add long-run, wraparound, trim, crash,
      transfer, reconfiguration, corruption, and model-based coverage.],
    [`benchmarks/benchmark.zig`, durable and zaxonlite benchmarks],
    [Measure a moving window over millions of slots, segment boundaries,
      trimming, lag, and database-size-independent tail latency.],
    [`docs`, ZDS 0002/0004/0008 amendments, release notes],
    [Describe the new limits and formats only after acceptance and
      implementation. Existing committed records are not edited by this
      prediscussion draft.],
  )
]

= Migration and Rollout

Migration is deliberately one-way after the first v2 journal command.

== Bridge release

A bridge binary reads journal v1, proof v2, and wire v8, but writes them until
cluster activation. It also understands the new files while voting only in
one mode at a time. Operators first upgrade every voter to the bridge release
and verify identical database ID, configuration, applied slot, chain, and
logical integrity.

== One-time global genesis

The cluster quiesces writes and completes one final old-format checkpoint.
That verified checkpoint becomes global anchor slot zero:

$ H_0' = "SHA256"("zaxon-global-migration-v1" || "database_id" || "old_proof_digest" || "old_state_digest") $

The bridge writes journal v2 genesis, `APPLIED` at zero, and a v2 manifest.
This one-time migration may copy and hash the database. It is an upgrade cost,
not a recurring write-count cost.

== Activation

The old configuration chooses a version-activation stop record bound to the
genesis digest. All voters atomically install the new generation, switch to
wire v9, and allocate global slot one. Mixed v8/v9 voting is forbidden after
activation. An old binary fails closed.

Rollback is allowed only before activation. After global slot one is chosen,
rollback requires restoring the pre-activation checkpoint and would discard
new writes; it is therefore a disaster-recovery action, not an ordinary
downgrade.

== Implementation stages

1. Add `u64` slot types, tagged windows, and property tests behind an
   experimental core option.
2. Add journal v2, applied anchors, and replay equivalence without trimming.
3. Add soft trim and segment/payload reclamation.
4. Add state-transfer recovery behind retained range.
5. Add hard-trim certificates and membership interaction.
6. Add bridge migration and format conformance tests.
7. Run formal, crash, long-duration, and performance gates.
8. Remove the old capacity rollover only after the new recovery path passes
   every gate.

= Verification Plan

== Formal model

Add `specs/GlobalTrim.tla` and a TLC configuration for $N in {3, 5}$ with
small windows $W in {2, 3}$ so reuse is exercised frequently. Model:

- Paxos promises, accepts, choice, and leader change;
- global slot allocation and tagged cell reuse;
- persisted, chosen, applied, and trim frontiers;
- soft and hard trim;
- crashes between every durability step;
- local replay and state transfer;
- one membership transition; and
- witness versus data-replica roles.

Check these invariants:

```text
Agreement
ChosenPrefix
TagNonAliasing
TrimNeverExceedsCertifiedAnchor
AppliedNeverExceedsDurablePages
RecoveryReadyImpliesExactPrefix
NoWitnessClaimsMaterializedState
GlobalSlotNeverDecreases
```

The model must include an action-to-code map in `specs/README.md`. Safety is
checked without fairness. Conditional liveness checks weak fairness only for
message delivery and successful durable writes.

== Deterministic and property tests

- run at least ten million global slots with a tiny $W$ and prove bounded RSS;
- force physical-cell wrap on every few proposals and compare against an
  unbounded reference model;
- split phase-one replies at every chunk boundary and reorder chunks;
- inject gaps, duplicates, stale tags, stale trim IDs, conflicting anchors,
  and near-`u64` overflow;
- compare in-memory continuation with crash/restart at every segment rotation;
- vary data voters and witnesses and reject witness-only trim certificates;
- perform membership change without resetting the global slot;
- retain and reclaim payloads across shared segment references;
- verify old-history API calls return `Trimmed`, never a newer value.

== Crash matrix

Crash before and after each of:

1. payload persistence;
2. chosen journal persistence;
3. page-image write;
4. database durability barrier;
5. inactive `APPLIED` write;
6. applied-anchor barrier;
7. segment trailer write and sync;
8. manifest generation and pointer publication;
9. readiness persistence and transmission;
10. trim choice;
11. local `TRIM` persistence;
12. segment unlink and directory sync;
13. payload reachability publication and unlink;
14. state-transfer begin, every chunk, end digest, install rename, and
    receiver acknowledgement.

Every restart must either expose the previous complete generation or the next
complete generation. It must never vote with a gap, an unverified image, or an
anchor newer than durable page state.

== Performance gates

Compare on the same host, power profile, Zig version, and commit, using at
least 30 independent samples and confidence intervals.

- Stable-leader `u64-3n` median nanoseconds per value should regress no more
  than 5% from the frozen pre-change baseline unless review explicitly accepts
  a measured trade-off.
- The number of steady-state durability barriers per committed group must not
  increase.
- Throughput and p99 are measured across at least one million slots and many
  physical-window wraps, not only a fresh first window.
- Segment rotation p99 must remain independent of SQLite database size within
  measurement noise.
- Runs use at least 1 MB, 1 GB, and a sparse or generated large database; no
  normal-path event may read or copy the full database.
- A lagging replica is tested within the retained suffix and behind the trim
  frontier. Only the latter may pay full state-transfer cost.
- RSS is measured at 10 thousand, 1 million, and 10 million chosen slots and
  must remain within the configured window plus allocator tolerance.

The current benchmark that executes only 1,000 measured zaxonlite operations
cannot validate this design because it never reaches the existing rollover.
It remains useful for request-path comparison but is not a compaction test.

= Security Considerations

Trim certificates influence recoverability and therefore require the same
authenticated peer identity and configuration binding as consensus traffic.
A stale voter, learner, gateway, or witness cannot claim materialized state.
Duplicate holder IDs count once.

History hashes and segment hashes detect accidental corruption and bind
protocol evidence. They do not turn crash-fault Paxos into Byzantine Paxos.
A malicious quorum can still certify false state; protecting against that
requires a different fault model and is out of scope.

State transfer exposes the database contents. Production transfer remains
inside mutually authenticated TLS, validates database and registry identity,
enforces chunk and total-size bounds, and writes only beneath a newly created
temporary generation. Paths from remote metadata are never used directly.

Resource exhaustion is bounded. Range requests, promises, certificate holder
lists, sparse indexes, manifests, transfer chunks, and outstanding leases all
have explicit limits. Invalid anchors, overlapping ranges, decompression
bombs, integer overflow, or excessive retries close the peer request and
increment structured diagnostics.

Deletion follows least authority. The trim subsystem receives explicit opened
directory handles and validated segment identities. It never constructs a
recursive deletion target from network input.

= Operational Considerations

Status adds:

```text
global_decided_slot
global_applied_slot
memory_floor
trimmed_through
retained_first_slot
retained_last_slot
journal_segment_count
journal_bytes
apply_lag_slots
trim_mode
recovery_holders_ready
state_transfer_phase
```

Alerts distinguish consensus unavailability, apply lag, retention pressure,
and unavailable recovery quorum. A slow replica first delays soft trim. It
does not force a snapshot. Near the disk budget, the leader attempts state
repair and hard-trim certification. If neither is safe, writes stop before
storage exhaustion with a stable operator error.

Operators choose retention by bytes and minimum time, not by total database
size. Defaults should preserve enough suffix for routine outages while
limiting disk amplification. Segment size is a performance parameter, never a
safety parameter.

Backups remain necessary. Consensus replication protects availability, not
operator deletion, correlated storage loss, or application-level corruption.
External backup does not automatically count as a live recovery holder unless
configured and continuously verified under the hard-trim policy.

= Expected Benchmark Effects

The core hot path adds a 64-bit tag comparison and absolute-index arithmetic.
Power-of-two masking avoids division. Clearing an entire 2,048-slot epoch and
same-member election disappear. Bounded phase one may use more messages after
a long leader outage, but each frame is smaller and bounded.

Zaxonlite adds applied-anchor maintenance. The design groups its publication
with the existing durability barrier; it must not add one full filesystem
barrier per write. Segment trailers and manifests add occasional small writes.

Expected qualitative effects are:

#table(
  columns: (1.3fr, 1.2fr, 1.2fr, 1.5fr),
  stroke: 0.5pt + rgb("d7dee8"),
  inset: 6pt,
  table.header([*Workload*], [*Current*], [*Proposed*], [*Risk*]),
  [Fresh-window core], [Very fast fixed arrays], [Tag check and `u64` slots],
    [Small constant regression to measure.],
  [Long-running core], [Stops at bound], [Constant-memory continuation],
    [Chunk recovery complexity.],
  [Routine reclamation], [Full DB copy/hash], [Segment metadata/unlink],
    [Filesystem directory latency.],
  [Lag within retention], [Epoch-specific recovery], [Range suffix],
    [More wire states.],
  [Lag beyond retention], [Snapshot generation], [On-demand state transfer],
    [Rare cost remains $Theta(D)$.],
  [Membership change], [Snapshot + slot reset], [Transfer if needed; slots continue],
    [Cross-config proof complexity.],
)

No claim of improvement is accepted without the verification workload above.
The mathematical result is narrower but firm: normal reclamation removes the
unavoidable $D/E$ term. Actual constants remain device and implementation
properties.

= Alternatives Considered

== Raise `max_entries`

This postpones exhaustion and increases static memory. It preserves the
database-size-dependent rollover term and remains a lifetime limit.

== Scale epoch size with database size

This can keep amortized copy cost below a target, but makes memory and recovery
bounds dynamic, still copies the database periodically, and couples unrelated
dimensions. It is a mitigation, not a separation of concerns.

== Reflink or copy-on-write snapshots

Filesystem clones can make the initial copy cheap, but are platform-dependent.
Hashing, later copy-on-write amplification, snapshot retention, and the fixed
slot bound remain. Reflinks are valuable for optional state transfer staging,
not the consensus abstraction.

== Incremental or Merkle-page snapshots

Changed-page snapshots reduce transfer bytes and may be added later. They do
not by themselves make a finite Paxos array unbounded. The proposed global
slot and trimming model is still required.

== Soft trim only

Trimming at the minimum applied frontier of every data replica is simple and
safe, and it is the first implementation stage. It allows one permanently
offline replica to retain the log indefinitely. Hard trim with explicit state
holders is needed for bounded storage under failure.

== Quorum trim without state-holder evidence

A Paxos quorum can prove a log decision, but a witness quorum may not contain a
SQLite image. Deleting the only commands needed to reconstruct application
state would preserve abstract agreement while destroying recoverability. The
proposal separates vote quorum from recovery-holder quorum.

== ARIES-style physiological redo as the consensus algorithm

ARIES provides excellent recovery principles—monotonic LSNs, write-ahead
logging, checkpoints, and repeating history—but it does not replace distributed
agreement. This design adopts those separation principles while Paxos remains
the authority for chosen order.

== Replace Paxos with Raft

Raft also requires snapshots or log compaction and a bounded implementation.
Changing the consensus family does not remove the storage-layer problem and
would discard the existing verified core. The required change is compatible
with Multi-Paxos.

== Matchmaker Paxos, Delos, or disaggregated log storage

Matchmaker Paxos improves reconfiguration; Delos composes virtual consensus
logs; Aurora separates database compute from replicated storage. Each offers
useful future directions, especially for elastic membership or remote
archives. None is required to fix the local slot lifetime and routine snapshot
tax. This record chooses the smallest architecture that establishes clean
boundaries now.

= Open Questions

- What default consensus window and recovery chunk minimize cache pressure
  without constraining the writer pipeline?
- Should hard trim ship in the first release, or should production initially
  use soft trim plus an operator disk budget?
- Can an external object store count as one recovery holder, and what ongoing
  verification and failure-domain rules are required?
- Should state transfer initially use SQLite online backup only, or also a
  reflink fast path after identical semantic validation?
- What segment byte size and sparse-index stride provide the best balance for
  SSD sequential IO and range recovery?
- Can the applied anchor share the current journal barrier on every supported
  filesystem without weakening the ZDS 0006 durability contract?
- Does the C ABI change in place before 1.0, or introduce suffixed `u64` slot
  functions for source compatibility?
- What exact normalized benchmark threshold should gate merge on CI hosts with
  noisy storage?
- Should historical audit retention be a separate archive policy above the
  minimum recovery suffix?

= Acceptance Criteria

- At least ten million decisions complete in one database and one unchanged
  configuration with no snapshot rollover and no slot reset.
- Consensus RSS remains bounded by configured windows within measured
  allocator tolerance.
- No two values are chosen for one slot in the formal model or deterministic
  simulation.
- A crash at every specified failpoint recovers the exact chosen SQLite prefix
  or refuses to vote.
- Soft trim never advances past the minimum durable applied frontier.
- Hard trim never advances without $f + 1$ valid independent state-holder
  attestations for one anchor.
- A witness alone never satisfies state recoverability.
- Segment and payload deletion cannot remove a retained reference.
- Membership change preserves monotonically increasing global slots.
- Routine segment rotation and trimming perform no full database copy or full
  database hash.
- A replica within retention uses range recovery; a replica behind trim uses
  verified state transfer and suffix replay.
- Wire and durable decoders reject old/new ambiguity and corrupted anchors.
- Stable-leader core performance meets the reviewed regression gate, and
  long-run p99 contains no database-size-correlated rollover spike.
- ZDS 0004's format contract and ZDS 0008's membership contract receive
  explicit amendments when this record is accepted; they are not silently
  contradicted.

= References

- Leslie Lamport, “The Part-Time Parliament” and “Paxos Made Simple” — the
  quorum and agreement foundation:
  `https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf`
- Robbert van Renesse and Deniz Altinbuken, “Paxos Made Moderately Complex” —
  operational Multi-Paxos structure:
  `https://www.cs.cornell.edu/courses/cs7412/2011sp/paxos.pdf`
- William Schultz et al., “MultiPaxos Made Complete” — explicit complete-log
  implementation, trimming, and recovery considerations:
  `https://arxiv.org/abs/2405.11183`
- Tushar Chandra, Robert Griesemer, and Joshua Redstone, “Paxos Made Live” —
  the gap between protocol and production system:
  `https://research.google/pubs/paxos-made-live-an-engineering-perspective/`
- C. Mohan et al., “ARIES: A Transaction Recovery Method Supporting Fine-
  Granularity Locking and Partial Rollbacks Using Write-Ahead Logging” — LSN,
  repeating-history, and checkpoint separation:
  `https://www.cs.cmu.edu/~15849g/readings/mohan92.pdf`
- Diego Ongaro, “Consensus: Bridging Theory and Practice” — log compaction,
  snapshots, membership, and implementation proof obligations:
  `https://github.com/ongardie/dissertation/raw/master/stanford.pdf`
- James C. Corbett et al., “Spanner: Google's Globally-Distributed Database” —
  replicated state machines composed with storage and reconfiguration:
  `https://research.google/pubs/spanner-googles-globally-distributed-database/`
- Mostafa Elhemali et al., “Amazon DynamoDB: A Scalable, Predictably
  Performant, and Fully Managed NoSQL Database Service” — production
  replication, storage nodes, repair, and operational isolation:
  `https://www.usenix.org/conference/atc22/presentation/elhemali`
- Alexandre Verbitski et al., “Amazon Aurora: Design Considerations for High
  Throughput Cloud-Native Relational Databases” — separation of database and
  replicated storage recovery:
  `https://www.amazon.science/publications/amazon-aurora-design-considerations-for-high-throughput-cloud-native-relational-databases`
- Mahesh Balakrishnan et al., “Virtual Consensus in Delos” — composable log
  abstraction and reconfiguration:
  `https://www.usenix.org/conference/osdi20/presentation/balakrishnan`
- Michael Whittaker et al., “Matchmaker Paxos” — reconfiguration without fixed
  configuration sequencing assumptions:
  `https://arxiv.org/abs/2007.09468`
- SQLite, “Write-Ahead Logging” and “Online Backup API” — local page-state and
  consistent transfer mechanisms:
  `https://www.sqlite.org/wal.html`, `https://www.sqlite.org/backup.html`
- `docs/zds/records/0001-zds-process.typ` — lifecycle and authoring rules
- `docs/zds/records/0002-zaxonlite-product-plan.typ` — product architecture
- `docs/zds/records/0004-zaxonlite-format.typ` — current format contract
- `docs/zds/records/0008-zaxonlite-voter-replacement.typ` — membership and
  checkpoint transition contract
- `src/protocol.zig`, `src/replicated_log.zig`, `src/learner.zig` — current
  bounded consensus representation
- `zaxonlite/src/node.zig`, `journal.zig`, `wal.zig`, `payload_store.zig`, and
  `checkpoint_proof.zig` — current rollover, persistence, and recovery boundary
