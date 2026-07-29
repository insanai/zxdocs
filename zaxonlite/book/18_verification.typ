#import "theme.typ": *
#import "figures.typ": *

= Verification

#objectives([
  By the end of this chapter you should be able to name each test layer
  and the question it answers, follow the mandatory cluster scenario
  step by step, point at the enforcement and the oracle for every
  persistence assertion, read the benchmark dashboard against rqlite
  without being misled by it, and state which claims this release does
  not verify.
])

#checkpoint([recovery and read levels], [
  This chapter leans on chapter 6 for the recovery sequence, and on
  chapter 8 for the crash matrix and read levels. The benchmark
  section uses both without re-deriving them.
])

A guarantee without a test is a claim. This book has made many
guarantees, and this chapter is where we pay for them. We verify
Zaxonlite in layers, in the same order we built it: bytes first, then
one process, then three processes, then hostile networks, then time
and load. Each layer has its own suite and its own oracle. The last
sections measure the finished product against rqlite and say plainly
what those numbers mean. Chapter 18 then closes the book by tracing
every guarantee to its code and its oracle.

== The test layers

Each suite exists to answer one question that the suites below it
cannot. A unit test cannot prove that three real processes elect a
leader. A cluster test cannot pin the exact bytes of a torn journal
tail. So we keep both, and everything between.

#table(
  columns: (auto, 1fr, auto),
  table.header([*Layer*], [*The question it answers*], [*Command*]),
  [Unit], [Do the codecs, chain hashes, journal replay, torn tails,
    payload-store faults, and the WAL capture spike behave at the byte
    level?], [`zig build test`],
  [Single process], [Does one real node survive restart, rebuild a
    deleted or stale image, expire sessions, roll snapshots, and
    isolate failed SQL?], [`zig build test-single`],
  [Crash points], [When a real process dies at each write-pipeline
    failpoint, does recovery ever invent a false success?],
    [`zig build test-crash`],
  [Cluster], [Do three real processes elect, fail over, catch up,
    transfer snapshots, and survive a total restart? The full script
    follows below.], [`zig build test-cluster`],
  [Roles], [Do the witness, standby, and read replica obey their read
    restrictions and bounded-freshness refusals?],
    [`zig build test-roles`],
  [Replacement], [Does a three-voter mTLS cluster survive a decided
    one-for-one voter replacement, with admin refusals, a crash inside
    the swap, idempotent retry, and quorum with the new voter? The full
    script follows below.], [`zig build test-replace-cluster`],
  [Gateway], [Does authenticated RPC pass end to end through a process
    that holds no Paxos or SQLite state?], [`zig build test-gateway`],
  [Adverse network], [Does the cluster stay correct under real TCP
    loss, duplication, reordering, seven-byte fragmentation, and
    delayed durable sync?], [`zig build test-fault-network`],
  [CLI contract], [Do exit codes, JSON shapes, session flags, the
    scripted shell, locking, loopback-only development PSK, startup/leader
    logs, enrollment/revocation, and single-seed mTLS redirects match the
    reference?],
    [`zig build test-cli`],
  [C ABI], [Does every exported function work, including locking and
    replay after reopen?], [`zig build test-cabi`],
  [Fuzz], [Do seeded random bytes break the decoders, the journal
    files, or a whole node under random SQL, crashes, and a
    rebuild-convergence oracle?], [`zig build fuzz`],
  [Soak], [Does sustained mixed load, with restarts and snapshots,
    ever drift from a live row-count model?], [`zig build soak`],
  [Benchmark], [What do writes, reads, recovery, and rebuild cost in
    ReleaseFast on this machine?], [`zig build benchmark`],
  [Cluster benchmark], [What do replicated writes and reads cost across
    three real server processes, in test-only plaintext, development PSK,
    and mTLS transport modes?], [`zig build bench-cluster`],
)

Beneath all of these, the paxos-zig library carries its own gates. Its
`zig build test` includes an effect-order misuse matrix: fixture processes
that read messages or reset a batch before confirming durability must abort
with a stable diagnostic in Debug, ReleaseSafe, ReleaseFast, and
ReleaseSmall, and invalid compile-time options must fail compilation.
Zaxonlite's write path relies on that contract; the matrix proves the
contract holds in the optimize modes Zaxonlite actually ships. The library
also carries the replacement's consensus-level evidence: changed-member
rollover unit tests, and a one-for-one replacement simulation in
`sim/reconfiguration.zig` that drives sixteen seeded schedules through
drop, duplication, and reordering with a restart oracle. A bounded TLA+
host model, `specs/VoterReplacement.tla`, sits beside `specs/Paxos.tla` as
the host-level model of the replacement's stop-sign and activation steps.

`zig build test-cluster -Dcluster-runs=N` repeats the whole cluster
scenario for flake hunting. One hundred consecutive runs are an
explicitly deferred CI gate, not a result this release claims. The
rqlite and dqlite comparison harnesses are scripts under
`zaxonlite/benchmarks/`, not build steps. They appear in the measured
section below.

== The mandatory cluster scenario

The cluster suite is a controller that spawns three real `zaxon serve`
processes on loopback ports. It drives them only through the public
RPC protocol. There is no test back door into node internals. If the
public surface cannot observe a behavior, the test may not rely on it
either. Every wait is a deadline on an observable status field. On
failure the controller dumps all three statuses and log tails, because
a distributed test that hides its state teaches nothing.

The scenario strings together every failure that chapters 6 and 7
promised to survive, in one run:

#transcript((
  [1], [Controller], [Waits for an election, then creates the
    schema.],
  [2], [Controller], [Submits writes 1--100 through all three
    endpoints. Half travel inside a session, half without.],
  [3], [Oracle], [A linearizable count must see exactly 100 rows.],
  [4], [Controller], [Stops one follower, writes 101--150 on the
    surviving quorum, restarts the follower, and waits for
    catch-up.],
  [5], [Oracle], [Chain and content digests must be identical on all
    three members.],
  [6], [Controller], [Arms the leader's `before_client_reply`
    failpoint and submits a session write. The leader dies after
    quorum choice, before it can reply.],
  [7], [Controller], [Retries the same session sequence at the new
    leader.],
  [8], [Oracle], [The retried write must be applied exactly once.],
  [9], [Controller], [Rolls the epoch while another member is
    stopped. The member must rejoin through a snapshot transfer.],
  [10], [Controller], [Deletes one member's `current.db`. The member
    must rebuild it from snapshot plus committed suffix.],
  [11], [Controller], [Kills all three processes without ceremony,
    then restarts all of them.],
  [12], [Oracle], [153 rows, the failpoint row exactly once, clean
    integrity, and identical digests on every member.],
))

Step 6 is the heart of the script. It manufactures the exact ambiguity
that sessions exist for: the write was decided, the client never heard
so. The retry in step 7 must not apply twice, and step 12 checks that
it did not, even after every process has since been killed.

== The replacement cluster scenario

`zig build test-replace-cluster` runs the same controller discipline
against the decided voter replacement: three real mTLS voters, driven
only through the public surface, every wait a deadline on an observable
field. The scenario strings together the failures chapter 13's runbook
promises to survive:

#transcript((
  [1], [Controller], [Starts three mTLS voters with a decided registry
    and an admin allow-list, writes rows, and waits for a leader.],
  [2], [Oracle], [A `replace-voter` request under a node certificate,
    and one under an unlisted admin name, must both be refused.],
  [3], [Controller], [Holds one client TCP connection open. It crashes
    the leader after durable proposal submission, restarts it, and retries
    the same request under the listed admin certificate.],
  [4], [Controller], [One survivor, started with the
    `before_transport_swap` failpoint armed, dies inside the in-process
    swap. The controller restarts it.],
  [5], [Oracle], [The restarted survivor must converge to the new
    configuration, and the held client connection must still answer.],
  [6], [Controller], [Retries the same operation ID, then submits a
    conflicting request reusing a retained operation ID.],
  [7], [Oracle], [The retry replays the recorded outcome; the
    conflicting reuse is rejected.],
  [8], [Controller], [Restarts the replaced voter with its old flags,
    and restarts a survivor with stale flags naming it.],
  [9], [Oracle], [The replaced voter stays sealed on its final
    configuration and is refused admission. The stale-flag survivor uses
    the decided registry and converges to the new configuration.],
  [10], [Controller], [Enrolls the replacement: token issuance, `enroll`
    with a join descriptor, then `serve`. The node fetches and verifies
    the registry blob and installs its snapshot.],
  [11], [Oracle], [Every member's registry digest is identical after
    restart, and stopping one survivor still leaves a quorum, with the
    replacement voting.],
))

Around the scenario sit the byte-level suites. The registry module's unit
tests pin the canonical encoding as stable across input order, reject
corruption, hold the allocation fence and ring monotonic, replay an
idempotent retry, refuse `OperationHistoryExpired` and
`OperationIdExhausted`, and enforce the three-voter floor. A unit test
pins sealed-set quorum counting: confirmation counts distinct voters of
the sealed set only, and the proposed next voter never counts toward its
own admission. Integration crash-window tests kill the process inside the
rollover write order (snapshot proof, `CURRENT`, `REGISTRY`, identity)
and require bootstrap to re-run when the pointer write is missing,
recovery to roll `REGISTRY` and identity forward together, and a corrupt
pointer to fail closed.

== Persistence assertions, mapped

Chapter 8's crash matrix and the product plan's persistence assertions
each name an enforcement point and an oracle. This table is the map
between them.

#table(
  columns: (1fr, 1.6fr),
  table.header([*Assertion*], [*Enforced and checked by*]),
  [Chain equality across members.], [The cluster scenario compares
    chain and content digests on all three members after every
    recovery arc.],
  [Contiguous monotone apply.], [Commit accounting inside the node
    permits no gap and no reorder in applied slots.],
  [Acknowledged writes survive single-node loss and total restart.],
    [The cluster scenario kills a follower, then the leader, then
    every process, and counts every acknowledged row afterward.],
  [At-most-once session sequences.], [The single-process, CLI, and
    C ABI suites, plus the cluster failpoint arc in steps 6 to 8
    above.],
  [Payload durable before any vote references it.], [Transport gating
    holds value-bearing frames until the payload is stored; the
    payload-store fault tests cover corruption and loss.],
  [Journal sync before any message leaves.], [The ordering is
    structural: the journal fsync runs before the outbox drains.],
  [Refusal on missing durable state.], [The corrupt-journal and
    missing-payload tests require the node to refuse to serve or
    vote.],
  [Torn tail truncated, interior corruption fatal.], [The journal
    unit tests and the seeded journal fuzzer discriminate the two
    cases.],
  [Quorum loss blocks acknowledgement.], [The two-members-down drill
    must refuse writes and fenced reads.],
)

== The three-node transport benchmark

`zig build bench-cluster -- [--sync os|full] <plaintext|psk|tls>
[writes] [reads]` runs the harness in `zaxonlite/src/cluster_bench.zig`.
It spawns three ReleaseFast `zaxon serve` processes on loopback ports in
the named transport and sync mode, waits for a leader, then drives
sequential replicated writes followed by `leader` and `linearizable`
reads over one persistent client connection to the leader — the shape
of an embedded client, not a pipelined load generator. Every response
is verified before it counts; a request the node declines (for example
after a leadership move) is retried through the configured endpoint
list, and the retry stays in that operation's latency sample. It
reports ops/s with p50, p95, p99, and max latency per workload, plus
each server process's RSS and CPU delta across the run. The defaults
are 1000 writes and 2000 reads. In `tls` mode the harness generates a
throwaway CA and per-node `zaxon-node-<id>` certificates with the
`openssl` CLI, so the three processes exercise the real mutual-TLS peer
and client paths.

The build step always passes `--record
benchmarks/results/transport-latest.json`, so every run replaces its
mode-and-sync row in that file, and the table below is read from it
when this book compiles — the same contract as the rqlite dashboard:
the compiled book always shows the last recorded runs, never a number
copied into prose. The current write row uses a fixed 256-byte value.

#transport_bench_table()

Two lines dominate this table. Across transport modes the write row
barely moves, because a sequential replicated write is dominated by
quorum fsyncs and the mTLS cost disappears inside them; the read rows
show encryption's real price on this host — a few microseconds at p50
and a throughput cost under about 16% — plus roughly 5–6 MiB of
additional RSS per node for OpenSSL state. Across *sync* modes the
write row moves by more than an order of magnitude: `full` issues one
`F_FULLFSYNC` per commit point on macOS — the payload install flushes
to the drive and the journal sync is the single drive-cache barrier
that makes both power-loss durable — while `os` trusts `fsync(2)` and
the drive cache. The write latency under `full` is therefore two
barriers overlap: an ordered stream queues `payload_data` immediately before
the phase-two accept, the receiver installs it before stepping the accept,
and the leader holds its node mutex until its own vote barrier completes.
Thus neither a volatile local vote nor an unstored payload can count, while
the two devices do useful work concurrently. Reads never touch
the journal, so their rows are indifferent to the sync mode. Sustained
`full`-mode
writes can also stall the leader's tick loop long enough to move
leadership — visible as occasional large maxima — which is exactly the
behavior an operator should expect from a workload that saturates a
full-flush storage budget.

== Measured against rqlite

Benchmarks are the easiest place for a book to lie, so this dashboard
states its scope before it shows a number.

#bench_boxes()

Every number in the two tables below is read from recorded result
files under `zaxonlite/benchmarks/results/` when the book is built.
We never copy a measured number into prose. If prose and table ever
disagreed, the table would be right.

=== One-row durable writes

The first comparison is deliberately narrow. Each system runs alone as
three voters on loopback with durable node directories. One client
issues single-row autocommit inserts, sequentially, over one
persistent connection, with the same payload size for both systems.
Warmup writes are excluded from timing. rqlite's queued-write mode
stays off, because it acknowledges before durability and that would be
a different contract.

This is a product-level comparison, not a consensus microbenchmark.
Each system is timed through its own front door. The Zaxonlite driver
speaks the framed binary RPC from chapter 12 and follows `not_leader`
redirects until it holds a connection to the leader. The rqlite driver
speaks HTTP to a node, and that node forwards each write to its
leader. Writes reach the leader in both systems, but the path there
includes each product's parsing, scheduling, fsync policy, and storage
layout. After timing, the driver verifies the data: a strong count and
an exact-payload predicate must both equal the number of acknowledged
writes. Zaxonlite answers that barrier at level `linearizable`;
rqlite answers it at its `strong` level.

#bench_write_table()

Read the columns in order. The p50 column is the typical cost of one
acknowledged durable write through the full product pipeline, and it
is the most portable column. The p95 and p99 columns show how wide the
tail is. The max column records the single worst write of the run; one
scheduler stall can own it, so never quote it alone. The gap between
the rows is a product gap. Front ends, durability scheduling, and
storage layouts differ by design, and the table cannot attribute its
gap to any single one of them. It is not evidence about Paxos versus
Raft, and it is not evidence about languages.

The recorded baseline pins the sync contract: both systems flush the
drive's cache on every acknowledged write — Zaxonlite's default `full`
mode issues `F_FULLFSYNC` on macOS, exactly as Go's file sync does for
rqlite. Group fsync already consolidates Zaxonlite's per-write flushes
to one barrier per node per commit point (the journal sync; payload
installs ride it — see chapter 6). The gap that remains is ordering:
Protocol v7 retains the v5 barrier overlap. Only phase-two accept requests are
released before the leader barrier; promises, accepted replies, recovered
values, commit delivery, and client replies remain behind durable evidence.
A commit-only local marker is derived from an already durable accepting quorum
and is reconstructed through phase one after a crash instead of forcing a
second full barrier. The table combines the current Zaxonlite mTLS/full row
with the pinned rqlite v10.2.7 baseline and labels them as separate executions
on the same host. A development
`--sync os` run on the same machine reverses the ranking at roughly a
tenfold lower write latency, but at the price of power-loss
durability; chapter 13 states when that trade is acceptable, and
chapter 6 states why a consensus voter must not make it silently.

=== Failure and recovery under a realistic workload

The second comparison stops treating the database as a write loop. It
is a deterministic order-processing simulation. Each system runs alone
as three voters seeded with 1,000 customers and 500 products, while
four concurrent clients spread across all endpoints. The traffic is
70% reads and 30% orders. Reads cover point inventory, customer
history, and a sales dashboard. An order is one SQLite transaction
whose trigger creates an order line, decrements stock, and records a
ledger entry, so every write exercises real relational work.

Two contract details matter. First, every write carries a unique
operation ID and uses `insert or ignore`, so a client can safely retry
an ambiguous response after a process dies. Second, measured reads use
each product's quorum-fence `linearizable` level. rqlite's `strong`
mode is reserved for the final verification barrier, because rqlite's
#link("https://rqlite.io/docs/api/read-consistency/")[read-consistency
guide] describes that mode as a testing tool which writes through
Raft, and recommends `linearizable` for production.

#predict([
  The run kills a follower in one phase and the leader in another.
  Which death costs more throughput, and why? Decide before the
  table.
])

After 100 untimed warmup operations, the controller runs three
400-operation phases. Phase one is healthy three-voter traffic. Phase
two sends `SIGKILL` to one follower, continues on the quorum, then
restarts the follower and waits until its local SQLite copy matches.
Phase three sends `SIGKILL` to the leader, begins traffic immediately
so the retries ride through the election, then restarts the old
leader and waits for its catch-up. Finally the controller kills all
three processes, restarts their original identities and data
directories, and checks every local copy.

#bench_realworld_table()

Walk the rows top to bottom. The healthy row is each product's mixed
throughput ceiling on this host. The follower-down row shows what a
quorum can still do with a member missing. The leader-killed row is
lower for both systems, and that answers the prediction: a dead
follower removes capacity, but a dead leader stalls every client
until an election finishes, so its phase carries the retry and
election cost inside its throughput. The crash-to-first-success row
isolates that outage: it is the gap a client actually experiences
between the kill and the next acknowledged operation. The two
catch-up rows measure how long a restarted member needs before its
local copy matches the cluster again. The full-restart row is the
cold path from three dead processes back to service.

The correctness line under the table is the reason the throughput
rows are worth reading at all. Both systems finished with the same
order count on every node, and the table's footer carries that count.
Order lines, ledger entries, inventory, and revenue matched on all
three nodes in both systems. No product ever showed negative stock,
and every SQLite integrity check came back clean. Zaxonlite
additionally passed its chain and payload-store verification. A
throughput table without those checks would be noise.

=== What these numbers are not

#callout(title: [Read the exclusions before quoting anything], tone: "warning")[
  Everything above ran on one development host, over loopback, in one
  recorded run per table, with one client in the write benchmark and
  four in the simulation, against default configurations and an
  unreleased `zaxon` build. These numbers are observations of that
  run. They are not portable claims, not service-latency predictions,
  and not verdicts about languages or consensus algorithms. Real
  networks, concurrent client fleets, and tuned deployments are all
  excluded.
]

Two omissions are deliberate. The initial rqlite bootstrap time is
not reported, because the manual join path sat out its default
three-second retry interval; charging a timer as if it were work
would be unfair. And the dqlite comparison is deferred entirely. Its
harness is committed at `benchmarks/compare-dqlite-3node.sh`, but
dqlite is supported on Linux, so no dqlite number appears anywhere in
this book until the script has run on a Linux host.

To reproduce, run `benchmarks/compare-rqlite-3node.sh` and
`benchmarks/compare-rqlite-realworld-3node.py`. Each writes JSON
under `benchmarks/results/`, and rebuilding the book re-renders the
dashboard from your run.

== The search gates

The multimodal search layer (ZDS 0009) adds five verification layers of
its own, each answering one question.

*Does the index state replicate exactly?* The byte-identical WAL oracle
in `zaxonlite/src/wal.zig` drives FTS5 external-content indexing, vec0
float and bit vector writes, updates and deletes through all three
representations, bounded `usermerge`/`merge` maintenance, and an
`optimize` compaction — then rebuilds the database from captured
payloads alone and compares every byte. The three-process cluster
scenario repeats the point end to end: a hybrid coarse-scan-plus-rerank
query must answer identically on the leader, both followers, and after
snapshot transfer and total restart.

*Is the SIMD real?* `zig build disasm-probe` emits the ReleaseFast
cosine kernel as an object file, and `benchmarks/verify-simd.sh` greps
its disassembly for packed float multiply/add instructions — NEON
`fmul/fadd .4s` on AArch64, `mulps/addps` on x86-64. A benchmark alone
is not accepted as proof. The pure kernels also cross-compile for the
whole vector target matrix (`zig build check-kernels`), including the
scalar fallbacks and wasm, and big-endian targets are rejected at
compile time.

*Are the formulas right?* The fusion and Welford contracts are
table-driven unit tests with no SQLite; the SQLite adapter tests then
run the ZDS record's RRF and DBSF example statements verbatim, plus
arity, NULL, and error-code conformance for every registered function.

*Is query memory bounded?* `zig build bench-search` records the SQLite
heap high-water mark at candidate counts 64, 512, and 4,096 over both a
2,048-row and an 8,192-row corpus: the mark follows the candidate
count and stays flat as the corpus quadruples. The same run records
scalar-versus-SIMD rerank throughput at dimensions 384 through 1,536
plus a non-multiple-of-four tail, the coarse-versus-float storage
ratio, and mmap-on/off query latency, SQLite page reads, peak RSS, and
minor/major page-fault deltas, all into
`benchmarks/results/search-latest.json` — recorded numbers, never prose
copies.

*Is search recall tracked without a model in CI?* The checked
`benchmarks/data/representative-v1-512/` bundle contains 96 corpus
vectors plus 12 text and 12 image queries. Its standard-library
generator is deterministic; CI validates NumPy layout, L2
normalization, relevance structure, manifest, and hashes.
`bench-search` measures recall at oversampling factors 4, 8, and 16
against an exact float32 scan on every run. This proves search
mechanics, not neural-model quality. The offline GME/Qwen 2B harness is
retained for later text/image qualification; audio remains unclaimed.

== What this release does not verify

Honesty about the suites requires the same honesty about their edges.
The engineering headroom tracked in the product plan: pipelined and
batched writes under one chosen value, which the descriptor already
anticipates with `transaction_count`; group fsync; random fault
schedules longer than the deterministic adverse run; automatic voter
replacement; and sharding. The decided replacement verified above is
operator-initiated, one voter at a time; a system that detects a dead
voter and replaces it on its own is neither a product feature nor a
verified one. The 10,000-crash, 100-consecutive-run, and
1-GiB recovery gates are explicitly deferred. The checked large
recovery fixture is 1 MiB.

#exercise([17.1], [
  Run `benchmarks/compare-rqlite-3node.sh` on your own machine.
  Before it finishes, predict which columns of your table will differ
  most from the recorded one and which will differ least. Then
  explain why p50 travels between machines better than max does.
], hint: [
  Medians summarize the whole run; the max column is one event.
  fsync cost and scheduler noise vary far more across machines than
  the shape of the pipeline does.
])

Chapter 18 finishes the job. It leaves suites behind and traces each
user-visible guarantee, one row at a time, to the function that
enforces it and the oracle that checks it, and it names the
guarantees that still have no oracle at all.
