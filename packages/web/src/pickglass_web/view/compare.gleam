//// Compare two captures.
////
//// A comparison is only as good as the match between the two captures, so
//// the page puts the match first. The comparability table lists each field
//// that decides whether two captures measure the same thing (collection
//// method, runtime, budgets, workload, warmup, cadence, role, build) with
//// both values and a verdict from core's `provenance.comparability`: the same,
//// different but expected (a new build is the point of a fix), or different
//// in a way that blocks. A blocking difference withholds any statement of
//// direction. The page then says "unmatched" and draws no "improved" or
//// "regressed"; the figures are still shown.
////
//// Verdicts are per column, not per page. A cadence mismatch, for instance,
//// withholds rates and deltas but not gauges. Each row's verdict comes from
//// `provenance.compare_measurements` for the row's series kind, so the page
//// cannot claim a direction core would withhold, and a missing reading on
//// either side has no verdict at all.
////
//// If both captures carry stacks, a differential flame follows, from core's
//// merged layout: red for a regression, blue for an improvement. A figure's
//// change and the flame's colours are a statement of direction too, so they
//// follow the same rule as the verdict column: where the verdict is withheld
//// the change is written in plain ink and the flame is one neutral colour.
//// Width still shows how large the change is.
////
//// ## Reading order
////
//// `view` draws the match (`match_panel`), the figures (`figures_panel`) and
//// the diff (`diff_panel`).

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/profile
import pickglass_core/provenance.{
  type Comparability, type Field, type Provenance,
}
import pickglass_core/unit
import pickglass_web/chart/flame as flame_chart
import pickglass_web/fmt
import pickglass_web/model.{type CompareModel, type CompareRow}
import pickglass_web/msg.{type Msg}
import pickglass_web/view/ui

/// Draw the compare page.
pub fn view(data: CompareModel) -> Element(Msg) {
  let comparability = provenance.comparability(data.baseline, data.candidate)

  html.div([attribute.class("stack")], [
    match_panel(data, comparability),
    figures_panel(data, comparability),
    diff_panel(data, comparability),
  ])
}

fn match_panel(
  data: CompareModel,
  comparability: Comparability,
) -> Element(Msg) {
  let blocking = provenance.blocking_fields(comparability)

  let verdict = case blocking {
    [] -> ui.badge("ok", "comparable")
    fields ->
      ui.badge(
        "block",
        "MISMATCH: "
          <> string.join(list.map(fields, provenance.field_name), ", ")
          <> verb(list.length(fields), " blocks", " block")
          <> " a verdict",
      )
  }

  ui.plain_panel(title: "Comparability", body: [
    html.p([attribute.class("compare-names")], [
      html.strong([], [element.text(data.baseline_name)]),
      element.text("  vs  "),
      html.strong([], [element.text(data.candidate_name)]),
      verdict,
    ]),
    html.table([attribute.class("tbl match")], [
      html.thead([], [
        html.tr([], [
          ui.th("field", None),
          ui.th("baseline", None),
          ui.th("candidate", None),
          ui.th("", None),
        ]),
      ]),
      html.tbody(
        [],
        list.map(comparability.fields, fn(entry) {
          field_row(entry.0, entry.1, data)
        }),
      ),
    ]),
    verdict_summary(comparability),
  ])
}

fn field_row(
  field: Field,
  result: provenance.FieldResult,
  data: CompareModel,
) -> Element(Msg) {
  let #(class, mark, detail) = case result {
    provenance.Same -> #("field-same", "same", "")
    provenance.DiffersExpected -> #("field-expected", "differs (expected)", "")
    provenance.DiffersBlocking(detail:) -> #(
      "field-block",
      "differs, blocks",
      detail,
    )
  }

  html.tr([attribute.class(class)], [
    html.td([], [element.text(provenance.field_name(field))]),
    html.td([attribute.class("mono")], [
      element.text(field_value(field, data.baseline)),
    ]),
    html.td([attribute.class("mono")], [
      element.text(field_value(field, data.candidate)),
    ]),
    html.td([attribute.title(detail)], [ui.badge("field", mark)]),
  ])
}

// The value of one comparability field, written for a person.
fn field_value(field: Field, p: Provenance) -> String {
  case field {
    provenance.Method -> p.collection.method
    provenance.RuntimeField ->
      "OTP " <> p.runtime.otp_release <> " · " <> p.runtime.emulator_flavor
    provenance.Budget ->
      "top "
      <> int.to_string(p.collection.budgets.top_k)
      <> " · "
      <> fmt.duration_ms(p.collection.budgets.deadline_ms)
    provenance.WorkloadField -> p.workload.label
    provenance.Warmup -> fmt.duration_ms(p.workload.warmup_ms)
    provenance.CadenceField ->
      case p.collection.cadence {
        measure.OneShot -> "one shot"
        measure.EveryMs(interval_ms:) ->
          "every " <> fmt.duration_ms(interval_ms)
      }
    provenance.Role -> p.target.role
    provenance.BuildField -> p.build.application <> " " <> p.build.revision
  }
}

/// What each kind of column may say, written as one sentence so a withheld
/// verdict is explained once at the top and not only on each row.
///
/// ## Examples
///
/// ```gleam
/// compare.verdict_text(comparability)
/// // -> "No figure gets a direction: the workload differs. The build
/// //     difference is expected."
/// ```
pub fn verdict_text(comparability: Comparability) -> String {
  let kinds = [
    #("levels", measure.Gauge),
    #("counters", measure.Counter),
    #("rates and deltas", measure.DeltaOverInterval),
  ]

  let allowed =
    list.filter(kinds, fn(kind) {
      provenance.verdict_for(comparability, kind.1)
      == provenance.DirectionAllowed
    })

  let blocking =
    provenance.blocking_fields(comparability)
    |> list.map(provenance.field_name)

  let expected =
    comparability.fields
    |> list.filter(fn(entry) { entry.1 == provenance.DiffersExpected })
    |> list.map(fn(entry) { provenance.field_name(entry.0) })

  let sentence = case allowed, blocking {
    _, [] -> "Every figure may be given a direction."

    [], _ ->
      "No figure gets a direction: the "
      <> string.join(blocking, ", ")
      <> verb(list.length(blocking), " differs.", " differ.")

    _, _ ->
      "Directions are given for "
      <> string.join(list.map(allowed, fn(kind) { kind.0 }), ", ")
      <> " only: the "
      <> string.join(blocking, ", ")
      <> verb(list.length(blocking), " differs.", " differ.")
  }

  case expected {
    [] -> sentence
    _ ->
      sentence
      <> " The "
      <> string.join(expected, ", ")
      <> " difference is expected."
  }
}

fn verdict_summary(comparability: Comparability) -> Element(Msg) {
  html.p([attribute.class("verdict-summary")], [
    element.text(verdict_text(comparability)),
  ])
}

fn figures_panel(
  data: CompareModel,
  comparability: Comparability,
) -> Element(Msg) {
  ui.plain_panel(title: "Figures", body: [
    html.table([attribute.class("tbl")], [
      html.thead([], [
        html.tr([], [
          ui.th("figure", None),
          ui.th_num("baseline", None),
          ui.th_num("candidate", None),
          ui.th_num("Δ", None),
          ui.th("verdict", None),
        ]),
      ]),
      html.tbody(
        [],
        list.map(data.rows, fn(row) { figure_row(row, comparability) }),
      ),
    ]),
  ])
}

fn figure_row(row: CompareRow, comparability: Comparability) -> Element(Msg) {
  html.tr([], [
    html.td([], [element.text(row.label)]),
    ui.num(row.baseline, unit: row.unit),
    ui.num(row.candidate, unit: row.unit),
    change_cell(row, comparability),
    html.td([], [verdict_cell(row, comparability)]),
  ])
}

// The change is coloured only where core allows a direction for this kind of
// column. Otherwise it is the same figure in plain ink, so the cell does not
// say "worse" while the verdict beside it says nothing may be said.
fn change_cell(row: CompareRow, comparability: Comparability) -> Element(Msg) {
  let moved = change(row.baseline, row.candidate)

  case provenance.verdict_for(comparability, row.kind) {
    provenance.DirectionAllowed -> ui.delta(moved, unit: row.unit)
    provenance.DirectionWithheld(..) -> ui.delta_plain(moved, unit: row.unit)
  }
}

// The change is a difference of two known readings; with either absent it
// is the word for the absent one, never a number.
fn change(baseline: Measurement, candidate: Measurement) -> Measurement {
  case baseline, candidate {
    Known(b), Known(c) -> Known(c - b)
    measure.Missing(reason:), _ -> measure.Missing(reason:)
    _, measure.Missing(reason:) -> measure.Missing(reason:)
    _, _ -> measure.NotApplicable
  }
}

fn verdict_cell(row: CompareRow, comparability: Comparability) -> Element(Msg) {
  case
    provenance.compare_measurements(
      comparability,
      row.kind,
      row.baseline,
      row.candidate,
    )
  {
    provenance.Moved(direction: provenance.Increased) ->
      ui.badge("up", "higher")
    provenance.Moved(direction: provenance.Decreased) ->
      ui.badge("down", "lower")
    provenance.Moved(direction: provenance.Unchanged) ->
      ui.badge("muted", "unchanged")
    provenance.Withheld(blocking:) ->
      ui.badge(
        "block",
        "unmatched: "
          <> string.join(list.map(blocking, provenance.field_name), ", "),
      )
    provenance.NoReading -> ui.badge("muted", "no reading")
  }
}

fn diff_panel(
  data: CompareModel,
  comparability: Comparability,
) -> Element(Msg) {
  case data.diff {
    None ->
      ui.plain_panel(title: "Differential flame", body: [
        ui.note(
          "The captures do not both carry call stacks, so there is no differential flame.",
        ),
      ])
    Some(diff) -> {
      let merged = diff.profile
      let name_of = fn(id) { profile.name_of(merged, id) }

      let blocking =
        provenance.blocking_fields(comparability)
        |> list.map(provenance.field_name)

      let verdict = case blocking {
        [] -> flame_chart.Directed
        _ -> flame_chart.Withheld
      }

      ui.plain_panel(title: "Differential flame", body: [
        html.div([attribute.class("graph-frame")], [
          flame_chart.view(
            layout: diff.layout,
            facing: flame_chart.RootBelow,
            name_of:,
            unit: unit.Count,
            selected: None,
            search: "",
            verdict:,
            on_select: fn(box) { msg.Ui(msg.SelectBox(box)) },
          ),
        ]),
        legend(blocking),
      ])
    }
  }
}

// The colour key, or the statement that there is no colour to key.
fn legend(blocking: List(String)) -> Element(Msg) {
  case blocking {
    [] ->
      html.p([attribute.class("legend-inline")], [
        ui.badge("up", "red: grew since the baseline"),
        ui.badge("down", "blue: shrank"),
        ui.badge("muted", "grey: unchanged"),
      ])
    fields ->
      html.p([attribute.class("legend-inline")], [
        ui.badge(
          "block",
          "withheld: "
            <> string.join(fields, ", ")
            <> verb(list.length(fields), " differs", " differ"),
        ),
        ui.note(
          "Boxes are one colour because the captures are not comparable. "
          <> "Width is the size of the change, not its direction.",
        ),
      ])
  }
}

// The verb form that agrees with how many fields the sentence names.
fn verb(count: Int, singular: String, plural: String) -> String {
  case count {
    1 -> singular
    _ -> plural
  }
}
