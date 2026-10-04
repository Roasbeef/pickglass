//// Memory categories, allocators and tables.
////
//// Memory figures from a VM are not all addends of one sum. `erlang:memory`
//// reports `total` beside the categories that make it up; allocator
//// carriers are capacity and `erlang:memory` is use, so they overlap; a
//// binary counted under `binary` may also be referenced from process heaps.
//// Each row therefore carries an `Additivity` from core. An additive row is
//// drawn plainly. An overlapping row is drawn with the approximation sign and
//// its reason on hover and in the notes below the table.
////
//// Each table ends with the sum of its additive rows, from `measure.sum`,
//// which counts missing rows beside the total and refuses to produce a total
//// when none is known. The page prints what `measure.render_total` says, so
//// a total over a table with a missing row reads "at least".
////
//// ## Reading order
////
//// `view` draws three panels with `category_table`; `total_row` computes the
//// footer.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure
import pickglass_core/unit
import pickglass_web/fmt
import pickglass_web/model.{type CategoryRow, type MemoryModel, type Panel}
import pickglass_web/msg.{type Msg}
import pickglass_web/view/ui

// Which columns a table draws. An allocator table has capacity, use and the
// unused part; a table of categories has one value.
type Columns {
  ValueOnly
  CapacityAndUse
}

fn column_count(columns: Columns) -> Int {
  case columns {
    ValueOnly -> 3
    CapacityAndUse -> 5
  }
}

/// Draw the memory page.
pub fn view(data: MemoryModel) -> Element(Msg) {
  html.div([attribute.class("grid memory")], [
    category_panel("Categories (erlang:memory)", data.categories),
    category_panel("Allocators", data.allocators),
    category_panel("Tables and binaries", data.tables),
  ])
}

fn category_panel(
  title: String,
  panel: Panel(List(CategoryRow)),
) -> Element(Msg) {
  // Capacity and use are separate readings for an allocator, and the unused
  // part is the figure that says where memory is held without being used.
  // A table whose rows have no such split does not draw the two columns.
  let columns = case
    list.any(panel.body, fn(row) {
      case row.used {
        measure.Known(_) -> True
        measure.Missing(_) | measure.NotApplicable -> False
      }
    })
  {
    True -> CapacityAndUse
    False -> ValueOnly
  }

  ui.panel(title:, info: panel.info, controls: [], body: [
    html.table([attribute.class("tbl")], [
      html.thead([], [
        html.tr([], case columns {
          CapacityAndUse -> [
            ui.th("category", None),
            ui.th_num("capacity", None),
            ui.th_num("used", None),
            ui.th_num(
              "unused",
              Some("capacity minus used: derived, memory held and not in use"),
            ),
            ui.th("what it is", None),
          ]
          ValueOnly -> [
            ui.th("category", None),
            ui.th_num("value", None),
            ui.th("what it is", None),
          ]
        }),
      ]),
      html.tbody([], list.map(panel.body, category_row(_, columns))),
      html.tfoot([], [total_row(panel.body, columns)]),
    ]),
    overlap_notes(panel.body),
  ])
}

fn category_row(row: CategoryRow, columns: Columns) -> Element(Msg) {
  let cell = case row.additivity {
    measure.Additive -> ui.num(row.value, unit: row.unit)
    measure.Overlapping(why:) -> ui.overlap(row.value, unit: row.unit, why:)
  }
  let label = html.td([attribute.class("category")], [element.text(row.label)])
  let note = html.td([attribute.class("note-cell")], [element.text(row.note)])

  html.tr([], case columns {
    CapacityAndUse -> [
      label,
      cell,
      ui.num(row.used, unit: row.unit),
      ui.num(unused_of(row), unit: row.unit),
      note,
    ]
    ValueOnly -> [label, cell, note]
  })
}

// Capacity less use, when both were read. A row that has no split has no
// unused part, which is not a part of zero.
fn unused_of(row: CategoryRow) -> measure.Measurement {
  case row.value, row.used {
    measure.Known(capacity), measure.Known(used) ->
      measure.Known(int.max(0, capacity - used))
    measure.Missing(reason), _ | _, measure.Missing(reason) ->
      measure.Missing(reason)
    measure.Known(_), measure.NotApplicable | measure.NotApplicable, _ ->
      measure.NotApplicable
  }
}

// The footer sums only the additive byte rows. A refusal is shown in words.
fn total_row(rows: List(CategoryRow), columns: Columns) -> Element(Msg) {
  let additive =
    list.filter(rows, fn(row) {
      row.additivity == measure.Additive && row.unit == unit.Bytes
    })

  let text = case
    measure.sum(
      unit.Bytes,
      measure.Additive,
      list.map(additive, fn(r) { r.value }),
    )
  {
    Ok(total) -> "Sum of additive rows: " <> fmt.total(total, unit.Bytes)
    Error(measure.NothingKnown) -> "No sum: no additive row was read."
    Error(measure.OverlappingRows(why:)) -> "No sum: " <> why
    Error(measure.RatioDoesNotAdd) -> "No sum: ratios do not add."
  }

  html.tr([attribute.class("total")], [
    html.td(
      [
        attribute.attribute("colspan", int.to_string(column_count(columns))),
        attribute.class("total-cell"),
      ],
      [
        element.text(text),
      ],
    ),
  ])
}

// The reasons rows overlap, each said once. Rows that share a reason are
// named together before it, so a table of thirteen allocators does not repeat
// one sentence thirteen times.
fn overlap_notes(rows: List(CategoryRow)) -> Element(Msg) {
  let pairs =
    list.filter_map(rows, fn(row) {
      case row.additivity {
        measure.Additive -> Error(Nil)
        measure.Overlapping(why:) -> Ok(#(why, row.label))
      }
    })
  let reasons = list.unique(list.map(pairs, fn(pair) { pair.0 }))
  let sentences =
    list.map(reasons, fn(why) {
      let labels =
        list.filter_map(pairs, fn(pair) {
          case pair.0 == why {
            True -> Ok(pair.1)
            False -> Error(Nil)
          }
        })

      string.join(labels, ", ") <> ": " <> with_period(why)
    })

  case sentences {
    [] -> element.none()
    _ -> ui.note("≈ rows overlap other rows. " <> string.join(sentences, " "))
  }
}

fn with_period(sentence: String) -> String {
  case string.ends_with(sentence, ".") {
    True -> sentence
    False -> sentence <> "."
  }
}
