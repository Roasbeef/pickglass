//// The static preview: every page rendered to a standalone HTML file.
////
//// `gleam run -m pickglass_web/preview -- <out dir>` renders each page from
//// the fixture data with the same `app.view` the viewer mounts, wraps it in
//// a complete document that links the stylesheet, copies the stylesheet next
//// to it, and writes an `index.html` that links every page. Opening a file
//// needs no server: the pages are as the viewer would draw them, minus the
//// socket, so nothing responds to clicks. Navigation between pages is plain
//// links to the sibling files.
////
//// Profile has one file per tab, and Owners one with the keeper's group
//// expanded, so the screenshots show the states worth reviewing. A state is
//// reached by sending the page the same `Ui` messages a click would send,
//// through `app.update`, with a request handler that does nothing.
////
//// This module is development tooling. It writes files, so it lives under
//// `dev/` with the fixtures, and `src/` stays free of I/O.
////
//// ## Flow
////
//// `main` reads the output directory, builds the list of `Entry`s
//// (`entries`), writes each file (`write_entry`), copies the stylesheet and
//// writes the index.

import argv
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import lustre/attribute
import lustre/effect
import lustre/element
import lustre/element/html
import pickglass_web/app.{type Model}
import pickglass_web/chart/call_graph
import pickglass_web/chart/flame as flame_chart
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg.{type Msg}
import pickglass_web/page
import simplifile

/// One file of the preview.
type Entry {
  Entry(file: String, title: String, summary: String, model: Model)
}

/// Run the preview: write every page into the directory named on the command
/// line.
pub fn main() -> Nil {
  case argv.load().arguments {
    [out] ->
      case write_all(out) {
        Ok(count) ->
          io.println("wrote " <> string.inspect(count) <> " pages to " <> out)
        Error(reason) -> io.println("preview failed: " <> reason)
      }
    _ -> io.println("usage: gleam run -m pickglass_web/preview -- <out dir>")
  }
}

fn write_all(out: String) -> Result(Int, String) {
  let all = entries()

  use _ <- result.try(
    simplifile.create_directory_all(out) |> describe("create " <> out),
  )
  use _ <- result.try(list.try_each(all, fn(entry) { write_entry(out, entry) }))
  use css <- result.try(
    simplifile.read("priv/pickglass.css") |> describe("read priv/pickglass.css"),
  )
  use _ <- result.try(
    simplifile.write(out <> "/pickglass.css", css)
    |> describe("write stylesheet"),
  )
  use _ <- result.try(
    simplifile.write(out <> "/index.html", index(all))
    |> describe("write index"),
  )

  Ok(list.length(all) + 1)
}

fn describe(
  result: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, String) {
  result.map_error(result, fn(error) {
    what <> ": " <> simplifile.describe_error(error)
  })
}

fn write_entry(out: String, entry: Entry) -> Result(Nil, String) {
  simplifile.write(out <> "/" <> entry.file, document(entry))
  |> describe("write " <> entry.file)
}

// ------------------------------------------------------------ documents

fn document(entry: Entry) -> String {
  element.to_document_string(
    html.html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width, initial-scale=1"),
        ]),
        html.title([], "pickglass · " <> entry.title),
        html.link([attribute.rel("stylesheet"), attribute.href("pickglass.css")]),
      ]),
      html.body([], [app.view(entry.model)]),
    ]),
  )
}

fn index(all: List(Entry)) -> String {
  let items =
    list.map(all, fn(entry) {
      html.li([], [
        html.a([attribute.href(entry.file)], [element.text(entry.title)]),
        html.span([attribute.class("muted")], [
          element.text("  " <> entry.summary),
        ]),
      ])
    })

  element.to_document_string(
    html.html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.title([], "pickglass preview"),
        html.link([attribute.rel("stylesheet"), attribute.href("pickglass.css")]),
      ]),
      html.body([], [
        html.main([attribute.class("page index")], [
          html.h1([], [element.text("pickglass preview")]),
          html.p([attribute.class("note")], [
            element.text(
              "Every page rendered from fixture data (a Loom-like daemon). "
              <> "These are static: nothing responds to clicks.",
            ),
          ]),
          html.ul([attribute.class("index-list")], items),
        ]),
      ]),
    ]),
  )
}

// ------------------------------------------------------------ entries

fn base(target: page.Page) -> Model {
  app.init(fixture.start(target, page.Files))
}

// Apply the messages a click would send, ignoring requests.
fn drive(model: Model, messages: List(Msg)) -> Model {
  list.fold(messages, model, fn(current, message) {
    let #(next, _) = app.update(fn(_) { effect.none() }, current, message)
    next
  })
}

fn entries() -> List(Entry) {
  [
    Entry(
      "overview.html",
      "Overview",
      "memory layers, schedulers, OS roles",
      base(page.Overview),
    ),
    Entry(
      "owners.html",
      "Owners",
      "memory by owner, keeper group expanded",
      owners_open(),
    ),
    Entry(
      "processes.html",
      "Processes",
      "windowed table over a sorted index",
      base(page.Processes),
    ),
    Entry(
      "process-detail.html",
      "Process detail",
      "the restart keeper: evidence, lineage, actions",
      base(page.ProcessDetail),
    ),
    Entry(
      "memory.html",
      "Memory",
      "categories with overlap explanations",
      base(page.Memory),
    ),
    Entry(
      "supervision.html",
      "Supervision",
      "tree, labelled as evidence",
      base(page.Supervision),
    ),
    Entry(
      "probes.html",
      "Probes",
      "plan dialog, running and history",
      base(page.Probes),
    ),
    Entry(
      "profile.html",
      "Profile · Flame",
      "filter chain and flame graph",
      profile_flame(),
    ),
    Entry(
      "profile-icicle.html",
      "Profile · Icicle",
      "the same boxes, root on top",
      profile_tab(msg.IcicleTab),
    ),
    Entry(
      "profile-graph.html",
      "Profile · Graph",
      "layered call graph",
      profile_graph(),
    ),
    Entry(
      "profile-top.html",
      "Profile · Top",
      "flat and cumulative table",
      profile_tab(msg.TopTab),
    ),
    Entry(
      "profile-peek.html",
      "Profile · Peek",
      "callers and callees of one function",
      profile_peek(),
    ),
    Entry(
      "profile-source.html",
      "Profile · Source",
      "function locations",
      profile_tab(msg.SourceTab),
    ),
    Entry(
      "timeline.html",
      "Timeline",
      "steps, spans, peaks and a coverage gap",
      drive(base(page.Timeline), [
        msg.Ui(msg.SelectReading(timeline_chart.item_key(0, 4))),
      ]),
    ),
    Entry(
      "compare.html",
      "Compare",
      "one blocking mismatch and a diff flame",
      base(page.Compare),
    ),
    Entry(
      "audit.html",
      "Audit",
      "allowed and denied decisions",
      base(page.Audit),
    ),
  ]
}

fn owners_open() -> Model {
  drive(base(page.Owners), [
    msg.Ui(msg.ToggleRow(key.make("owner:session:s-12"))),
    msg.Ui(msg.ToggleRow(key.make("role:session:s-12 / restart_keeper"))),
  ])
}

fn profile_tab(tab: msg.ProfileTab) -> Model {
  drive(base(page.Profile), [msg.Ui(msg.OpenTab(tab))])
}

fn profile_flame() -> Model {
  let model = base(page.Profile)

  case widest_box(model, 3) {
    Some(box) -> drive(model, [msg.Ui(msg.SelectBox(box))])
    None -> model
  }
}

fn profile_graph() -> Model {
  let model = profile_tab(msg.GraphTab)

  case top_function(model) {
    Some(node) -> drive(model, [msg.Ui(msg.SelectNode(node))])
    None -> model
  }
}

fn profile_peek() -> Model {
  let model = profile_tab(msg.PeekTab)

  case top_function(model) {
    Some(node) -> drive(model, [msg.Ui(msg.SelectNode(node))])
    None -> model
  }
}

// The key of the widest box at a depth, so a screenshot has a selection.
fn widest_box(model: Model, depth: Int) -> option.Option(key.Key) {
  case model.profile {
    app.Ready(data) ->
      case data.stacks {
        model.HasStacks(layout:, ..) ->
          layout.boxes
          |> list.filter(fn(box) { box.depth == depth })
          |> list.sort(fn(a, b) { int_compare(b.width, a.width) })
          |> list.first
          |> result.map(flame_chart.box_key)
          |> option.from_result
        model.NoStacks(..) -> None
      }
    app.Waiting -> None
  }
}

fn int_compare(a: Int, b: Int) -> order.Order {
  case a < b {
    True -> order.Lt
    False ->
      case a > b {
        True -> order.Gt
        False -> order.Eq
      }
  }
}

fn top_function(model: Model) -> option.Option(key.Key) {
  case model.profile {
    app.Ready(data) ->
      case data.top.rows {
        [first, ..] ->
          case first.function {
            Some(id) -> Some(call_graph_key(id))
            None -> None
          }
        [] -> None
      }
    app.Waiting -> None
  }
}

fn call_graph_key(function: Int) -> key.Key {
  call_graph.node_key(function)
}
