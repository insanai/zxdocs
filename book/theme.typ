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
    title: "Part Time Parliament",
    author: "Paxos Zig contributors",
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
  set page(
    margin: (x: 30mm, top: 35mm, bottom: 35mm),
    header: none,
    background: rect(width: 100%, height: 100%, fill: rgb("0e1626")),
  )
  align(center)[
    #v(5mm)
    #text(size: 28pt, weight: "bold", fill: white)[Part Time Parliament]
    #v(4mm)
    #text(size: 14pt, fill: rgb("4f8fff"))[A Literate Guide to Paxos in Zig]
    #v(16mm)
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *
      let n_color = rgb("4f8fff")
      let e_color = rgb("203a60")
      circle((0, 0), radius: 3.5, stroke: 1pt + e_color)
      circle((0, 0), radius: 2.2, stroke: 0.5pt + e_color)
      let pts = (
        (0.0, 3.5),
        (3.328, 1.08),
        (2.057, -2.83),
        (-2.057, -2.83),
        (-3.328, 1.08),
      )
      for p1 in pts {
        for p2 in pts {
          if p1 != p2 {
            line(p1, p2, stroke: 0.6pt + e_color)
          }
        }
      }
      for p in pts {
        circle(p, radius: 0.28, fill: rgb("0e1626"), stroke: 1.5pt + n_color)
        circle(p, radius: 0.08, fill: n_color, stroke: none)
      }
      circle((0, 0), radius: 0.6, fill: rgb("173f2a"), stroke: 1.5pt + rgb("27734d"))
      content((0, 0), text(size: 8pt, fill: rgb("43b87a"), weight: "bold")[Chosen])
    })
    #v(16mm)
    #box(
      inset: (x: 14pt, y: 10pt),
      radius: 4pt,
      fill: rgb("16243d"),
      stroke: 0.7pt + rgb("233c66"),
    )[
      #text(size: 10pt, fill: rgb("a5c7f7"))[Paxos protocol design, optimization, and implementation]
    ]
    #v(12mm)
    #text(size: 9.5pt, fill: rgb("8898b3"))[Version 0.1.0]
    #v(2mm)
    #text(size: 9.5pt, fill: rgb("8898b3"))[Paxos Zig contributors]
  ]
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
