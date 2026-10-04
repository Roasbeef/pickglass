//// Building blocks shared by the page views.
////
//// The panel is the unit of every page. Its header carries a title and the
//// controls that belong to the whole panel. Beneath it, one line says where
//// the data came from, how it was collected, how often, how much of the
//// requested scope it covers and whether anything was cut: source, method,
//// interval, coverage and truncation, in that order and in the same format
//// on every page, so an operator learns where to look. A panel that was cut
//// short colours its truncation segment, so a partial answer cannot pass
//// for a complete one.
////
//// Table cells come from here too, so the rule that a missing reading is a
//// word is applied in one place: `num` writes a measurement and marks a
//// word with the `word` class, `delta` writes a signed change, and
//// `overlap` writes the mark for a column whose rows share what they
//// measure.
////
//// ## Reading order
////
//// `panel` assembles a panel from `meta` (the title-bar line) and a body;
//// `num`, `delta` and `overlap` build cells; `badge`, `note` and `waiting`
//// are small text pieces.

import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/measure.{type Coverage, type Measurement}
import pickglass_core/unit.{type Unit}
import pickglass_web/fmt
import pickglass_web/model.{type PanelInfo}

/// The one-line description of where a panel's data came from, as the
/// parts of the title-bar line in order.
///
/// ## Examples
///
/// ```gleam
/// ui.meta_parts(info)
/// // -> ["census", "process_info bundle v1", "every 10.0 s · took 4 ms",
/// //     "4,812 of 4,812 processes", "complete"]
/// ```
pub fn meta_parts(info: PanelInfo) -> List(String) {
  [
    info.source,
    info.method,
    interval_text(info),
    coverage_text(info.coverage),
    truncation_text(info.coverage.outcome),
  ]
}

fn interval_text(info: PanelInfo) -> String {
  let asked = case info.cadence {
    measure.OneShot -> "one shot"
    measure.EveryMs(interval_ms:) -> "every " <> fmt.duration_ms(interval_ms)
  }

  // The achieved interval is stated only when it fell behind the request;
  // a pass that kept its cadence has nothing to add to "every 2.00 s".
  let behind = case cadence_missed(info.cadence, info.achieved_ms) {
    True ->
      case info.achieved_ms {
        Some(actual) -> " (achieved " <> fmt.duration_ms(actual) <> ")"
        None -> ""
      }
    False -> ""
  }

  case info.took_ms {
    Some(took) -> asked <> behind <> " · took " <> fmt.duration_ms(took)
    None -> asked <> behind
  }
}

fn coverage_text(coverage: Coverage) -> String {
  fmt.count(coverage.achieved)
  <> " of "
  <> fmt.count(coverage.requested)
  <> " "
  <> coverage.scope
}

/// The truncation segment of the title-bar line: `complete`, or what cut the
/// collection short.
///
/// ## Examples
///
/// ```gleam
/// ui.truncation_text(measure.Partial(measure.Truncated(measure.TopKLimit)))
/// // -> "truncated: top_k_limit"
/// ```
pub fn truncation_text(outcome: measure.Outcome) -> String {
  case outcome {
    measure.Complete -> "complete"
    measure.Partial(reason: measure.Truncated(reason:)) ->
      "truncated: " <> measure.truncation_code(reason)
    measure.Partial(reason:) -> "partial: " <> measure.partial_code(reason)
    measure.Refused(reason:) -> "refused: " <> reason
    measure.Errored(reason:) -> "error: " <> reason
    measure.Unrecorded -> "not recorded"
  }
}

/// The title-bar line as an element, one span per segment.
pub fn meta(info: PanelInfo) -> Element(msg) {
  let outcome_class = case info.coverage.outcome {
    measure.Complete -> "meta-seg meta-ok"
    _ -> "meta-seg meta-cut"
  }

  html.p([attribute.class("panel-meta")], [
    seg("meta-seg meta-source", info.source),
    seg("meta-seg", info.method),
    seg(interval_class(info), interval_text(info)),
    seg("meta-seg", coverage_text(info.coverage)),
    seg(outcome_class, truncation_text(info.coverage.outcome)),
  ])
}

/// Whether the interval achieved is slower than the one requested by more
/// than half again: 1.5 times the requested interval or more.
///
/// ## Examples
///
/// ```gleam
/// ui.cadence_missed(measure.EveryMs(1000), Some(1600))
/// // -> True
/// ```
pub fn cadence_missed(cadence: measure.Cadence, achieved: Option(Int)) -> Bool {
  case cadence, achieved {
    measure.EveryMs(interval_ms:), Some(actual) -> actual * 2 >= interval_ms * 3
    measure.EveryMs(_), None | measure.OneShot, _ -> False
  }
}

fn interval_class(info: PanelInfo) -> String {
  case cadence_missed(info.cadence, info.achieved_ms) {
    True -> "meta-seg meta-cut"
    False -> "meta-seg"
  }
}

fn seg(class: String, text: String) -> Element(msg) {
  html.span([attribute.class(class)], [element.text(text)])
}

/// A panel: title, optional controls, the title-bar line and a body.
pub fn panel(
  title title: String,
  info info: PanelInfo,
  controls controls: List(Element(msg)),
  body body: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("panel")], [
    html.header([attribute.class("panel-bar")], [
      html.h2([], [element.text(title)]),
      html.div([attribute.class("panel-controls")], controls),
    ]),
    meta(info),
    html.div([attribute.class("panel-body")], body),
  ])
}

/// A panel with no title-bar line, for a block that is not data from the
/// node, such as the profile's chain.
pub fn plain_panel(
  title title: String,
  body body: List(Element(msg)),
) -> Element(msg) {
  html.section([attribute.class("panel")], [
    html.header([attribute.class("panel-bar")], [
      html.h2([], [element.text(title)]),
    ]),
    html.div([attribute.class("panel-body")], body),
  ])
}

/// A numeric table cell: a measurement in its unit's scale, or the word for
/// an absent reading, marked so the stylesheet can set it apart.
pub fn num(m: Measurement, unit u: Unit) -> Element(msg) {
  html.td([attribute.class(cell_class(m))], [element.text(fmt.cell(m, u))])
}

/// A numeric cell for a signed change.
pub fn delta(m: Measurement, unit u: Unit) -> Element(msg) {
  html.td([attribute.class(delta_class(m))], [element.text(fmt.signed(m, u))])
}

/// A numeric cell for a signed change that carries no direction: the same
/// figure as `delta`, in plain ink.
pub fn delta_plain(m: Measurement, unit u: Unit) -> Element(msg) {
  html.td([attribute.class(plain_class(m))], [element.text(fmt.signed(m, u))])
}

fn plain_class(m: Measurement) -> String {
  case m {
    measure.Known(_) -> "num delta"
    _ -> "num delta word"
  }
}

fn cell_class(m: Measurement) -> String {
  case fmt.is_word(m) {
    fmt.Number -> "num"
    fmt.Word -> "num word"
  }
}

fn delta_class(m: Measurement) -> String {
  case m {
    measure.Known(value:) if value > 0 -> "num delta delta-up"
    measure.Known(value:) if value < 0 -> "num delta delta-down"
    measure.Known(_) -> "num delta"
    _ -> "num delta word"
  }
}

/// A cell for a column whose rows overlap. It shows the row's own reading
/// with the approximation mark, and never a total.
pub fn overlap(m: Measurement, unit u: Unit, why why: String) -> Element(msg) {
  html.td([attribute.class(cell_class(m) <> " approx"), attribute.title(why)], [
    element.text(fmt.cell(m, u) <> " ≈"),
  ])
}

/// A cell that stands in for an overlapping column's total. It says so in
/// words, because no number is right.
pub fn no_total(why why: String) -> Element(msg) {
  html.td([attribute.class("num word approx"), attribute.title(why)], [
    element.text("≈ not summed"),
  ])
}

/// A small label.
pub fn badge(class: String, text: String) -> Element(msg) {
  html.span([attribute.class("badge " <> class)], [element.text(text)])
}

/// A quiet explanatory line.
pub fn note(text: String) -> Element(msg) {
  html.p([attribute.class("note")], [element.text(text)])
}

/// A header cell, with a title for the hover explanation.
pub fn th(label: String, title: Option(String)) -> Element(msg) {
  case title {
    Some(text) -> html.th([attribute.title(text)], [element.text(label)])
    None -> html.th([], [element.text(label)])
  }
}

/// A right-aligned header cell for a numeric column.
pub fn th_num(label: String, title: Option(String)) -> Element(msg) {
  case title {
    Some(text) ->
      html.th([attribute.class("num"), attribute.title(text)], [
        element.text(label),
      ])
    None -> html.th([attribute.class("num")], [element.text(label)])
  }
}

/// What a page shows before the viewer's first feed for it arrives. It is a
/// statement, not a zero.
pub fn waiting(page: String) -> Element(msg) {
  html.div([attribute.class("waiting")], [
    html.h2([], [element.text(page)]),
    html.p([], [
      element.text("Waiting for the viewer's first reading. Nothing is shown "),
      element.text("until a reading exists, because an empty table would "),
      element.text("look like a measured zero."),
    ]),
  ])
}
