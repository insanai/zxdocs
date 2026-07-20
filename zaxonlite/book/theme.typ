// Zaxonlite book theme: a sibling of the Part-Time Parliament book with
// its own identity (deep green accent for the storage/replication focus).

#let ink = rgb("1b2430")
#let accent = rgb("1f6f54")
#let accent_light = rgb("e9f5ef")
#let blue = rgb("2855a6")
#let blue_light = rgb("eaf0fb")
#let amber = rgb("9a6200")
#let amber_light = rgb("fff5dc")
#let red = rgb("9f3030")
#let red_light = rgb("fcecec")
#let gray = rgb("667085")
#let rule = rgb("d4d9e2")
#let green = rgb("27734d")
#let green_light = rgb("eaf7f0")

#let book(body) = {
  set document(
    title: "Zaxonlite: Replicated SQLite on Multi-Paxos",
    author: "Vikrant Rathore, Ronak Rathore",
    keywords: ("SQLite", "Paxos", "replication", "Zig", "embedded database"),
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
          box(width: 100%, clip: true)[Zaxonlite],
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
      #line(length: 38mm, stroke: 1.5pt + accent)
    ]
  }
  show heading.where(level: 2): set text(size: 15pt, fill: ink)
  show heading.where(level: 3): set text(size: 12pt, fill: accent)
  body
}

#let callout(title: none, tone: "note", body) = {
  let (line_color, fill_color) = if tone == "note" {
    (blue, blue_light)
  } else if tone == "decision" {
    (accent, accent_light)
  } else if tone == "warning" {
    (amber, amber_light)
  } else {
    (red, red_light)
  }
  block(
    width: 100%,
    fill: fill_color,
    stroke: (left: 2.2pt + line_color),
    inset: (x: 10pt, y: 8pt),
    radius: 2pt,
    breakable: true,
  )[
    #if title != none {
      text(weight: "bold", fill: line_color, size: 9.5pt)[#title]
      v(2pt)
    }
    #set text(size: 9.6pt)
    #body
  ]
}

// Part divider pages, matching the paxos-zig book's structure.
#let part_page(number, title, summary) = {
  set page(header: none)
  pagebreak(to: "odd")
  align(center + horizon)[
    #text(size: 11pt, tracking: 1.6pt, fill: accent)[PART #number]
    #v(5mm)
    #text(size: 28pt, weight: "bold")[#title]
    #v(7mm)
    #line(length: 34mm, stroke: 1.5pt + accent)
    #v(7mm)
    #box(width: 72%, text(size: 10.5pt, fill: gray)[#summary])
  ]
  pagebreak()
}

// Step-by-step message walkthroughs, as in the paxos-zig book.
#let transcript(rows) = table(
  columns: (auto, auto, 1fr),
  align: (right, left, left),
  table.header(
    [*Step*], [*Actor*], [*Event and reason*],
  ),
  ..rows,
)

#let book_figure(caption, body) = figure(
  placement: auto,
  body,
  caption: text(size: 9pt, fill: gray)[#caption],
)

// Pedagogy blocks shared in spirit with the paxos-zig book so both books
// read the same way: learning contracts, exercises, and teach-back prompts.
#let objectives(body) = callout(title: [Learning contract], tone: "decision", body)

#let checkpoint(title, body) = callout(title: [Checkpoint: #title], body)

#let predict(body) = callout(title: [Predict before reading on], tone: "warning", body)

#let exercise(number, body, hint: none) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: amber_light,
  stroke: 0.6pt + amber,
  breakable: true,
)[
  #text(weight: "bold", fill: amber)[Exercise #number.]
  #h(4pt)
  #body
  #if hint != none [
    #linebreak()
    #text(size: 9pt, fill: gray)[Hint: #hint]
  ]
]

#let teach_back(body) = block(
  width: 100%,
  inset: 9pt,
  outset: (y: 3pt),
  radius: 3pt,
  fill: blue_light,
  stroke: 0.6pt + blue,
  breakable: true,
)[
  #text(weight: "bold", fill: blue)[Teach it back.]
  #h(4pt)
  #body
]

#let api_anchor(symbol, purpose, source: none) = {
  let location = if source == none { [] } else { [ in #source] }
  callout(title: [API anchor: #symbol], [#purpose#location])
}

#let code_file(path, body) = block(
  width: 100%,
  inset: 0pt,
  outset: (y: 4pt),
  stroke: 0.6pt + rule,
  radius: 3pt,
  breakable: true,
)[
  #block(width: 100%, inset: 6pt, fill: blue_light)[
    #text(size: 8pt, weight: "bold", fill: blue)[#path]
  ]
  #block(width: 100%, inset: 8pt)[#body]
]

#let field_table(..rows) = table(
  columns: (auto, auto, 1fr),
  align: (left, left, left),
  table.header([*Offset/size*], [*Field*], [*Meaning*]),
  ..rows
)
