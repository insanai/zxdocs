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
  [
    Recorded #meta.date on #meta.host (#meta.cpu, #meta.os), revision
    #raw(meta.git), Zig #meta.zig, rustc #meta.rustc.
  ]
  table(
    columns: (auto, auto, auto, auto, auto),
    table.header(
      [*Implementation*], [*Workload*], [*Mode*], [*ns / value*],
      [*Messages*],
    ),
    ..data
      .runs
      .map(run => (
        [#run.impl],
        [#run.workload],
        [#run.mode],
        [#calc.round(run.ns_per_value, digits: 1)],
        [#if "messages" in run { str(run.messages) } else { "-" }],
      ))
      .flatten(),
  )
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
