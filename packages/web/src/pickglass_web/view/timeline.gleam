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
//// A scheduling and collection probe, and a call tree probe that kept call
//// slices, are drawn below the polled timeline, each on a time axis of its
//// own. Their slices count from the start of the probe, and the viewer's
//// passes are stamped on the wall clock, so the two are not aligned and the
//// page does not pretend they are.
////
//// ## Reading order
////
//// `view` draws the chart from `chart/timeline` and a table of gaps, then
//// `events_panel` and `calls_panel` for the tracing probes.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import pickglass_core/unit
import pickglass_web/chart/activity
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/fmt
import pickglass_web/msg.{type Msg}
import pickglass_web/state.{type UiState}
import pickglass_web/timeline_model.{
  type CallsTimeline, type CoverageGap, type EventsTimeline, type TimelineModel,
}
import pickglass_web/view/profile as profile_view
import pickglass_web/view/ui
import pickglass_web/wire

/// Draw the timeline page.
pub fn view(data: TimelineModel, ui_state: UiState) -> Element(Msg) {
  html.div([attribute.class("stack")], [
    polled_panel(data, ui_state),
    events_panel(data.events),
    calls_panel(data.calls),
    case data.exports {
      [] -> element.none()
      notes -> profile_view.export_notes(notes)
    },
  ])
}

fn polled_panel(data: TimelineModel, ui_state: UiState) -> Element(Msg) {
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

// ------------------------------------------------- scheduling and collection

// The scheduling and collection probe: the slices of each traced process, the
// per-process totals the probe counted over the whole window (the slices are
// the first ones to close, so the totals are the figures to read), and the
// threshold events of the whole node.
fn events_panel(events: Option(EventsTimeline)) -> Element(Msg) {
  case events {
    None -> element.none()
    Some(data) ->
      ui.panel(
        title: "Scheduling and collections · probe " <> data.probe,
        info: data.info,
        controls: [export_button(msg.EventsTrace)],
        body: [
          html.div([attribute.class("graph-frame")], [activity.events(data)]),
          legend(),
          notes(data.notes),
          totals_table(data),
          long_table(data),
        ],
      )
  }
}

fn export_button(which: msg.TraceExport) -> Element(Msg) {
  html.button(
    [
      attribute.class("btn btn-small"),
      attribute.type_("button"),
      attribute.data("test-id", "export-trace"),
      wire.click(msg.Ask(msg.ExportTrace(which))),
    ],
    [element.text("Chrome trace")],
  )
}

fn legend() -> Element(Msg) {
  html.p([attribute.class("legend-line")], [
    html.span([attribute.class("swatch swatch-run")], []),
    element.text(" run on a scheduler  "),
    html.span([attribute.class("swatch swatch-gc-minor")], []),
    element.text(" minor collection  "),
    html.span([attribute.class("swatch swatch-gc-major")], []),
    element.text(" major collection  "),
    html.span([attribute.class("swatch swatch-window")], []),
    element.text(" observed window"),
  ])
}

fn notes(sentences: List(String)) -> Element(Msg) {
  html.ul(
    [attribute.class("caveats"), attribute.data("test-id", "trace-notes")],
    list.map(sentences, fn(text) { html.li([], [element.text(text)]) }),
  )
}

fn totals_table(data: EventsTimeline) -> Element(Msg) {
  let observed = int.max(1, data.observed_ns)

  html.table(
    [attribute.class("tbl compact"), attribute.data("test-id", "trace-totals")],
    [
      html.thead([], [
        html.tr([], [
          ui.th("process", None),
          ui.th_num("runs", None),
          ui.th_num(
            "time on scheduler",
            Some(
              "the closest the BEAM comes to per-process CPU time; it includes any time the operating system took the scheduler thread away",
            ),
          ),
          ui.th_num("of observed time", None),
          ui.th_num("minor GCs", None),
          ui.th_num("major GCs", None),
          ui.th_num("GC time", None),
        ]),
      ]),
      html.tbody(
        [],
        list.map(data.tracks, fn(track) {
          html.tr([], [
            html.td([attribute.class("mono")], [element.text(track.label)]),
            html.td([attribute.class("num")], [
              element.text(fmt.count(track.runs)),
            ]),
            html.td([attribute.class("num")], [
              element.text(fmt.nanoseconds(track.run_ns)),
            ]),
            html.td([attribute.class("num")], [
              element.text(fmt.share(track.run_ns, of: observed)),
            ]),
            html.td([attribute.class("num")], [
              element.text(fmt.count(track.minor_gcs)),
            ]),
            html.td([attribute.class("num")], [
              element.text(fmt.count(track.major_gcs)),
            ]),
            html.td([attribute.class("num")], [
              element.text(fmt.nanoseconds(track.gc_ns)),
            ]),
          ])
        }),
      ),
    ],
  )
}

// The threshold events. The VM reports a duration and a process, not a time,
// so the table has no time column and the chart no position for them.
fn long_table(data: EventsTimeline) -> Element(Msg) {
  case data.long {
    [] ->
      ui.note(case data.long_gc_ms, data.long_schedule_ms {
        0, 0 -> "The node-wide thresholds were not set for this probe."
        gc, schedule ->
          "No collection of "
          <> int.to_string(gc)
          <> " ms or more and no timeslice of "
          <> int.to_string(schedule)
          <> " ms or more was reported on the node."
      })
    longs ->
      html.div([], [
        html.table(
          [
            attribute.class("tbl compact"),
            attribute.data("test-id", "long-events"),
          ],
          [
            html.thead([], [
              html.tr([], [
                ui.th("event", None),
                ui.th("process", None),
                ui.th_num("duration", None),
                ui.th("detail", None),
              ]),
            ]),
            html.tbody([], list.map(longs, long_row)),
          ],
        ),
        ui.note(
          "Threshold events concern any process on the node, not only the "
          <> "traced ones, and the VM reports no time for them: "
          <> int.to_string(data.long_seen)
          <> " were seen and the agent keeps the first "
          <> int.to_string(list.length(data.long))
          <> ".",
        ),
      ])
  }
}

fn long_row(marker: timeline_model.LongMarker) -> Element(Msg) {
  case marker {
    timeline_model.LongGcMarker(process:, duration_ms:, heap_words:) ->
      html.tr([], [
        html.td([], [ui.badge("warn", "long_gc")]),
        html.td([attribute.class("mono")], [element.text(process)]),
        html.td([attribute.class("num")], [
          element.text(fmt.duration_ms(duration_ms)),
        ]),
        html.td([], [element.text("heap " <> fmt.count(heap_words) <> " words")]),
      ])
    timeline_model.LongScheduleMarker(process:, duration_ms:, function:) ->
      html.tr([], [
        html.td([], [ui.badge("warn", "long_schedule")]),
        html.td([attribute.class("mono")], [element.text(process)]),
        html.td([attribute.class("num")], [
          element.text(fmt.duration_ms(duration_ms)),
        ]),
        html.td([attribute.class("mono")], [
          element.text(case function {
            "" -> "no function named"
            named -> "in " <> named
          }),
        ]),
      ])
  }
}

// ------------------------------------------------------------------- calls

fn calls_panel(calls: Option(CallsTimeline)) -> Element(Msg) {
  case calls {
    None -> element.none()
    Some(data) -> {
      let hidden = activity.hidden_calls(data.tracks)

      let drawn =
        list.fold(data.tracks, 0, fn(total, track) {
          total + list.length(track.calls)
        })

      ui.panel(
        title: "Calls · probe " <> data.probe,
        info: data.info,
        controls: [export_button(msg.CallsTrace)],
        body: [
          html.div([attribute.class("graph-frame")], [activity.calls(data)]),
          notes(data.notes),
          ui.note(case drawn {
            0 -> "No call finished in the window, so nothing is drawn."
            _ ->
              "The first "
              <> fmt.count(drawn)
              <> " calls to finish are drawn, nested under their callers. A call "
              <> "is drawn when it returns, so a call still running when the "
              <> "probe stopped is closed at the last event seen."
              <> case hidden {
                0 -> ""
                count ->
                  " "
                  <> fmt.count(count)
                  <> " calls nested deeper than "
                  <> int.to_string(activity.max_call_rows)
                  <> " levels are not drawn."
              }
          }),
        ],
      )
    }
  }
}
