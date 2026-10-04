//// Memory by owner.
////
//// The owners page groups processes by who owns them, using the join of
//// labels, provider claims, registry names and supervision that core's
//// `owner` module performs. Its job is to make one thing easy to see, which
//// owner holds the memory that moved, and to be honest about two limits.
////
//// The `unknown` row is always drawn, even when it is empty, so the operator
//// can see how much of the node nobody claimed. And a column whose rows may
//// share what they measure, references to reference-counted binaries, is
//// marked with the approximation sign and has no group total: a binary
//// referenced by two processes would be counted twice, and a figure that is
//// not a total must not look like one. Group rows say "not summed" in words.
////
//// Rows expand to show their processes, each with a pin button that sends a
//// request, nothing more. Expansion state is the operator's (`state`); a new
//// census keeps it.
////
//// ## Reading order
////
//// `view` filters the flat row list by what is expanded (`visible`), then
//// draws each visible row (`group_row`) and, below an expanded one, its
//// processes (`member_row`).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/policy.{type Capability}
import pickglass_core/unit
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model.{
  type CheckpointRef, type OwnerRow, type OwnersModel, type ProcRow,
}
import pickglass_web/msg.{type Msg}
import pickglass_web/page.{type Links}
import pickglass_web/state.{type UiState}
import pickglass_web/view/ui
import pickglass_web/wire

const binary_why: String =
  "References to reference-counted binaries overlap between processes: a "
  <> "binary two processes hold is counted by both. The column is shown "
  <> "per process and is never totalled."

/// Whether a row's parent is open, so its children are drawn.
type Visibility {
  Visible
  Hidden
}

/// Draw the owners page.
pub fn view(
  data: OwnersModel,
  ui_state: UiState,
  links: Links,
  grants: List(Capability),
) -> Element(Msg) {
  let rows = visible(data.rows, ui_state)
  let all = list.append(rows, [data.unknown])
  let tail = case data.remainder {
    model.NoRemainder -> []
    model.Remainder(..) -> [
      #("remainder/row", remainder_row(data.remainder)),
    ]
  }

  let body_rows =
    list.flat_map(all, fn(row) {
      let heading = #(
        key.to_string(row.key) <> "/row",
        group_row(row, ui_state, grants),
      )

      // An open row shows every member. The unknown row shows its largest
      // few even when closed, because a page that says only "nobody claimed
      // this memory" leaves the operator a click away from the processes
      // that hold it.
      let shown = case set.contains(ui_state.expanded, row.key), row.kind {
        True, _ -> row.members
        False, model.UnknownGroup -> largest(row.members, unknown_preview)
        False, model.OwnerGroup | False, model.RoleGroup -> []
      }
      let children =
        list.map(shown, fn(member) {
          #(
            key.to_string(row.key) <> "/" <> key.to_string(member.key),
            member_row(member, links),
          )
        })

      [heading, ..children]
    })
    |> list.append(tail)

  ui.panel(
    title: "Memory by owner",
    info: data.info,
    controls: controls(data),
    body: [
      html.table([attribute.class("tbl owners")], [
        head(data.rate_ms),
        keyed.tbody([], body_rows),
      ]),
      ui.note(
        "≈ marks a column whose rows overlap; it has no group total. "
        <> "Δ is the difference of the row's heap capacity between the "
        <> "chosen checkpoint and now, taken over the row's whole group, so "
        <> "it includes processes that started or exited in between and the "
        <> "rows beneath a group need not add to it. The unknown row lists "
        <> "its five largest processes; open it for the rest.",
      ),
      ui.note(labelled_text(data.labelled)),
    ],
  )
}

// The most members listed under the unknown row while it is closed.
const unknown_preview: Int = 5

// The `count` members with the most heap capacity. A member whose capacity
// was not read has no size to rank by and comes last.
fn largest(members: List(ProcRow), count: Int) -> List(ProcRow) {
  members
  |> list.sort(fn(a, b) { int.compare(heap_of(b), heap_of(a)) })
  |> list.take(count)
}

fn heap_of(member: ProcRow) -> Int {
  case member.heap_cap {
    measure.Known(value:) -> value
    measure.Missing(_) | measure.NotApplicable -> -1
  }
}

fn labelled_text(counts: #(Int, Int)) -> String {
  "Labels read on "
  <> fmt.count(counts.0)
  <> " of the "
  <> fmt.count(counts.0 + counts.1)
  <> " processes listed; "
  <> fmt.count(counts.1)
  <> " carried none."
}

fn controls(data: OwnersModel) -> List(Element(Msg)) {
  [
    html.span([attribute.class("chip")], [element.text("group by owner path")]),
    html.label([attribute.class("select")], [
      element.text("Δ vs "),
      html.select(
        [wire.key_chosen(fn(picked) { msg.Ask(msg.ChooseBaseline(picked)) })],
        list.map(data.checkpoints, fn(ref) { option_for(ref, data.baseline) }),
      ),
    ]),
  ]
}

fn option_for(
  ref: CheckpointRef,
  baseline: Option(CheckpointRef),
) -> Element(Msg) {
  let chosen = case baseline {
    Some(current) -> current.key == ref.key
    None -> False
  }

  html.option(
    [attribute.value(key.to_string(ref.key)), attribute.selected(chosen)],
    ref.checkpoint.name,
  )
}

fn head(rate_ms: Option(Int)) -> Element(Msg) {
  html.thead([], [
    html.tr([], [
      ui.th("owner", None),
      ui.th_num("procs", None),
      ui.th_num("heap capacity", Some("process_info(memory), bytes")),
      ui.th_num("Δ", Some("change of heap capacity since the checkpoint")),
      ui.th_num("mailbox", Some("messages waiting")),
      ui.th_num(
        case rate_ms {
          Some(ms) -> "red/s over last " <> fmt.duration_ms(ms)
          None -> "red/s (needs two passes)"
        },
        Some(
          "reductions per second between the last two passes, summed over the "
          <> "processes that were in both: work, not CPU time",
        ),
      ),
      ui.th_num("binary refs ≈", Some(binary_why)),
    ]),
  ])
}

// A group is always visible; a role row only while its group is expanded.
fn visible(rows: List(OwnerRow), ui_state: UiState) -> List(OwnerRow) {
  let #(shown, _) =
    list.fold(rows, #([], Visible), fn(state, row) {
      let #(shown, parent) = state

      case row.kind {
        model.OwnerGroup -> #([row, ..shown], opened(ui_state, row.key))
        model.RoleGroup | model.UnknownGroup ->
          case parent {
            Visible -> #([row, ..shown], parent)
            Hidden -> #(shown, parent)
          }
      }
    })

  list.reverse(shown)
}

fn opened(ui_state: UiState, row: Key) -> Visibility {
  case set.contains(ui_state.expanded, row) {
    True -> Visible
    False -> Hidden
  }
}

fn group_row(
  row: OwnerRow,
  ui_state: UiState,
  grants: List(Capability),
) -> Element(Msg) {
  let class = case row.kind {
    model.OwnerGroup -> "group"
    model.RoleGroup -> "group role-row"
    model.UnknownGroup -> "group unknown"
  }

  let expandable = case row.members {
    [] -> twisty_placeholder()
    _ -> twisty(row.key, ui_state)
  }

  html.tr([attribute.class(class)], [
    html.td([attribute.class("owner-cell depth-" <> depth(row.depth))], [
      expandable,
      html.span([attribute.class("owner-label")], [element.text(row.label)]),
      source_tag(row),
      ui.profile_button(
        grants,
        "Profile",
        "Pin the busiest processes of "
          <> row.label
          <> " and plan one stack probe over them",
        msg.ProfileOwner(row.key),
      ),
      ui.record_button(
        grants,
        "Record",
        "Pin the busiest processes of "
          <> row.label
          <> " and plan a recording of when they run and collect garbage",
        msg.RecordOwner(row.key),
      ),
    ]),
    ui.num(row.procs, unit.Count),
    heap_cell(row),
    ui.delta(row.delta, unit.Bytes),
    ui.num(row.mailbox, unit.Count),
    ui.num(row.reductions, unit.Reductions),
    ui.no_total(binary_why),
  ])
}

// The processes the agent counted but did not list. It is drawn from the
// aggregate, so only the two figures the aggregate carries are numbers; the
// rest say they were not measured for these processes.
fn remainder_row(remainder: model.Remainder) -> Element(Msg) {
  case remainder {
    model.NoRemainder -> element.none()
    model.Remainder(procs:, heap_cap:) ->
      html.tr([attribute.class("group remainder")], [
        html.td([attribute.class("owner-cell depth-0")], [
          html.span([attribute.class("twisty twisty-none")], []),
          html.span([attribute.class("owner-label")], [
            element.text("other, not in the listed owners"),
          ]),
        ]),
        ui.num(procs, unit.Count),
        ui.num(heap_cap, unit.Bytes),
        ui.num(measure.NotApplicable, unit.Bytes),
        ui.num(measure.NotApplicable, unit.Count),
        ui.num(measure.NotApplicable, unit.Reductions),
        ui.no_total(binary_why),
      ])
  }
}

// A total over members some of which were unread is a lower bound, and the
// cell says so, with the count in its hover text.
fn heap_cell(row: OwnerRow) -> Element(Msg) {
  case row.unread {
    0 -> ui.num(row.heap_cap, unit.Bytes)
    n ->
      html.td(
        [
          attribute.class("num bound"),
          attribute.title(
            int.to_string(n)
            <> " processes had no reading; the total leaves them out",
          ),
        ],
        [element.text("≥ " <> fmt.cell(row.heap_cap, unit.Bytes))],
      )
  }
}

fn depth(level: Int) -> String {
  case level {
    0 -> "0"
    _ -> "1"
  }
}

fn twisty(row: Key, ui_state: UiState) -> Element(Msg) {
  let open = set.contains(ui_state.expanded, row)

  let glyph = case open {
    True -> "▾"
    False -> "▸"
  }

  html.button(
    [
      attribute.class("twisty"),
      attribute.type_("button"),
      attribute.aria("expanded", case open {
        True -> "true"
        False -> "false"
      }),
      wire.click(msg.Ui(msg.ToggleRow(row))),
    ],
    [element.text(glyph)],
  )
}

fn twisty_placeholder() -> Element(Msg) {
  html.span([attribute.class("twisty twisty-none")], [])
}

fn source_tag(row: OwnerRow) -> Element(Msg) {
  case row.source {
    None -> element.none()
    Some(source) -> {
      let text = owner.source_code(source)
      let dissent = case row.dissent {
        0 -> ""
        n -> " · " <> int.to_string(n) <> " dissent"
      }

      ui.badge("source", text <> dissent)
    }
  }
}

fn member_row(member: ProcRow, links: Links) -> Element(Msg) {
  html.tr([attribute.class("member")], [
    html.td([attribute.class("owner-cell depth-2")], [
      html.a(
        [
          attribute.class("pid mono"),
          attribute.href(page.process_href(links, member.key)),
        ],
        [element.text(member.pid_text)],
      ),
      html.span([attribute.class("owner-label muted")], [
        element.text(member.owner_label),
      ]),
      html.button(
        [
          attribute.class("btn btn-small"),
          attribute.type_("button"),
          wire.click(msg.Ask(msg.RequestPin(member.key))),
        ],
        [element.text("Pin")],
      ),
    ]),
    ui.num(model_count(), unit.Count),
    ui.num(member.heap_cap, unit.Bytes),
    html.td([attribute.class("num")], []),
    ui.num(member.mailbox, unit.Count),
    ui.num(member.reductions, unit.Reductions),
    ui.overlap(member.binary_refs, unit.Count, binary_why),
  ])
}

// A process row counts itself once; the cell is a real count of one.
fn model_count() -> measure.Measurement {
  measure.Known(1)
}
