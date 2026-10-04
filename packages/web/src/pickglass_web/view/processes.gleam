//// The process table.
////
//// A node can have a hundred thousand processes, and a Lustre page re-renders
//// and re-diffs its whole tree on every message, so this page never draws
//// them all. The viewer holds the sorted index and sends one window of it;
//// the page draws that window and says where the window sits ("rows 1 to 100
//// of 3,412"). Sorting and paging are requests to the viewer, which answers
//// with a new window, so the page needs no copy of the index.
////
//// Rows are keyed by the key the viewer issued for the process, so when a
//// refresh reorders the window Lustre moves rows instead of rewriting them,
//// and a click that was in flight while the order changed reaches the same
//// process or none. Each row links to its detail page and carries a pin
//// button that only sends a request.
////
//// ## Reading order
////
//// `view` draws the panel; `head` builds the sortable header, `row` one
//// keyed row, and `pager` the window controls.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import pickglass_core/owner
import pickglass_core/unit
import pickglass_web/fmt
import pickglass_web/key
import pickglass_web/model.{type ProcRow, type ProcessesModel, type SortColumn}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links}
import pickglass_web/view/ui
import pickglass_web/wire

const binary_why: String =
  "References to reference-counted binaries overlap between processes and "
  <> "are never totalled."

/// Draw the processes page.
pub fn view(data: ProcessesModel, links: Links) -> Element(Msg) {
  ui.panel(title: "Processes", info: data.info, controls: [pager(data)], body: [
    html.table([attribute.class("tbl processes")], [
      head(data.sort, data.rate_ms),
      keyed.tbody(
        [],
        list.map(data.rows, fn(process) {
          #(key.to_string(process.key), row(process, links))
        }),
      ),
    ]),
    ui.note(
      "Rows are one window of a sorted index held by the viewer. "
      <> "Reductions are a work counter, not CPU time.",
    ),
  ])
}

fn pager(data: ProcessesModel) -> Element(Msg) {
  let window = data.window
  let first = case window.total {
    0 -> 0
    _ -> window.offset + 1
  }
  let last = int.min(window.offset + list.length(data.rows), window.total)

  html.div([attribute.class("pager")], [
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        wire.click(msg.Ask(msg.MovePage(msg.FirstPage))),
      ],
      [element.text("⇤")],
    ),
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        wire.click(msg.Ask(msg.MovePage(msg.PreviousPage))),
      ],
      [element.text("‹")],
    ),
    html.span([attribute.class("pager-text num")], [
      element.text(
        "rows "
        <> fmt.count(first)
        <> " to "
        <> fmt.count(last)
        <> " of "
        <> fmt.count(window.total),
      ),
    ]),
    html.button(
      [
        attribute.class("btn btn-small"),
        attribute.type_("button"),
        wire.click(msg.Ask(msg.MovePage(msg.NextPage))),
      ],
      [element.text("›")],
    ),
  ])
}

// The reduction column says what its rate is over: the change between the
// last two passes, not the count since the process started.
fn rate_label(rate_ms: Option(Int)) -> String {
  case rate_ms {
    Some(ms) -> "red/s over last " <> fmt.duration_ms(ms)
    None -> "red/s (needs two passes)"
  }
}

fn head(sort: SortColumn, rate_ms: Option(Int)) -> Element(Msg) {
  html.thead([], [
    html.tr([], [
      ui.th("pid", None),
      ui.th("owner", None),
      sortable("memory", model.ByMemory, sort),
      ui.th_num("heap capacity", None),
      sortable("mailbox", model.ByMailbox, sort),
      sortable(rate_label(rate_ms), model.ByReductions, sort),
      ui.th_num("binary refs ≈", Some(binary_why)),
      ui.th("current function", None),
      ui.th("", None),
    ]),
  ])
}

fn sortable(
  label: String,
  column: SortColumn,
  current: SortColumn,
) -> Element(Msg) {
  let active = case column == current {
    True -> "sort sort-active"
    False -> "sort"
  }

  html.th([attribute.class("num"), sort_state(column, current)], [
    html.button(
      [
        attribute.class(active),
        attribute.type_("button"),
        wire.click(msg.Ask(msg.SortProcesses(column))),
      ],
      [element.text(label)],
    ),
  ])
}

fn sort_state(
  column: SortColumn,
  current: SortColumn,
) -> attribute.Attribute(Msg) {
  case column == current {
    True -> attribute.aria("sort", "descending")
    False -> attribute.none()
  }
}

fn row(process: ProcRow, links: Links) -> Element(Msg) {
  html.tr([], [
    html.td([], [
      html.a(
        [
          attribute.class("pid mono"),
          attribute.href(page.process_href(links, process.key)),
        ],
        [element.text(process.pid_text)],
      ),
    ]),
    html.td([attribute.class("owner-cell")], [
      html.span([attribute.class("owner-label")], [
        element.text(process.owner_label),
      ]),
      attribution_tag(process),
    ]),
    ui.num(process.memory, unit.Bytes),
    ui.num(process.heap_cap, unit.Bytes),
    ui.num(process.mailbox, unit.Count),
    ui.num(process.reductions, unit.Reductions),
    ui.overlap(process.binary_refs, unit.Count, binary_why),
    html.td([attribute.class("mono current")], [current(process)]),
    html.td([attribute.class("row-actions")], [
      html.button(
        [
          attribute.class("btn btn-small"),
          attribute.type_("button"),
          wire.click(msg.Ask(msg.RequestPin(process.key))),
        ],
        [element.text("Pin")],
      ),
    ]),
  ])
}

fn attribution_tag(process: ProcRow) -> Element(Msg) {
  case process.attribution {
    owner.Attributed(winner:, ..) ->
      ui.badge("source", owner.source_code(winner.source))
    owner.Unattributed -> ui.badge("source source-none", "unknown")
  }
}

fn current(process: ProcRow) -> Element(Msg) {
  case process.current {
    Some(name) -> element.text(name)
    None -> html.span([attribute.class("word")], [element.text("not read")])
  }
}
