#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2" as cetz
#import "theme.typ": blue, blue_light, green, green_light, amber, amber_light, red, gray, rule

#let node_style = (
  fill: blue_light,
  stroke: 0.8pt + blue,
  corner-radius: 3pt,
  inset: 7pt,
)

#let quorum_picture() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  circle((0, 0), radius: 1.55, fill: blue_light, stroke: blue)
  circle((2.0, 0), radius: 1.55, fill: green_light, stroke: green)
  content((-0.7, 0), text(weight: "bold")[A])
  content((2.7, 0), text(weight: "bold")[B])
  content((1.0, 0), text(size: 8pt)[A and B])
})

#let phase_flow() = diagram(
  spacing: (34mm, 18mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Candidate], ..node_style),
  node((1, 0), [Phase one #linebreak() prepare], ..node_style),
  node((2, 0), [Quorum #linebreak() promises], ..node_style),
  node((2, 1), [Phase two #linebreak() accept], ..node_style),
  node((1, 1), [Quorum #linebreak() votes], ..node_style),
  node((0, 1), [Chosen], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (2, 1), "-|>"),
  edge((2, 1), (1, 1), "-|>"),
  edge((1, 1), (0, 1), "-|>"),
)

#let effects_flow() = diagram(
  spacing: (24mm, 15mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.9pt + gray,
  node((0, 0), [step(input)], ..node_style),
  node((1, -1), [writes], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  node((1, 0), [messages], fill: blue_light, stroke: 0.8pt + blue,
    corner-radius: 3pt, inset: 7pt),
  node((1, 1), [released entries], fill: rgb("fff5dc"), stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((2, -1), [sync disk], ..node_style),
  node((2, 0), [send network], ..node_style),
  node((2, 1), [apply state], ..node_style),
  edge((0, 0), (1, -1), "-|>"),
  edge((0, 0), (1, 0), "-|>"),
  edge((0, 0), (1, 1), "-|>"),
  edge((1, -1), (2, -1), "-|>", [first]),
  edge((2, -1), (2, 0), "-|>", [then], bend: 25deg),
  edge((2, -1), (2, 1), "-|>", [then], bend: 38deg),
  edge((1, 0), (2, 0), "-|>"),
  edge((1, 1), (2, 1), "-|>"),
)

#let role_map() = diagram(
  spacing: (28mm, 14mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.9pt + gray,
  node((0, 0), [Client], ..node_style),
  node((1, 0), [Proposer], ..node_style),
  node((2, -1), [Acceptor], ..node_style),
  node((2, 1), [Learner], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  node((3, 0), [State machine], ..node_style),
  edge((0, 0), (1, 0), "-|>", [command]),
  edge((1, 0), (2, -1), "-|>", [ballot]),
  edge((2, -1), (2, 1), "-|>", [chosen]),
  edge((2, 1), (3, 0), "-|>", [ordered value]),
)

#let log_picture() = cetz.canvas(length: 1cm, {
  import cetz.draw: *
  for index in range(0, 8) {
    let x = index * 1.15
    let fill_color = if index < 5 { green_light } else if index == 6 { blue_light } else { white }
    rect((x, 0), (x + 1, 0.8), fill: fill_color, stroke: 0.7pt + gray)
    content((x + 0.5, 0.4), [#(index + 1)])
  }
  content((2.85, -0.45), text(fill: green)[contiguous committed prefix])
  content((6.25, 1.2), text(fill: blue)[known but blocked])
  line((6.5, 1.0), (6.5, 0.82), mark: (end: ">"), stroke: blue)
})

// Renders the committed benchmark results. The book can only cite numbers
// that were actually measured: this table is generated from
// benchmarks/results/latest.json (written by benchmarks/run-all.sh) at
// build time, environment stamp included.
#let benchmark_results_table() = {
  let data = json("../../benchmarks/results/latest.json")
  let meta = data.meta
  let find(impl, workload, mode) = data.runs.find(run =>
    run.impl == impl and run.workload == workload and run.mode == mode)
  let ns(run) = calc.round(run.ns_per_value, digits: 1)
  let us(run) = calc.round(run.ns_per_value / 1000, digits: 1)
  let envelopes(run) = if "messages" in run {
    calc.round(run.messages / run.values, digits: 2)
  } else { [-] }
  let span(run) = if "ns_total_min" in run and "ns_total_max" in run {
    calc.round(
      (run.ns_total_max - run.ns_total_min) * 100 / run.ns_total_median,
      digits: 1,
    )
  } else { [-] }
  let matrix_cell(run) = [#ns(run) #text(size: 7.2pt, fill: gray)[ns · #envelopes(run) env]]
  let panel(title, subtitle, body, tint: blue_light, breakable: true) = block(
    width: 100%,
    inset: 9pt,
    radius: 5pt,
    fill: tint,
    stroke: 0.5pt + rule,
    breakable: breakable,
  )[
    #text(size: 11pt, weight: "bold")[#title]
    #linebreak()
    #text(size: 8pt, fill: gray)[#subtitle]
    #v(5pt)
    #body
  ]

  let zig_sync = find("paxos-zig", "u64-3n", "sync")
  let zig_p8 = find("paxos-zig", "u64-3n", "pipeline8")
  let zig_p64 = find("paxos-zig", "u64-3n", "pipeline64")
  let zig_b16 = find("paxos-zig", "u64-3n", "batch16")
  let zig_b256 = find("paxos-zig", "u64-3n", "batch256")
  let omni_sync = find("omnipaxos", "u64-3n", "sync")
  let omni_p8 = find("omnipaxos", "u64-3n", "pipeline8")
  let omni_p64 = find("omnipaxos", "u64-3n", "pipeline64")
  let lib_sync = find("libpaxos3", "u64-3n", "sync-preexec")
  let durable_each = find("paxos-zig", "durable-u64-3n", "fsync-each")
  let durable_group = find("paxos-zig", "durable-u64-3n", "group8")
  let dirty = if "dirty" in meta and meta.dirty { [ · modified tree] } else { [] }

  [
    #text(size: 8pt, fill: gray)[
      Recorded #meta.date · #meta.host · #meta.cpu · #meta.os · revision
      #raw(meta.git)#dirty · Zig #meta.zig · rustc #meta.rustc
    ]
    #v(6pt)
    #grid(
      columns: (1fr, 1fr, 1fr),
      gutter: 6pt,
      box(inset: 7pt, radius: 4pt, fill: blue_light)[
        #text(size: 7pt, weight: "bold", fill: blue)[TIMED]
        #linebreak()
        #text(size: 8pt)[Stable leader through in-process decision]
      ],
      box(inset: 7pt, radius: 4pt, fill: green_light)[
        #text(size: 7pt, weight: "bold", fill: green)[CHECKED]
        #linebreak()
        #text(size: 8pt)[Replica decisions, checksums, envelope counts, journal replay]
      ],
      box(inset: 7pt, radius: 4pt, fill: amber_light)[
        #text(size: 7pt, weight: "bold", fill: amber)[EXCLUDED]
        #linebreak()
        #text(size: 8pt)[Network, codec, contention, application, client queueing]
      ],
    )
    #v(8pt)

    #panel(
      [The comparison at a glance],
      [8-byte values · 3 voters · in-memory · median of 7; lower time is better],
      table(
        columns: (1.05fr, 1.45fr, auto, auto, auto),
        table.header(
          [*Core*], [*Submission shape*], [*env / value*],
          [*ns / value*], [*sample span*],
        ),
        [Zig], [one at a time], [#envelopes(zig_sync)], [#ns(zig_sync)], [#span(zig_sync)%],
        [OmniPaxos], [one at a time], [#envelopes(omni_sync)], [#ns(omni_sync)], [#span(omni_sync)%],
        [LibPaxos3], [one + phase-one preexecution], [#envelopes(lib_sync)], [#ns(lib_sync)], [#span(lib_sync)%],
        [Zig], [window of 64], [#envelopes(zig_p64)], [#ns(zig_p64)], [#span(zig_p64)%],
        [OmniPaxos], [window of 64; coalesced], [#envelopes(omni_p64)], [#ns(omni_p64)], [#span(omni_p64)%],
        [Zig], [`proposeBatch` of 256], [#envelopes(zig_b256)], [#ns(zig_b256)], [#span(zig_b256)%],
      ),
    )
    #v(8pt)

    #panel(
      [Sensitivity matrix],
      [Each cell is median ns/value · logical envelopes/value. Rows change one workload dimension.],
      table(
        columns: (1.15fr, 1fr, 1fr, 1fr, 1fr),
        table.header([*Workload*], [*Zig sync*], [*Zig win 8*], [*Omni sync*], [*Omni win 8*]),
        [8 B · 3 voters], [#matrix_cell(zig_sync)], [#matrix_cell(zig_p8)],
          [#matrix_cell(omni_sync)], [#matrix_cell(omni_p8)],
        [64 B · 3 voters],
          [#matrix_cell(find("paxos-zig", "blob64-3n", "sync"))],
          [#matrix_cell(find("paxos-zig", "blob64-3n", "pipeline8"))],
          [#matrix_cell(find("omnipaxos", "blob64-3n", "sync"))],
          [#matrix_cell(find("omnipaxos", "blob64-3n", "pipeline8"))],
        [1 KiB · 3 voters],
          [#matrix_cell(find("paxos-zig", "blob1k-3n", "sync"))],
          [#matrix_cell(find("paxos-zig", "blob1k-3n", "pipeline8"))],
          [#matrix_cell(find("omnipaxos", "blob1k-3n", "sync"))],
          [#matrix_cell(find("omnipaxos", "blob1k-3n", "pipeline8"))],
        [8 B · 5 voters],
          [#matrix_cell(find("paxos-zig", "u64-5n", "sync"))],
          [#matrix_cell(find("paxos-zig", "u64-5n", "pipeline8"))],
          [#matrix_cell(find("omnipaxos", "u64-5n", "sync"))],
          [#matrix_cell(find("omnipaxos", "u64-5n", "pipeline8"))],
      ),
      tint: green_light,
    )
    #v(8pt)

    #panel(
      [What the Zig API amortizes],
      [All rows still emit one-value protocol envelopes; batching combines host/API work, not wire values.],
      table(
        columns: (1.35fr, auto, auto, 1fr),
        table.header([*Mode*], [*Values / drain*], [*ns / value*], [*env / value*]),
        [individual], [1], [#ns(zig_sync)], [#envelopes(zig_sync)],
        [pipeline], [8], [#ns(zig_p8)], [#envelopes(zig_p8)],
        [pipeline], [64], [#ns(zig_p64)], [#envelopes(zig_p64)],
        [`proposeBatch`], [16], [#ns(zig_b16)], [#envelopes(zig_b16)],
        [`proposeBatch`], [256], [#ns(zig_b256)], [#envelopes(zig_b256)],
      ),
    )
    #v(8pt)

    #panel(
      [Durability changes the scale],
      [512 values · 3 file journals · writes replay-verified after timing · median of 3],
      table(
        columns: (1.3fr, auto, auto, 1fr),
        table.header([*Host policy*], [*fsync / value*], [*µs / value*], [*vs in-memory Zig sync*]),
        [sync every write-bearing transition],
          [#calc.round(durable_each.fsyncs / durable_each.values, digits: 2)],
          [#us(durable_each)],
          [#calc.round(durable_each.ns_per_value / zig_sync.ns_per_value, digits: 0)×],
        [group commit, window 8],
          [#calc.round(durable_group.fsyncs / durable_group.values, digits: 2)],
          [#us(durable_group)],
          [#calc.round(durable_group.ns_per_value / zig_sync.ns_per_value, digits: 0)×],
      ),
      tint: amber_light,
      breakable: false,
    )
    #v(4pt)
    #text(size: 7.8pt, fill: gray)[
      “env” counts logical in-process envelopes, not bytes. OmniPaxos may carry
      many values in one envelope; Zig and this LibPaxos3 fixture carry one.
      “sample span” is (maximum − minimum) / median across the seven totals;
      lower is steadier.
      The doubled-log-slack control is #ns(find("paxos-zig", "u64-3n-slack", "sync")) ns/value;
      compare it with Zig sync above before attributing small differences.
    ]
  ]
}

#let tick_flow() = diagram(
  spacing: (27mm, 15mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [tick], ..node_style),
  node((1, -1), [Follower], ..node_style),
  node((1, 1), [Leader], ..node_style),
  node((2, -1), [Campaign], fill: amber_light, stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((2, 0.5), [Heartbeat], ..node_style),
  node((2, 1.5), [Resend], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, -1), "-|>"),
  edge((0, 0), (1, 1), "-|>"),
  edge((1, -1), (2, -1), "-|>"),
  edge((1, 1), (2, 0.5), "-|>"),
  edge((1, 1), (2, 1.5), "-|>"),
)

#let epoch_flow() = diagram(
  spacing: (29mm, 16mm),
  node-stroke: 0.8pt + blue,
  edge-stroke: 0.8pt + gray,
  node((0, 0), [Configuration 41], ..node_style),
  node((1, 0), [Commands], ..node_style),
  node((2, 0), [Stop sign], fill: amber_light, stroke: 0.8pt + amber,
    corner-radius: 3pt, inset: 7pt),
  node((3, 0), [Configuration 42], fill: green_light, stroke: 0.8pt + green,
    corner-radius: 3pt, inset: 7pt),
  edge((0, 0), (1, 0), "-|>"),
  edge((1, 0), (2, 0), "-|>"),
  edge((2, 0), (3, 0), "-|>", [decided]),
)
