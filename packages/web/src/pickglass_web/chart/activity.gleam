//// The slices of a tracing probe as SVG: runs and collections per process,
//// and nested calls per process.
////
//// The polled timeline (`chart/timeline`) draws readings taken at passes, so
//// a bar there is a width of time the reading stands for. A tracing probe is
//// different in kind. It saw every run and every collection of a traced
//// process, and each is a slice with a start and a length, so it is drawn at
//// its real position and width and never smoothed. A slice shorter than a
//// pixel is drawn one pixel wide so that it can be seen, and its hover text
//// gives its true length.
////
//// The probe's own time axis starts at zero when the probe started. Where the
//// probe stopped before the end of the window it was asked for (its event
//// budget ran out, the collector fell behind, the operator stopped it, every
//// target exited), only the part it observed is shaded: the rest of the axis
//// is a stretch nobody watched, and leaving it plain says so.
////
//// A scheduling track draws runs and collections on one row per process, a
//// minor collection and a major one in different colours so a sweep of the
//// whole heap stands out. A call track draws a row per depth, so a callee sits
//// under its caller. Rows deeper than `max_call_rows` are not drawn, and
//// `hidden_calls` counts the calls left out so the page can say so.
////
//// The node-wide threshold events carry no time (the VM reports a duration
//// and a pid, not when it happened), so they are drawn as glyphs in the
//// margin beside the row of the process they name, never at a position on the
//// axis, which would claim a time nobody reported.
////
//// ## Reading order
////
//// `events` draws a scheduling probe, `calls` a call tree probe; both share
//// `axis`, `shade` and the scale from `x_of` and `width_of`.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg
import pickglass_web/chart/svg_util
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/fmt
import pickglass_web/timeline_model.{
  type ActivitySlice, type CallBox, type CallTrack, type CallsTimeline,
  type EventsTimeline, type LongMarker, type TracedTrack,
}

const label_width: Int = 170

const plot_width: Int = 1000

const margin_width: Int = 112

const axis_height: Int = 26

/// The height of a scheduling track, in pixels.
const track_height: Int = 26

/// The height of one depth row of a call track, in pixels.
const call_row: Int = 14

/// The deepest call level drawn. A call below it is counted, not drawn.
pub const max_call_rows: Int = 8

/// The most threshold glyphs drawn beside one process. The rest are in the
/// table below the chart.
const max_glyphs: Int = 6

// ------------------------------------------------------------------ scale

/// The length of the axis in nanoseconds: the window the probe was asked for,
/// or the time it observed or the end of its last slice if either is longer,
/// and never zero.
///
/// ## Examples
///
/// ```gleam
/// activity.axis_ns(5_000_000_000, 1_200_000_000, 1_000_000_000)
/// // -> 5_000_000_000
/// ```
pub fn axis_ns(window_ns: Int, observed_ns: Int, last_end_ns: Int) -> Int {
  int.max(1, int.max(window_ns, int.max(observed_ns, last_end_ns)))
}

/// The pixel offset of a time on the axis.
///
/// ## Examples
///
/// ```gleam
/// activity.x_of(500, 1000)
/// // -> 670
/// ```
pub fn x_of(ns: Int, axis: Int) -> Int {
  label_width + int.max(0, ns) * plot_width / int.max(1, axis)
}

/// The pixel width of a duration, at least one pixel so that a very short
/// slice can be seen.
///
/// ## Examples
///
/// ```gleam
/// activity.width_of(1, 1_000_000_000)
/// // -> 1
/// ```
pub fn width_of(ns: Int, axis: Int) -> Int {
  int.max(1, int.max(0, ns) * plot_width / int.max(1, axis))
}

/// The end of the last slice of a list of scheduling tracks, in nanoseconds.
///
/// ## Examples
///
/// ```gleam
/// activity.last_end(tracks)
/// // -> 4_800_000
/// ```
pub fn last_end(tracks: List(TracedTrack)) -> Int {
  list.fold(tracks, 0, fn(latest, track) {
    list.fold(track.slices, latest, fn(inner, slice) {
      int.max(inner, slice.start_ns + slice.duration_ns)
    })
  })
}

/// The end of the last call of a list of call tracks, in nanoseconds.
///
/// ## Examples
///
/// ```gleam
/// activity.last_call_end(tracks)
/// // -> 4_800_000
/// ```
pub fn last_call_end(tracks: List(CallTrack)) -> Int {
  list.fold(tracks, 0, fn(latest, track) {
    list.fold(track.calls, latest, fn(inner, call) {
      int.max(inner, call.start_ns + call.duration_ns)
    })
  })
}

/// How many calls of a call timeline are deeper than the rows drawn.
///
/// ## Examples
///
/// ```gleam
/// activity.hidden_calls(tracks)
/// // -> 0
/// ```
pub fn hidden_calls(tracks: List(CallTrack)) -> Int {
  list.fold(tracks, 0, fn(total, track) {
    total + list.count(track.calls, fn(call) { call.depth >= max_call_rows })
  })
}

// ----------------------------------------------------------- scheduling

/// Draw a scheduling and collection probe: a row per traced process with its
/// runs and collections as slices, the observed part of the window shaded,
/// and the node-wide threshold events as glyphs in the margin.
///
/// ## Examples
///
/// ```gleam
/// activity.events(timeline)
/// ```
pub fn events(timeline: EventsTimeline) -> Element(msg) {
  let axis =
    axis_ns(timeline.window_ns, timeline.observed_ns, last_end(timeline.tracks))
  let plot_height = list.length(timeline.tracks) * track_height

  svg.svg(
    [
      svg_util.view_box(
        label_width + plot_width + margin_width,
        plot_height + axis_height,
      ),
      attribute.class("graph timeline events"),
      attribute.attribute("role", "img"),
      attribute.attribute("aria-label", "Scheduling and collection timeline"),
    ],
    [
      shade(timeline.observed_ns, axis, plot_height),
      svg.g(
        [],
        list.index_map(timeline.tracks, fn(track, index) {
          scheduling_track(track, index, axis, long_for(timeline.long, track))
        }),
      ),
      axis_line(axis, plot_height),
    ],
  )
}

// The part of the axis the probe watched. It runs from zero to the time the
// probe observed, so a probe that stopped early leaves the rest plain.
fn shade(observed_ns: Int, axis: Int, plot_height: Int) -> Element(msg) {
  svg.g([attribute.class("act-window")], [
    svg.title([], [
      element.text(
        "observed for "
        <> fmt.duration_ms(observed_ns / 1_000_000)
        <> "; the rest of the axis was not watched",
      ),
    ]),
    svg.rect([
      svg_util.num("x", label_width),
      svg_util.num("y", 0),
      svg_util.num("width", width_of(observed_ns, axis)),
      svg_util.num("height", plot_height),
      attribute.class("act-window-band"),
    ]),
  ])
}

fn scheduling_track(
  track: TracedTrack,
  index: Int,
  axis: Int,
  marks: List(LongMarker),
) -> Element(msg) {
  let y = index * track_height

  svg.g([attribute.class("track")], [
    svg.text(
      [
        svg_util.num("x", 0),
        svg_util.num("y", y + track_height / 2 + 4),
        attribute.class("track-label mono"),
      ],
      svg_util.fit(track.label, label_width, 7),
    ),
    svg.line([
      svg_util.num("x1", label_width),
      svg_util.num("y1", y + track_height - 3),
      svg_util.num("x2", label_width + plot_width),
      svg_util.num("y2", y + track_height - 3),
      attribute.class("track-base"),
    ]),
    svg.g([], list.map(track.slices, fn(slice) { slice_rect(slice, y, axis) })),
    glyphs(marks, y),
  ])
}

fn slice_rect(slice: ActivitySlice, y: Int, axis: Int) -> Element(msg) {
  let #(class, name) = case slice.kind {
    timeline_model.RunActivity -> #("act act-run", "run")
    timeline_model.MinorGcActivity -> #("act act-gc-minor", "minor collection")
    timeline_model.MajorGcActivity -> #("act act-gc-major", "major collection")
  }

  svg.g([], [
    svg.title([], [
      element.text(
        name
        <> " · +"
        <> fmt.nanoseconds(slice.start_ns)
        <> " for "
        <> fmt.nanoseconds(slice.duration_ns),
      ),
    ]),
    svg.rect([
      svg_util.num("x", x_of(slice.start_ns, axis)),
      svg_util.num("y", y + 4),
      svg_util.num("width", width_of(slice.duration_ns, axis)),
      svg_util.num("height", track_height - 10),
      attribute.class(class),
    ]),
  ])
}

// The threshold events that name this process, as glyphs in the margin right
// of the plot: a diamond for a long collection and a triangle for a long
// timeslice. They sit in a row from the margin's left edge because the VM
// reports no time for them.
fn long_for(long: List(LongMarker), track: TracedTrack) -> List(LongMarker) {
  list.filter(long, fn(marker) { process_of(marker) == pid_of(track.label) })
}

fn process_of(marker: LongMarker) -> String {
  case marker {
    timeline_model.LongGcMarker(process:, ..) -> process
    timeline_model.LongScheduleMarker(process:, ..) -> process
  }
}

// A track's label starts with the pid text; an owner label may follow it.
fn pid_of(label: String) -> String {
  case string.split_once(label, " ") {
    Ok(#(pid, _)) -> pid
    Error(Nil) -> label
  }
}

fn glyphs(marks: List(LongMarker), y: Int) -> Element(msg) {
  svg.g(
    [attribute.class("long-marks")],
    list.index_map(list.take(marks, max_glyphs), fn(marker, position) {
      let x = label_width + plot_width + 10 + position * 16
      let cy = y + track_height / 2

      case marker {
        timeline_model.LongGcMarker(duration_ms:, heap_words:, ..) ->
          svg.g([], [
            svg.title([], [
              element.text(
                "long_gc · "
                <> int.to_string(duration_ms)
                <> " ms · heap "
                <> fmt.count(heap_words)
                <> " words · time not reported",
              ),
            ]),
            svg.polygon([
              attribute.attribute(
                "points",
                svg_util.points([
                  #(x, cy - 6),
                  #(x + 6, cy),
                  #(x, cy + 6),
                  #(x - 6, cy),
                ]),
              ),
              attribute.class("long-gc"),
            ]),
          ])
        timeline_model.LongScheduleMarker(duration_ms:, function:, ..) ->
          svg.g([], [
            svg.title([], [
              element.text(
                "long_schedule · "
                <> int.to_string(duration_ms)
                <> " ms · in "
                <> function_text(function)
                <> " · time not reported",
              ),
            ]),
            svg.polygon([
              attribute.attribute(
                "points",
                svg_util.points([
                  #(x, cy - 6),
                  #(x + 6, cy + 5),
                  #(x - 6, cy + 5),
                ]),
              ),
              attribute.class("long-schedule"),
            ]),
          ])
      }
    }),
  )
}

fn function_text(function: String) -> String {
  case function {
    "" -> "an unnamed function"
    named -> named
  }
}

// ------------------------------------------------------------------ calls

/// Draw a call tree probe's calls: a block per process, a row per depth, each
/// call as a slice under its caller.
///
/// ## Examples
///
/// ```gleam
/// activity.calls(timeline)
/// ```
pub fn calls(timeline: CallsTimeline) -> Element(msg) {
  let axis =
    axis_ns(
      timeline.window_ns,
      timeline.observed_ns,
      last_call_end(timeline.tracks),
    )
  let heights = list.map(timeline.tracks, call_track_height)
  let plot_height = list.fold(heights, 0, int.add)

  svg.svg(
    [
      svg_util.view_box(
        label_width + plot_width + margin_width,
        plot_height + axis_height,
      ),
      attribute.class("graph timeline calls"),
      attribute.attribute("role", "img"),
      attribute.attribute("aria-label", "Call timeline"),
    ],
    [
      shade(timeline.observed_ns, axis, plot_height),
      svg.g(
        [],
        list.index_map(timeline.tracks, fn(track, index) {
          let top = list.fold(list.take(heights, index), 0, int.add)

          call_track(track, top, axis)
        }),
      ),
      axis_line(axis, plot_height),
    ],
  )
}

// A track is as tall as the deepest call drawn in it, with a row of room
// above the first so the label has somewhere to sit.
fn call_track_height(track: CallTrack) -> Int {
  let deepest =
    list.fold(track.calls, 0, fn(most, call) {
      case call.depth < max_call_rows {
        True -> int.max(most, call.depth + 1)
        False -> most
      }
    })

  { int.max(1, deepest) + 1 } * call_row
}

fn call_track(track: CallTrack, top: Int, axis: Int) -> Element(msg) {
  svg.g([attribute.class("track")], [
    svg.text(
      [
        svg_util.num("x", 0),
        svg_util.num("y", top + call_row),
        attribute.class("track-label mono"),
      ],
      svg_util.fit(track.label, label_width, 7),
    ),
    svg.g(
      [],
      list.filter_map(track.calls, fn(call) {
        case call.depth < max_call_rows {
          True -> Ok(call_rect(call, top + call_row, axis))
          False -> Error(Nil)
        }
      }),
    ),
  ])
}

fn call_rect(call: CallBox, top: Int, axis: Int) -> Element(msg) {
  let x = x_of(call.start_ns, axis)
  let width = width_of(call.duration_ns, axis)

  svg.g([], [
    svg.title([], [
      element.text(
        call.name
        <> " · +"
        <> fmt.nanoseconds(call.start_ns)
        <> " for "
        <> fmt.nanoseconds(call.duration_ns)
        <> " · depth "
        <> int.to_string(call.depth),
      ),
    ]),
    svg.rect([
      svg_util.num("x", x),
      svg_util.num("y", top + call.depth * call_row),
      svg_util.num("width", width),
      svg_util.num("height", call_row - 2),
      attribute.class("call call-d" <> int.to_string(call.depth % 4)),
    ]),
    case width >= 60 {
      True ->
        svg.text(
          [
            svg_util.num("x", x + 3),
            svg_util.num("y", top + call.depth * call_row + call_row - 4),
            attribute.class("call-label"),
          ],
          svg_util.fit(call.name, width - 6, 6),
        )
      False -> element.none()
    },
  ])
}

// -------------------------------------------------------------------- axis

fn axis_line(axis: Int, plot_height: Int) -> Element(msg) {
  let window_ms = int.max(1, axis / 1_000_000)

  svg.g(
    [attribute.class("axis")],
    list.map([0, 1, 2, 3, 4, 5], fn(tick) {
      let ms = window_ms * tick / 5
      let x = label_width + plot_width * tick / 5

      svg.g([attribute.class("tick")], [
        svg.line([
          svg_util.num("x1", x),
          svg_util.num("y1", plot_height),
          svg_util.num("x2", x),
          svg_util.num("y2", plot_height + 5),
          attribute.class("tick-line"),
        ]),
        svg.text(
          [
            svg_util.num("x", x),
            svg_util.num("y", plot_height + 19),
            attribute.attribute("text-anchor", "middle"),
            attribute.class("tick-label"),
          ],
          "+" <> timeline_chart.axis_text(ms, window: window_ms),
        ),
      ])
    }),
  )
}
