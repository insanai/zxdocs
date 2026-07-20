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
  [Gateway], [Does authenticated RPC pass end to end through a process
    that holds no Paxos or SQLite state?], [`zig build test-gateway`],
  [Adverse network], [Does the cluster stay correct under real TCP
    loss, duplication, reordering, seven-byte fragmentation, and
    delayed durable sync?], [`zig build test-fault-network`],
  [CLI contract], [Do exit codes, JSON shapes, session flags, the
    scripted shell, and locking match the reference?],
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
)

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

== Measured against rqlite

Benchmarks are the easiest place for a book to lie, so this dashboard
states its scope before it shows a number.

#bench_boxes()

Every number in the two tables below is read from the recorded result
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

== What this release does not verify

Honesty about the suites requires the same honesty about their edges.
The engineering headroom tracked in the product plan: pipelined and
batched writes under one chosen value, which the descriptor already
anticipates with `transaction_count`; group fsync; random fault
schedules longer than the deterministic adverse run; automatic voter
replacement; and sharding. The 10,000-crash, 100-consecutive-run, and
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
