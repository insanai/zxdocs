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
)

`zig build test-cluster -Dcluster-runs=N` repeats the full scenario for
flake hunting; the release gate target is 100 consecutive green runs in
CI stress.

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
write     1000 ops    ~630 ms   ~1600 ops/s   p50 0.57 ms  p99 0.90 ms
read     10000 ops     ~20 ms  ~480000 ops/s  p50 2 us
recovery  1000 committed writes replayed + validated in ~10 ms
rebuild   image restored from snapshot in <1 ms
```

Each write is a full pipeline: SQLite transaction, frame capture,
payload fsync, journal append, journal fsync. The read path performs no
consensus append and no disk sync — that is the fence path's cost model,
plus one network round trip in a cluster. Numbers are baselines, not
claims; the benchmark harness prints its own on your hardware.

== What remains beyond this book

Engineering headroom, tracked in the product plan: pipelined/batched
writes under one chosen value (the descriptor already carries
`transaction_count`), group fsync, a soak-under-partition schedule with
packet-level fault injection, dqlite comparison runs, and dynamic
membership beyond the fixed three-voter configuration.
