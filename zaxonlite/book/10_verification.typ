#import "theme.typ": *

= Verification

== Test layers

#table(
  columns: (auto, 1.6fr, auto),
  table.header([*Layer*], [*Focus*], [*Command*]),
  [Unit], [Codecs, chain hashes, journal replay/torn-tail/corruption,
    payload store faults, WAL capture/apply byte-identity spike, wire
    round trips.], [`zig build test`],
  [Single-process integration], [Restart recovery, journal-authoritative
    rebuild, stale-image convergence, idempotent sessions, session
    expiry, snapshot rollover (explicit and capacity-triggered), failed
    SQL isolation, locking.], [`zig build test-single`],
  [Three-process cluster], [Election, writes through every endpoint,
    follower stop/catch-up, hash comparison, leader SIGKILL failpoint
    with exactly-once retry, rollover with a stopped member (snapshot
    transfer), image rebuild, total restart.],
    [`zig build test-cluster`],
  [Role cluster], [Three data voters, a non-campaigning witness, standby and
    read-replica chosen-log catch-up, role read restrictions, leader hints, and
    bounded-freshness refusal after voter disconnection.],
    [`zig build test-roles`],
  [Gateway], [Authenticated RPC passes end to end through a process with no
    Paxos or SQLite state.], [`zig build test-gateway`],
  [Adverse network/storage], [Real TCP loss, semantic duplication, pair
    reordering, seven-byte frame fragmentation, and delayed durable sync.],
    [`zig build test-fault-network`],
  [CLI contract], [Exit codes, JSON shapes, session semantics, scripted
    shell, locking, offline client mode.], [`zig build test-cli`],
  [C ABI], [Every exported function, including locking and
    replay-after-reopen.], [`zig build test-cabi`],
  [Fuzz], [Seeded: decoder robustness (random + mutated-valid bytes),
    journal-file damage, end-to-end random SQL with crashes and
    rebuild-convergence oracle.], [`zig build fuzz`],
  [Soak], [Sustained mixed load with a live row-count model, replay
    checks, snapshots, restarts.], [`zig build soak`],
  [Benchmark], [Write/read latency percentiles, recovery and rebuild
    times, ReleaseFast.], [`zig build benchmark`],
  [dqlite comparison], [Pinned three-voter durable state, equal one-row
    workload and payload, warmup exclusion, verification, JSON output.],
    [`benchmarks/compare-dqlite-3node.sh` (Linux)],
  [rqlite comparison], [Three voters using installed binaries, equal one-row
    workload and payload, no queued writes, strong verification, CLI membership
    evidence, percentile latency, JSON output.],
    [`benchmarks/compare-rqlite-3node.sh`],
)

`zig build test-cluster -Dcluster-runs=N` repeats the full scenario for
flake hunting; 100 consecutive runs are an explicitly deferred CI stress
target, not a result claimed by this release.

== The mandatory cluster scenario

The controller spawns three real `zaxon serve` processes on loopback
ports and drives them over the public RPC protocol — no test back door
into node internals. Every wait is deadline-based on observable
conditions (status fields), and a failure dumps all three statuses and
log tails. The script: elect; create schema; submit requests 1–100
through all three endpoints (half through a session); verify a
linearizable count; stop a follower; write 101–150; restart and wait
for catch-up; compare chain and content digests on all three; arm the
leader's `before_client_reply` failpoint and submit a session write —
the leader dies after quorum choice; retry the same sequence at the new
leader and prove it applied exactly once; roll the epoch with another
member stopped and watch it rejoin via snapshot transfer; delete a
member's `current.db` and watch it rebuild; kill everything without
ceremony; restart all; verify 153 rows, the failpoint row exactly once,
clean integrity, and identical digests.

== Persistence assertions, mapped

Chapter 6's crash matrix and the plan's persistence assertions each name
their enforcement: chain equality across members (cluster digests),
contiguous monotone apply (commit accounting), acknowledged writes
surviving single-node loss and total restart (cluster scenario),
at-most-once session sequences (single, CLI, C ABI, cluster failpoint),
payload-before-vote (transport gating plus store fault tests),
sync-before-send (structural: journal fsync precedes the outbox),
refusal on missing durable state (corrupt-journal and missing-payload
tests), torn-tail-versus-interior discrimination (journal tests and
fuzz), and quorum loss blocking acknowledgement (two-members-down
refusal).

== Measured baselines

On the development machine (Apple Silicon, Debug-mode servers except
where noted), single-node ReleaseFast:

```text
write     1000 ops     672 ms    1485 ops/s   p50 617 us  p95 729 us  p99 818 us
read     10000 ops      21 ms  462490 ops/s   p50   2 us  p99   2 us
recovery  1000 committed writes replayed + validated in 11 ms
rebuild   image restored from snapshot in <1 ms
```

Each write is a full pipeline: SQLite transaction, frame capture,
payload fsync, journal append, journal fsync. The read path performs no
consensus append and no disk sync — that is the fence path's cost model,
plus one network round trip in a cluster. Numbers are baselines, not
claims; the benchmark harness prints its own on your hardware.

The first installed-rqlite comparison on the same Apple Silicon development
host used rqlite v10.2.7 / SQLite 3.53.2, three voters, 100 excluded warmup
writes, then 1,000 measured 256-byte autocommits. One observed run was:

```text
zaxonlite   474.6 ops/s   p50 1.69 ms   p95 1.97 ms   p99 2.32 ms
rqlite       45.0 ops/s   p50 21.96 ms  p95 27.96 ms  p99 33.04 ms
```

The installed `rqlite` CLI confirmed three reachable voters and 1,000 measured
rows; the driver also checked a strong count and exact-payload predicate. This
is one local end-to-end observation, not a portable claim or a consensus-only
microbenchmark. dqlite execution remains deferred to a supported Linux host.
The raw JSON is retained under `benchmarks/results/`.

== Real-world failure and recovery comparison

The second product comparison is a deterministic order-processing simulation,
not a single-row write loop. Each product runs alone as three voters with 1,000
customers, 500 products and four clients distributed across all endpoints. The
traffic is 70% reads (inventory, customer history and sales dashboards) and 30%
orders. An order is one SQLite transaction whose trigger creates an order line,
decrements inventory and records an accounting-ledger entry.

Measured reads use each product's quorum-fence `linearizable` level. rqlite's
`strong` mode is reserved for the final verification barrier because rqlite's
#link("https://rqlite.io/docs/api/read-consistency/")[read-consistency guide]
describes that mode as a testing tool which writes through Raft; it recommends
`linearizable` when that guarantee is required in production.
Every write carries a unique operation ID and uses `insert or ignore`, so a
client can safely retry an ambiguous response after a process dies.

After 100 warmup operations the controller runs three 400-operation phases:

+ healthy three-voter traffic;
+ `SIGKILL` one follower, continue with a quorum, restart it and wait until its
  local SQLite copy matches;
+ `SIGKILL` the leader, begin traffic immediately, retry through election,
  restart the old leader and wait for local catch-up.

It then kills all three processes, restarts their original identities and data
directories, and checks every local copy. Two consecutive full runs on the
same Darwin-arm64 development host produced these ranges:

#table(
  columns: (1.55fr, 1fr, 1fr),
  table.header([*Measurement*], [*Zaxonlite*], [*rqlite v10.2.7*]),
  [Healthy mixed throughput], [1,783-1,796 ops/s], [170-177 ops/s],
  [One-follower mixed throughput], [1,045-1,073 ops/s], [214-222 ops/s],
  [Leader crash to first success], [591-597 ms], [2,190-2,402 ms],
  [Restarted follower catch-up], [112-166 ms], [841-949 ms],
  [Restarted old-leader catch-up], [175-338 ms], [548-554 ms],
  [Total three-node restart], [446-457 ms], [1,294-1,627 ms],
)

In the retained run, healthy all-operation p50/p95 latency was 1.63/5.58 ms
for Zaxonlite and 15.26/68.58 ms for rqlite. The leader outage appears honestly
in tails: linearizable-read p99 was 602 ms and 2,411 ms respectively. Both
systems finished with exactly 372 orders, lines, ledger records and operation
IDs; 942 inventory units; 4,428,073 cents revenue; no negative stock; identical
values on all three nodes; and clean SQLite integrity. Zaxonlite's chain and
payload-store checks also passed.

These are local end-to-end observations, not a proof that Paxos is faster than
Raft. Front ends, storage layouts, election timers and implementations differ.
The initial rqlite bootstrap time is intentionally omitted because the manual
join path incurred its default three-second retry interval. This schedule tests
process loss and restart, not network partition or disk corruption; those are
covered by the separate adverse-network and crash suites. Reproduce with
`benchmarks/compare-rqlite-realworld-3node.py`; the full JSON is
`benchmarks/results/realworld-rqlite-v10.2.7-darwin-arm64-2026-07-20.json`.

== What remains beyond this book

Engineering headroom, tracked in the product plan: pipelined/batched
writes under one chosen value (the descriptor already carries
`transaction_count`), group fsync, longer random fault schedules beyond the
deterministic adverse run, automatic voter replacement, and sharding. The
10,000-crash, 100-run, and 1-GiB gates are explicitly deferred; the checked
large recovery fixture is 1 MiB.
