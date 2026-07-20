#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2" as cetz
#import "theme.typ": ink, accent, accent_light, blue, blue_light, amber, amber_light, red, red_light, gray, rule, green, green_light

#let voter_style = (
  fill: blue_light,
  stroke: 0.8pt + blue,
  corner-radius: 3pt,
  inset: 7pt,
)

#let learner_style = (
  fill: green_light,
  stroke: 0.8pt + green,
  corner-radius: 3pt,
  inset: 7pt,
)

#let plain_style = (
  fill: accent_light,
  stroke: 0.8pt + accent,
  corner-radius: 3pt,
  inset: 7pt,
)

// A full role-aware cluster: three voters decide, learners follow, the
// gateway routes, and the client speaks one protocol to all of them.
#let cluster_topology() = diagram(
  spacing: (16mm, 11mm),
  edge-stroke: 0.8pt + gray,
  node((1, 0), [Client], ..plain_style),
  node((1, 1), [Gateway #linebreak() #text(size: 7.5pt)[no state, no vote]], ..plain_style),
  node((0, 2), [Voter 1 #linebreak() #text(size: 7.5pt)[leader]], ..voter_style),
  node((1, 2), [Voter 2], ..voter_style),
  node((2, 2), [Voter 3 #linebreak() #text(size: 7.5pt)[or witness]], ..voter_style),
  node((0, 3), [Standby #linebreak() #text(size: 7.5pt)[full copy, no reads]],
    ..learner_style),
  node((2, 3), [Read replica #linebreak() #text(size: 7.5pt)[stale reads only]],
    ..learner_style),
  edge((1, 0), (1, 1), "-|>", [RPC]),
  edge((1, 1), (0, 2), "-|>"),
  edge((1, 1), (1, 2), "-|>"),
  edge((1, 1), (2, 2), "-|>"),
  edge((0, 2), (1, 2), "<|-|>", [Paxos]),
  edge((1, 2), (2, 2), "<|-|>", [Paxos]),
  edge((0, 2), (0, 3), "-|>", [certified #linebreak() commits]),
  edge((0, 2), (2, 3), "-|>", label-side: left),
)

// One replicated write, in the order the bytes actually move.
#let write_path() = diagram(
  spacing: (13mm, 10mm),
  edge-stroke: 0.8pt + gray,
  node((0, 0), [SQL arrives #linebreak() #text(size: 7.5pt)[leader only]], ..plain_style),
  node((1, 0), [Speculative #linebreak() WAL capture], ..plain_style),
  node((2, 0), [Payload built #linebreak() #text(size: 7.5pt)[ZXPL, hashed]], ..plain_style),
  node((3, 0), [Payload stored #linebreak() and synced], ..voter_style),
  node((3, 1), [Accept round #linebreak() #text(size: 7.5pt)[payload-gated]], ..voter_style),
  node((2, 1), [Journal synced #linebreak() on a quorum], ..voter_style),
  node((1, 1), [Commit], ..learner_style),
  node((0, 1), [Applied, then #linebreak() acknowledged], ..learner_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (3, 0), "-|>"),
  edge((3, 0), (3, 1), "-|>"),
  edge((3, 1), (2, 1), "-|>"),
  edge((2, 1), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

// Where a transaction's bytes live at each stage.
#let wal_capture() = diagram(
  spacing: (17mm, 10mm),
  edge-stroke: 0.8pt + gray,
  node((0, 0), [SQLite pages #linebreak() #text(size: 7.5pt)[speculative WAL]], ..plain_style),
  node((1, 0), [WAL frames #linebreak() #text(size: 7.5pt)[commit-tiled]], ..plain_style),
  node((2, 0), [ZXPL payload #linebreak() #text(size: 7.5pt)[SHA-256 named]], ..voter_style),
  node((2, 1), [Descriptor #linebreak() #text(size: 7.5pt)[153-byte command]], ..voter_style),
  node((1, 1), [Paxos slot], ..voter_style),
  node((0, 1), [Chain hash #linebreak() #text(size: 7.5pt)[log identity]], ..learner_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>", [hash + counts]),
  edge((2, 1), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

// Restart never trusts the materialized database file.
#let recovery_flow() = diagram(
  spacing: (14mm, 10mm),
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Restart], ..plain_style),
  node((1, 0), [Discard `current.db`, #linebreak() WAL, and SHM], ..voter_style),
  node((2, 0), [Copy verified #linebreak() snapshot image], ..voter_style),
  node((2, 1), [Replay committed #linebreak() journal suffix], ..voter_style),
  node((1, 1), [Verify chain #linebreak() and payloads], ..voter_style),
  node((0, 1), [Serve], ..learner_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>"),
  edge((2, 1), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

// A fenced default read: the leader proves it is still the leader.
#let read_fence() = diagram(
  spacing: (22mm, 9mm),
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Client query], ..plain_style),
  node((1, 0), [Leader issues #linebreak() fence nonce], ..voter_style),
  node((2, 0), [Voters confirm #linebreak() exact ballot], ..voter_style),
  node((1, 1), [Quorum of #linebreak() fence acks], ..voter_style),
  node((0, 1), [Read served from #linebreak() applied state], ..learner_style),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

// The epoch journal timeline around a stop sign.
#let epoch_seal() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  for index in range(0, 4) {
    let x = index * 1.3
    rect((x, 0), (x + 1.2, 0.8), fill: green_light, stroke: green)
    content((x + 0.6, 0.4), text(size: 8pt)[slot #(index + 1)])
  }
  rect((5.2, 0), (6.4, 0.8), fill: amber_light, stroke: amber)
  content((5.8, 0.4), text(size: 8pt)[stop])
  rect((7.0, 0), (8.2, 0.8), fill: blue_light, stroke: blue)
  content((7.6, 0.4), text(size: 8pt)[slot 1])
  rect((8.3, 0), (9.5, 0.8), fill: blue_light, stroke: blue)
  content((8.9, 0.4), text(size: 8pt)[slot 2])
  content((2.6, -0.5), text(size: 8pt, fill: green)[epoch N: decided prefix])
  content((5.8, -0.5), text(size: 8pt, fill: amber)[seal])
  content((8.25, -0.5), text(size: 8pt, fill: blue)[epoch N+1: new journal])
})

// ----------------------------------------------------------------------
// Benchmark dashboard. Every number is read from the recorded result
// files at build time, so the book can only cite measured values.
// ----------------------------------------------------------------------

#let bench_stamp(data) = {
  let tools = data.tools
  text(size: 8pt, fill: gray)[
    Recorded #data.run_at_utc.slice(0, 10) UTC · #data.host ·
    zaxon #raw(tools.zaxon.version) · rqlited #raw(tools.rqlited.version)
  ]
}

#let bench_boxes() = grid(
  columns: (1fr, 1fr, 1fr),
  gutter: 6pt,
  box(inset: 7pt, radius: 4pt, fill: blue_light)[
    #text(size: 7pt, weight: "bold", fill: blue)[TIMED]
    #linebreak()
    #text(size: 8pt)[Client-visible operations against three live voters]
  ],
  box(inset: 7pt, radius: 4pt, fill: green_light)[
    #text(size: 7pt, weight: "bold", fill: green)[CHECKED]
    #linebreak()
    #text(size: 8pt)[Row counts, exact payloads, integrity on every node]
  ],
  box(inset: 7pt, radius: 4pt, fill: amber_light)[
    #text(size: 7pt, weight: "bold", fill: amber)[EXCLUDED]
    #linebreak()
    #text(size: 8pt)[Real networks, concurrent clients, tuned deployments]
  ],
)

#let bench_write_table() = {
  let data = json("../../../zaxonlite/benchmarks/results/latest.json")
  let row(run) = (
    [#run.system],
    [#calc.round(run.operations_per_second, digits: 1)],
    [#calc.round(run.latency_ms.p50, digits: 2)],
    [#calc.round(run.latency_ms.p95, digits: 2)],
    [#calc.round(run.latency_ms.p99, digits: 2)],
    [#calc.round(run.latency_ms.max, digits: 1)],
  )
  [
    #bench_stamp(data)
    #v(4pt)
    #table(
      columns: (1.2fr, auto, auto, auto, auto, auto),
      table.header(
        [*System*], [*writes/s*], [*p50 ms*], [*p95 ms*], [*p99 ms*], [*max ms*],
      ),
      ..data.results.map(row).flatten(),
    )
    #text(size: 8pt, fill: gray)[
      #data.results.at(0).operations single-row durable autocommit writes,
      #data.results.at(0).payload_bytes bytes each, one sequential connection,
      warmup excluded, verified by strong count and exact-payload predicate.
    ]
  ]
}

#let bench_realworld_table() = {
  let data = json("../../../zaxonlite/benchmarks/results/realworld-latest.json")
  let zx = data.results.zaxonlite
  let rq = data.results.rqlite
  let round1(value) = calc.round(value, digits: 1)
  [
    #table(
      columns: (1.55fr, auto, auto),
      table.header([*Order-processing phase*], [*Zaxonlite*], [*rqlite*]),
      [Healthy cluster, mixed reads and writes (ops/s)],
        [#round1(zx.healthy_operations_per_second)],
        [#round1(rq.healthy_operations_per_second)],
      [One follower down (ops/s)],
        [#round1(zx.follower_down_operations_per_second)],
        [#round1(rq.follower_down_operations_per_second)],
      [Leader killed, after failover (ops/s)],
        [#round1(zx.leader_down_operations_per_second)],
        [#round1(rq.leader_down_operations_per_second)],
      [Leader crash to first success (ms)],
        [#round1(zx.leader_crash_to_first_success_ms)],
        [#round1(rq.leader_crash_to_first_success_ms)],
      [Restarted follower catch-up (ms)],
        [#round1(zx.restarted_follower_catch_up_ms)],
        [#round1(rq.restarted_follower_catch_up_ms)],
      [Restarted leader catch-up (ms)],
        [#round1(zx.restarted_leader_catch_up_ms)],
        [#round1(rq.restarted_leader_catch_up_ms)],
      [Full cluster restart to service (ms)],
        [#round1(zx.total_cluster_restart_ms)],
        [#round1(rq.total_cluster_restart_ms)],
    )
    #text(size: 8pt, fill: gray)[
      Recorded #data.run_at_utc.slice(0, 10) UTC.
      Both systems finished with #data.correctness.zaxonlite.orders orders,
      identical rows on every node, and clean integrity checks.
    ]
  ]
}
