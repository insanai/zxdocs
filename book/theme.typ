#import "@preview/cetz:0.5.2" as cetz

#let ink = rgb("172033")
#let blue = rgb("2855a6")
#let blue_light = rgb("eaf0fb")
#let green = rgb("27734d")
#let green_light = rgb("eaf7f0")
#let amber = rgb("9a6200")
#let amber_light = rgb("fff5dc")
#let red = rgb("9f3030")
#let red_light = rgb("fcecec")
#let gray = rgb("667085")
#let rule = rgb("d4d9e2")

#let book(body) = {
  set document(
    title: "Part-Time Parliament",
    author: "Vikran Rathore, Ronak Rathore",
    keywords: ("Paxos", "consensus", "Zig", "distributed systems"),
  )
  set page(
    paper: "a4",
    margin: (inside: 25mm, outside: 20mm, top: 22mm, bottom: 24mm),
    numbering: "1",
    number-align: center,
    header: context {
      if counter(page).get().first() > 1 {
        set text(size: 8pt, fill: gray)
        let headings = query(heading.where(level: 1).before(here()))
        let chapter = if headings.len() > 0 { headings.last().body } else { [] }
        grid(
          columns: (1fr, 1fr),
          box(width: 100%, clip: true)[Part Time Parliament],
          box(width: 100%, clip: true, align(right, emph(chapter))),
        )
        line(length: 100%, stroke: 0.4pt + rule)
      }
    },
  )
  set text(font: "New Computer Modern", size: 10.3pt, fill: ink, lang: "en")
  set smartquote(enabled: false)
  set par(justify: true, leading: 0.74em, spacing: 0.72em)
  set heading(numbering: "1.1")
  set raw(tab-size: 4)
  show raw: set text(size: 8.3pt)
  set table(stroke: 0.45pt + rule, inset: 6pt)
  show link: set text(fill: blue)
  show heading.where(level: 1): heading => {
    pagebreak(weak: true)
    block(above: 4mm, below: 6mm)[
      #text(size: 22pt, weight: "bold", fill: ink)[#heading]
      #line(length: 38mm, stroke: 1.5pt + blue)
    ]
  }
  show heading.where(level: 2): set text(size: 15pt, fill: ink)
  show heading.where(level: 3): set text(size: 12pt, fill: blue)
  body
}

#let title_page() = {
  let cover_ink = rgb("34405a")
  let cover_muted = rgb("748097")
  let cover_blue = rgb("dfeaf6")
  let cover_blue_line = rgb("88a8c8")
  let cover_sage = rgb("e4f0e8")
  let cover_sage_line = rgb("85aa92")
  let cover_peach = rgb("f7e6d9")
  let cover_peach_line = rgb("d39a72")
  let cover_lilac = rgb("eee9f5")
  let cover_lilac_line = rgb("a596b8")
  let cover_paper = rgb("fbfaf7")

  set page(
    margin: (x: 23mm, top: 18mm, bottom: 19mm),
    header: none,
    numbering: none,
    background: rect(width: 100%, height: 100%, fill: cover_paper),
  )
  grid(
    columns: (1fr, auto),
    text(size: 7.5pt, weight: "bold", tracking: 1.25pt,
      fill: cover_blue_line)[A LITERATE GUIDE TO PAXOS],
    text(size: 7.5pt, tracking: 0.8pt, fill: cover_muted)[ZIG · 0.1.0],
  )

  v(15mm)
  text(size: 40pt, weight: "bold", fill: cover_ink)[Part-Time]
  v(-1mm)
  text(size: 40pt, weight: "bold", fill: cover_ink)[Parliament]
  v(5mm)
  text(size: 12pt, fill: cover_muted)[
    Consensus, invariants, and the craft of building a replicated system
  ]
  v(7mm)
  line(length: 28mm, stroke: 1.4pt + cover_peach_line)

  v(12mm)
  align(center)[
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *

      // Two soft quorum fields overlap around one durable decision.
      circle((-1.05, 0.2), radius: 2.65, fill: rgb("dfeaf6b5"),
        stroke: 0.8pt + cover_blue_line)
      circle((1.05, 0.2), radius: 2.65, fill: rgb("e4f0e8b5"),
        stroke: 0.8pt + cover_sage_line)
      content((-2.2, 2.1), text(size: 7pt, weight: "bold",
        tracking: 0.8pt, fill: cover_blue_line)[QUORUM A])
      content((2.2, 2.1), text(size: 7pt, weight: "bold",
        tracking: 0.8pt, fill: cover_sage_line)[QUORUM B])

      // The parliamentary seats form a chamber. Two outlined seats are away.
      line((-2.55, 0.95), (0, 2.55), (2.55, 0.95),
        stroke: 1.3pt + rgb("cbd6e3"))
      line((-2.55, 0.95), (-1.65, -1.65), (1.65, -1.65),
        (2.55, 0.95), stroke: 1.3pt + rgb("d4dfd8"))
      circle((-2.55, 0.95), radius: 0.5, fill: cover_blue,
        stroke: 1pt + cover_blue_line)
      circle((0, 2.55), radius: 0.54, fill: cover_peach,
        stroke: 1pt + cover_peach_line)
      circle((2.55, 0.95), radius: 0.5, fill: cover_sage,
        stroke: 1pt + cover_sage_line)
      circle((-1.65, -1.65), radius: 0.5, fill: cover_paper,
        stroke: 1pt + cover_lilac_line)
      circle((1.65, -1.65), radius: 0.5, fill: cover_paper,
        stroke: 1pt + cover_lilac_line)

      // The witness and the chosen ledger entry sit in the intersection.
      circle((0, 0.25), radius: 1.15, fill: cover_lilac,
        stroke: 0.8pt + cover_lilac_line)
      rect((-1.35, -0.4), (1.35, 0.65), radius: 5pt,
        fill: rgb("fffffff2"), stroke: 0.7pt + rgb("d8dce5"))
      content((0, 0.38), text(size: 6.8pt, weight: "bold",
        tracking: 1pt, fill: cover_muted)[CHOSEN])
      content((0, -0.02), text(size: 15pt, fill: cover_ink)[$s ↦ v$])

      // A quiet island baseline rather than a literal technical diagram.
      line((-4.25, -2.65), (-3.2, -2.82), (-2.15, -2.65),
        (-1.1, -2.82), (-0.05, -2.65), (1.0, -2.82),
        (2.05, -2.65), (3.1, -2.82), (4.15, -2.65),
        stroke: 1pt + rgb("c9daeb"))
      line((-3.7, -3.02), (-2.7, -3.16), (-1.7, -3.02),
        (-0.7, -3.16), (0.3, -3.02), (1.3, -3.16),
        (2.3, -3.02), (3.3, -3.16),
        stroke: 0.7pt + rgb("dbe6f1"))
    })
  ]

  v(9mm)
  box(
    width: 100%,
    inset: (x: 14pt, y: 11pt),
    radius: 7pt,
    fill: rgb("f0f5fa"),
    stroke: 0.6pt + rgb("d7e3ef"),
  )[
    #text(size: 7pt, weight: "bold", tracking: 1pt,
      fill: cover_blue_line)[THE INVARIANT]
    #v(3pt)
    #text(size: 13pt, fill: cover_ink)[
      $ forall s, v, w : "chosen"(s, v) ∧ "chosen"(s, w) => v = w $
    ]
    #v(4pt)
    #text(size: 8.2pt, fill: cover_muted)[
      Intersecting quorums carry one decision safely through missing members,
      delayed messages, and changing leaders.
    ]
  ]

  v(18mm)
  grid(
    columns: (1fr, auto),
    align: (left, right),
    [
      #text(size: 10pt, weight: "bold", fill: cover_ink)[Vikran Rathore]
      #linebreak()
      #text(size: 7.8pt, fill: cover_muted)[with assistance from Ronak Rathore]
    ],
    align(right)[
      #text(size: 7pt, tracking: 0.8pt, fill: cover_peach_line)[FIRST EDITION]
      #linebreak()
      #text(size: 7.8pt, fill: cover_muted)[Part-Time Parliament]
    ],
  )
}

#let part_page(number, title, summary) = {
  set page(header: none)
  pagebreak(to: "odd")
  align(center + horizon)[
    #text(size: 11pt, tracking: 1.6pt, fill: blue)[PART #number]
    #v(5mm)
    #text(size: 28pt, weight: "bold")[#title]
    #v(7mm)
    #line(length: 34mm, stroke: 1.5pt + blue)
    #v(7mm)
    #box(width: 72%, text(size: 10.5pt, fill: gray)[#summary])
  ]
  pagebreak()
}

#let callout(title, body, kind: "note") = {
  let colors = if kind == "warning" {
    (red, red_light)
  } else if kind == "idea" {
    (green, green_light)
  } else {
    (blue, blue_light)
  }
  block(
    width: 100%,
    inset: 10pt,
    outset: (y: 3pt),
    radius: 3pt,
    fill: colors.at(1),
    stroke: (left: 2pt + colors.at(0)),
  )[
    #text(weight: "bold", fill: colors.at(0))[#title]
    #h(5pt)
    #body
  ]
}

#let definition(term, body) = callout(term, body, kind: "idea")

#let warning(title, body) = callout(title, body, kind: "warning")

#let book_quote(body, attribution) = block(
  width: 88%,
  inset: (left: 12pt, right: 8pt, y: 7pt),
  outset: (y: 4pt),
  stroke: (left: 1.2pt + blue),
)[
  #emph(body)
  #linebreak()
  #align(right, text(size: 9pt, fill: gray)[#text("- ")#attribution])
]

#let exercise(number, body, hint: none) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: amber_light,
  stroke: 0.6pt + amber,
)[
  #text(weight: "bold", fill: amber)[Exercise #number.]
  #h(4pt)
  #body
  #if hint != none [
    #linebreak()
    #text(size: 9pt, fill: gray)[Hint: #hint]
  ]
]

#let transcript(rows) = table(
  columns: (auto, auto, 1fr),
  align: (right, left, left),
  table.header(
    [*Step*], [*Actor*], [*Event and reason*],
  ),
  ..rows,
)

#let objectives(body) = callout([Learning contract], body, kind: "idea")

#let checkpoint(title, body) = callout([Checkpoint: #title], body)

#let predict(body) = callout([Predict before reading on], body, kind: "warning")

#let teach_back(body) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: blue_light,
  stroke: 0.6pt + blue,
)[
  #text(weight: "bold", fill: blue)[Teach it back.]
  #h(4pt)
  #body
]

#let api_anchor(symbol, purpose, source: none) = {
  let location = if source == none { [] } else { [ in #source] }
  callout([API anchor: #symbol], [#purpose#location])
}

#let code_file(path, body) = block(
  width: 100%,
  inset: 0pt,
  outset: (y: 4pt),
  stroke: 0.6pt + rule,
  radius: 3pt,
)[
  #block(width: 100%, inset: 6pt, fill: blue_light)[
    #text(size: 8pt, weight: "bold", fill: blue)[#path]
  ]
  #block(width: 100%, inset: 8pt)[#body]
]

#let book_figure(caption, body) = figure(
  placement: auto,
  body,
  caption: text(size: 9pt, fill: gray)[#caption],
)
