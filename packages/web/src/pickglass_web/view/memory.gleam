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

import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure
import pickglass_core/unit
import pickglass_web/model.{type CategoryRow, type MemoryModel, type Panel}
import pickglass_web/msg.{type Msg}
import pickglass_web/view/ui

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
  ui.panel(title:, info: panel.info, controls: [], body: [
    html.table([attribute.class("tbl")], [
      html.thead([], [
        html.tr([], [
          ui.th("category", None),
          ui.th_num("value", None),
          ui.th("what it is", None),
        ]),
      ]),
      html.tbody([], list.map(panel.body, category_row)),
      html.tfoot([], [total_row(panel.body)]),
    ]),
    overlap_notes(panel.body),
  ])
}

fn category_row(row: CategoryRow) -> Element(Msg) {
  let cell = case row.additivity {
    measure.Additive -> ui.num(row.value, unit: row.unit)
    measure.Overlapping(why:) -> ui.overlap(row.value, unit: row.unit, why:)
  }

  html.tr([], [
    html.td([attribute.class("category")], [element.text(row.label)]),
    cell,
    html.td([attribute.class("note-cell")], [element.text(row.note)]),
  ])
}

// The footer sums only the additive byte rows. A refusal is shown in words.
fn total_row(rows: List(CategoryRow)) -> Element(Msg) {
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
    Ok(total) ->
      "Sum of additive rows: " <> measure.render_total(total, unit.Bytes)
    Error(measure.NothingKnown) -> "No sum: no additive row was read."
    Error(measure.OverlappingRows(why:)) -> "No sum: " <> why
    Error(measure.RatioDoesNotAdd) -> "No sum: ratios do not add."
  }

  html.tr([attribute.class("total")], [
    html.td(
      [attribute.attribute("colspan", "3"), attribute.class("total-cell")],
      [
        element.text(text),
      ],
    ),
  ])
}

fn overlap_notes(rows: List(CategoryRow)) -> Element(Msg) {
  let reasons =
    rows
    |> list.filter_map(fn(row) {
      case row.additivity {
        measure.Additive -> Error(Nil)
        measure.Overlapping(why:) -> Ok(row.label <> ": " <> why)
      }
    })

  case reasons {
    [] -> element.none()
    _ -> ui.note("≈ rows overlap other rows. " <> string.join(reasons, " "))
  }
}
