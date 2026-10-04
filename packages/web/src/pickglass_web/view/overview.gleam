//// The overview page.
////
//// The overview answers "where did the memory go" at the level of layers. It
//// stacks what the OS gives the node (resident set), what the allocators
//// hold (carriers), what the VM says is in use (`erlang:memory`) and its
//// categories, and shows the two differences between layers as derived rows.
//// A derived row is labelled as the difference of two readings taken at
//// slightly different moments, and is a word when either side is missing,
//// because a difference with an unknown end is not zero.
////
//// Beside the layers: scheduler utilisation, run queue and reductions as
//// sparklines (reductions marked as work, not CPU), the counts of processes,
//// ports, tables and atoms against their limits, and the OS processes in
//// their roles.
////
//// ## Reading order
////
//// `view` lays out four panels; `layers_panel` is the checkpoint-aware
//// table, with a bar column drawn by `layer_bar`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/element/svg
import pickglass_core/identity
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/policy.{type Capability}
import pickglass_core/unit
import pickglass_web/chart/spark
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/key
import pickglass_web/model.{
  type CheckpointRef, type CountTile, type LayerRow, type OsRole,
  type OverviewModel, type Sparkline,
}
import pickglass_web/msg.{type Msg}
import pickglass_web/view/ui
import pickglass_web/wire

/// Draw the overview. The layers come first because the page answers where
/// the memory went; the counts follow the panels that explain a change. The
/// movers panel waits for its own feed and is absent until it arrives.
pub fn view(
  data: OverviewModel,
  movers: Option(model.OwnerMovers),
  grants: List(Capability),
) -> Element(Msg) {
  html.div([attribute.class("stack")], [
    html.div([attribute.class("profile-bar")], [
      ui.busiest_button(grants),
      html.span([attribute.class("muted")], [
        element.text(
          "Pins the busiest processes, plans one stack probe and waits "
          <> "for your confirmation.",
        ),
      ]),
    ]),
    html.div([attribute.class("grid overview")], overview_panels(data, movers)),
  ])
}

fn overview_panels(
  data: OverviewModel,
  movers: Option(model.OwnerMovers),
) -> List(Element(Msg)) {
  [
    layers_panel(data),
    schedulers_panel(data),
    movers_panel(movers),
    counts_panel(data),
    roles_panel(data),
  ]
}

/// The most owners the movers panel lists.
pub const max_movers: Int = 5

/// The owners to list: the largest absolute change first, at most
/// `max_movers`, with unknown changes left out because a word has no size to
/// rank by.
///
/// ## Examples
///
/// ```gleam
/// overview.top_movers([OwnerMover("a", Known(1)), OwnerMover("b", Known(-9))])
/// // -> [OwnerMover("b", Known(-9)), OwnerMover("a", Known(1))]
/// ```
pub fn top_movers(rows: List(model.OwnerMover)) -> List(model.OwnerMover) {
  rows
  |> list.filter(fn(row) {
    case row.delta {
      Known(value:) -> value != 0
      _ -> False
    }
  })
  |> list.sort(fn(a, b) { int.compare(magnitude(b.delta), magnitude(a.delta)) })
  |> list.take(max_movers)
}

fn magnitude(delta: Measurement) -> Int {
  case delta {
    Known(value:) -> int.absolute_value(value)
    _ -> 0
  }
}

fn movers_panel(movers: Option(model.OwnerMovers)) -> Element(Msg) {
  case movers {
    None -> element.none()
    Some(data) ->
      html.section([attribute.class("panel movers")], [
        html.header([attribute.class("panel-bar")], [
          html.h2([], [element.text("Largest change by owner")]),
          html.span([attribute.class("chip")], [
            element.text("heap capacity since " <> data.since),
          ]),
        ]),
        html.div([attribute.class("panel-body")], [
          case top_movers(data.rows) {
            [] -> ui.note("No owner's heap capacity moved.")
            rows ->
              html.table([attribute.class("tbl")], [
                html.tbody(
                  [],
                  list.map(rows, fn(row) {
                    html.tr([], [
                      html.td([attribute.class("owner-label")], [
                        element.text(row.label),
                      ]),
                      ui.delta(row.delta, unit.Bytes),
                    ])
                  }),
                ),
              ])
          },
        ]),
      ])
  }
}

fn layers_panel(data: OverviewModel) -> Element(Msg) {
  let rows = data.layers.body
  let peak = largest(rows)

  ui.panel(
    title: "Memory layers",
    info: data.layers.info,
    controls: checkpoint_controls(data),
    body: [
      html.table([attribute.class("tbl layers")], [
        html.thead([], [
          html.tr([], [
            ui.th("layer", None),
            ui.th_num("now", None),
            ui.th_num(delta_title(data.checkpoint), None),
            ui.th("", None),
          ]),
        ]),
        html.tbody([], list.map(rows, fn(row) { layer_row(row, peak) })),
      ]),
      ui.note(
        "Gap rows are differences of two readings that were not taken at "
        <> "the same instant. They are derived, not measured.",
      ),
    ],
  )
}

fn delta_title(checkpoint: Option(CheckpointRef)) -> String {
  case checkpoint {
    Some(chosen) -> "Δ since " <> chosen.checkpoint.name
    None -> "Δ (no checkpoint)"
  }
}

// The baseline chooser and the form that takes a checkpoint. The name field
// is read from the submit, so a name typed an instant before Enter or the
// button is the name used. The form is keyed by the checkpoints on the page, so
// that when the viewer reports the new one the browser builds a fresh, empty
// field instead of keeping the name that was just used.
fn checkpoint_controls(data: OverviewModel) -> List(Element(Msg)) {
  let chosen = case data.checkpoint {
    Some(ref) -> Some(ref.key)
    None -> None
  }

  [
    html.label([attribute.class("select")], [
      element.text("vs "),
      html.select(
        [wire.key_chosen(fn(picked) { msg.Ask(msg.ChooseBaseline(picked)) })],
        list.map(data.checkpoints, fn(ref) {
          let value = key.to_string(ref.key)

          html.option(
            [
              attribute.value(value),
              attribute.selected(Some(ref.key) == chosen),
            ],
            ref.checkpoint.name,
          )
        }),
      ),
    ]),
    keyed.div([attribute.class("inline-form")], [
      #(
        checkpoints_key(data.checkpoints),
        html.form(
          [
            attribute.class("inline-form checkpoint-form"),
            wire.submitted("name", fn(text) {
              msg.Ask(msg.TakeCheckpoint(text))
            }),
          ],
          [
            html.input([
              attribute.class("text checkpoint-name"),
              attribute.type_("text"),
              attribute.name("name"),
              attribute.placeholder("name, such as idle-0"),
              attribute.attribute("maxlength", "64"),
              attribute.attribute("aria-label", "Checkpoint name"),
            ]),
            html.button([attribute.class("btn"), attribute.type_("submit")], [
              element.text("Checkpoint now"),
            ]),
          ],
        ),
      ),
    ]),
  ]
}

// The text that changes when a checkpoint is added, which is what clears the
// name field.
fn checkpoints_key(checkpoints: List(CheckpointRef)) -> String {
  list.fold(checkpoints, "", fn(acc, ref) {
    acc <> key.to_string(ref.key) <> ","
  })
}

fn largest(rows: List(LayerRow)) -> Int {
  list.fold(rows, 1, fn(best, row) {
    case row.value {
      Known(value:) -> int.max(best, int.absolute_value(value))
      _ -> best
    }
  })
}

fn layer_row(row: LayerRow, peak: Int) -> Element(Msg) {
  let class = case row.derivation {
    model.Measured -> "layer"
    model.Derived(_) -> "layer derived"
  }

  let label_cell = case row.derivation {
    model.Measured ->
      html.td([attribute.class("layer-label indent-" <> indent(row.depth))], [
        element.text(row.label),
      ])
    model.Derived(note:) ->
      html.td(
        [
          attribute.class("layer-label indent-" <> indent(row.depth)),
          attribute.title(note),
        ],
        [
          element.text(row.label),
          html.span([attribute.class("tag")], [element.text("derived")]),
          negative_note(row),
        ],
      )
  }

  html.tr([attribute.class(class)], [
    label_cell,
    ui.num(row.value, unit.Bytes),
    ui.delta(row.delta, unit.Bytes),
    html.td([attribute.class("bar-cell")], [layer_bar(row, peak)]),
  ])
}

// A gap that comes out below zero reads as an error, so the row says why it
// is not one: the upper layer counts pages the OS has charged, the lower
// counts address space the allocators reserved, and reserved is not resident.
fn negative_note(row: LayerRow) -> Element(Msg) {
  case row.value {
    Known(value:) if value < 0 ->
      html.small([attribute.class("band")], [
        element.text(
          " Negative: the carriers are reserved address space, and the resident set counts only pages the OS has charged. On macOS reserved pages can be untouched or compressed, so the carriers can exceed the resident set.",
        ),
      ])
    _ -> element.none()
  }
}

// Indentation is a class from a closed set, not a computed style.
fn indent(depth: Int) -> String {
  case depth {
    0 -> "0"
    1 -> "1"
    _ -> "2"
  }
}

fn layer_bar(row: LayerRow, peak: Int) -> Element(Msg) {
  case row.value {
    Known(value:) -> {
      let width = int.max(int.absolute_value(value) * 120 / peak, 1)
      let fill = case row.derivation {
        model.Measured -> "bar-fill"
        model.Derived(_) -> "bar-fill bar-derived"
      }

      svg.svg([svg_util.view_box(120, 10), attribute.class("bar")], [
        svg.rect([
          svg_util.num("width", 120),
          svg_util.num("height", 10),
          attribute.class("bar-track"),
        ]),
        svg.rect([
          svg_util.num("width", width),
          svg_util.num("height", 10),
          attribute.class(fill),
        ]),
      ])
    }
    _ -> html.span([attribute.class("word")], [element.text("?")])
  }
}

fn schedulers_panel(data: OverviewModel) -> Element(Msg) {
  ui.panel(title: "Schedulers", info: data.schedulers.info, controls: [], body: [
    html.table([attribute.class("tbl spark-table")], [
      html.tbody([], list.map(data.schedulers.body, spark_row)),
    ]),
  ])
}

fn spark_row(series: Sparkline) -> Element(Msg) {
  html.tr([], [
    html.td([attribute.class("spark-label")], [element.text(series.label)]),
    html.td([attribute.class("spark-cell")], [
      spark.view(series.points, unit: series.unit),
    ]),
    ui.num(series.summary, unit: series.unit),
    html.td([attribute.class("note-cell")], [element.text(series.note)]),
  ])
}

fn counts_panel(data: OverviewModel) -> Element(Msg) {
  html.section([attribute.class("panel tiles")], [
    html.div([attribute.class("tile-row")], list.map(data.counts, count_tile)),
  ])
}

fn count_tile(tile: CountTile) -> Element(Msg) {
  let value_class = case fmt.is_word(tile.value) {
    fmt.Number -> "tile-value num"
    fmt.Word -> "tile-value num word"
  }

  let limit = case tile.limit {
    Known(_) -> " of " <> fmt.cell(tile.limit, unit.Count)
    _ -> ""
  }

  html.div([attribute.class("tile")], [
    html.span([attribute.class("tile-label")], [element.text(tile.label)]),
    html.span([attribute.class(value_class)], [
      element.text(fmt.cell(tile.value, unit.Count)),
    ]),
    html.span([attribute.class("tile-limit")], [element.text(limit)]),
  ])
}

// The anonymous column is dropped, with one note, when no row has a reading
// because the platform has no such figure. Seventeen rows each saying so
// repeat one fact.
fn roles_panel(data: OverviewModel) -> Element(Msg) {
  let anon = list.any(data.roles.body, fn(role) { anon_readable(role) })

  ui.panel(
    title: "OS processes by role",
    info: data.roles.info,
    controls: [],
    body: [
      html.table([attribute.class("tbl")], [
        html.thead([], [
          html.tr(
            [],
            list.flatten([
              [
                ui.th("role", None),
                ui.th_num("os pid", None),
                ui.th_num("RSS", None),
              ],
              case anon {
                True -> [ui.th_num("anon", None)]
                False -> []
              },
              [ui.th("", None)],
            ]),
          ),
        ]),
        html.tbody(
          [],
          list.map(data.roles.body, fn(role) { role_row(role, anon) }),
        ),
      ]),
      case anon {
        True -> element.none()
        False ->
          ui.note(
            "The anonymous part of the resident set is not readable on this platform, so it is not listed.",
          )
      },
      case list.any(data.roles.body, coarse_start) {
        True -> ui.note("Process start times are good to a second.")
        False -> element.none()
      },
    ],
  )
}

fn coarse_start(role: OsRole) -> Bool {
  case role.os.start {
    identity.CoarseStart(_) -> True
    identity.PreciseStart(_) | identity.UnreadableStart -> False
  }
}

fn anon_readable(role: OsRole) -> Bool {
  role.anon != measure.Missing(measure.UnsupportedOnPlatform)
}

fn role_row(role: OsRole, anon: Bool) -> Element(Msg) {
  html.tr(
    [],
    list.flatten([
      [
        html.td([attribute.class("role-name")], [element.text(role.role)]),
        html.td([attribute.class("num mono")], [
          element.text(int.to_string(role.os.pid)),
        ]),
        ui.num(role.rss, unit.Bytes),
      ],
      case anon {
        True -> [ui.num(role.anon, unit.Bytes)]
        False -> []
      },
      [
        html.td([attribute.class("note-cell")], [
          element.text(
            [role.note, start_note(role.os.start)]
            |> list.filter(fn(part) { part != "" })
            |> string.join(" · "),
          ),
        ]),
      ],
    ]),
  )
}

fn start_note(start: identity.StartIdentity) -> String {
  case start {
    identity.PreciseStart(_) -> ""

    // The row's note already says so, once.
    identity.CoarseStart(_) -> ""
    identity.UnreadableStart -> "start time unreadable"
  }
}

/// The derived gap between two layer readings: the upper layer minus the lower
/// one, or the word for whichever side is absent. A difference with an
/// unknown end is never a number.
///
/// ## Examples
///
/// ```gleam
/// overview.gap(Known(10), Known(4))
/// // -> Known(6)
///
/// overview.gap(Known(10), Missing(CounterDisabled))
/// // -> Missing(CounterDisabled)
/// ```
pub fn gap(upper: Measurement, lower: Measurement) -> Measurement {
  case upper, lower {
    Known(a), Known(b) -> Known(a - b)
    measure.Missing(reason:), _ -> measure.Missing(reason:)
    _, measure.Missing(reason:) -> measure.Missing(reason:)
    _, _ -> measure.NotApplicable
  }
}
