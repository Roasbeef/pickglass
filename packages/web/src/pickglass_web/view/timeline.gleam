//// The timeline page.
////
//// A timeline is the one place where a gap in the data can be mistaken for
//// quiet, so the page is built around not letting that happen. Polled
//// counters are drawn as steps as wide as their sampling interval and are
//// never interpolated: between two readings the value is unknown, not
//// smoothly changing. A missing reading is a hatched step. Where the
//// collector dropped evidence, a hatched band crosses every track and the
//// gaps are listed below with their reason and the number of events lost.
////
//// The clock note says which clock the tracks share and its error, because
//// spans from the host and events from the node are only aligned when both
//// carry the same clock.
////
//// ## Reading order
////
//// `view` draws the chart from `chart/timeline` and a table of gaps.

import gleam/list
import gleam/option.{None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/unit
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/fmt
import pickglass_web/model.{type CoverageGap, type TimelineModel}
import pickglass_web/msg.{type Msg}
import pickglass_web/state.{type UiState}
import pickglass_web/view/ui

/// Draw the timeline page.
pub fn view(data: TimelineModel, ui_state: UiState) -> Element(Msg) {
  ui.panel(
    title: "Timeline · window " <> fmt.duration_ms(data.window_ms),
    info: data.info,
    controls: [
      html.span([attribute.class("chip")], [element.text(data.clock_note)]),
    ],
    body: [
      html.div([attribute.class("graph-frame")], [
        timeline_chart.view(
          window_ms: data.window_ms,
          tracks: data.tracks,
          gaps: data.gaps,
          selected: ui_state.selected,
          on_select: fn(item) { msg.Ui(msg.SelectReading(item)) },
        ),
      ]),
      selection_line(data, ui_state),
      gap_list(data.gaps),
      ui.note(
        "Counters read by polling are known only at their readings: each bar "
        <> "stands for one sampling interval and nothing is interpolated. "
        <> "Hatched bars are readings that could not be taken.",
      ),
    ],
  )
}

// The persistent line for the chosen reading or span, the counterpart of the
// flame's selection line.
fn selection_line(data: TimelineModel, ui_state: UiState) -> Element(Msg) {
  let described = case ui_state.selected {
    Some(chosen) -> timeline_chart.describe(data.tracks, chosen)
    None -> Error(Nil)
  }

  case described {
    Ok(text) -> html.p([attribute.class("selection")], [element.text(text)])
    Error(Nil) -> ui.note("Click a bar to read its value.")
  }
}

fn gap_list(gaps: List(CoverageGap)) -> Element(Msg) {
  case gaps {
    [] -> ui.note("No evidence was dropped in this window.")
    _ ->
      html.table([attribute.class("tbl compact")], [
        html.thead([], [
          html.tr([], [
            ui.th("gap", None),
            ui.th_num("events dropped", None),
            ui.th("reason", None),
          ]),
        ]),
        html.tbody([], list.map(gaps, gap_row)),
      ])
  }
}

fn gap_row(gap: CoverageGap) -> Element(Msg) {
  html.tr([], [
    html.td([attribute.class("num")], [
      element.text(
        "+"
        <> fmt.duration_ms(gap.from_ms)
        <> " to +"
        <> fmt.duration_ms(gap.to_ms),
      ),
    ]),
    ui.num(gap.dropped, unit.Count),
    html.td([], [element.text(gap.reason)]),
  ])
}
