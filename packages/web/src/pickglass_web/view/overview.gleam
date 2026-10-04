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
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
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
    html.button(
      [
        attribute.class("btn"),
        attribute.type_("button"),
        wire.click(msg.Ask(msg.TakeCheckpoint)),
      ],
      [element.text("Checkpoint now")],
    ),
  ]
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

fn roles_panel(data: OverviewModel) -> Element(Msg) {
  ui.panel(
    title: "OS processes by role",
    info: data.roles.info,
    controls: [],
    body: [
      html.table([attribute.class("tbl")], [
        html.thead([], [
          html.tr([], [
            ui.th("role", None),
            ui.th_num("os pid", None),
            ui.th_num("RSS", None),
            ui.th_num("anon", None),
            ui.th("", None),
          ]),
        ]),
        html.tbody([], list.map(data.roles.body, role_row)),
      ]),
    ],
  )
}

fn role_row(role: OsRole) -> Element(Msg) {
  html.tr([], [
    html.td([attribute.class("role-name")], [element.text(role.role)]),
    html.td([attribute.class("num mono")], [
      element.text(int.to_string(role.os.pid)),
    ]),
    ui.num(role.rss, unit.Bytes),
    ui.num(role.anon, unit.Bytes),
    html.td([attribute.class("note-cell")], [
      element.text(role.note <> start_note(role.os.start)),
    ]),
  ])
}

fn start_note(start: identity.StartIdentity) -> String {
  case start {
    identity.PreciseStart(_) -> ""
    identity.CoarseStart(_) -> " · start time coarse"
    identity.UnreadableStart -> " · start time unreadable"
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
