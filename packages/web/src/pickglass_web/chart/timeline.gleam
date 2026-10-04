//// The timeline as SVG.
////
//// A timeline lines up several tracks against one time axis. Its rules come
//// from what the data is.
////
//// A counter that was polled is known only at the moments it was read, so
//// it is drawn as steps: each reading is a bar as wide as the sampling
//// interval it stands for, and nothing is interpolated between bars. A
//// reading that is missing is a hatched bar of the same width, not a bar of
//// height zero. Operation spans are drawn as labelled bars. Where the
//// collector dropped evidence, a hatched band crosses every track with the
//// number of events lost in its hover text, so a quiet stretch cannot be
//// mistaken for an idle one.
////
//// A counter track has no vertical axis of its own, so the track prints its
//// peak at the right edge ("peak 7.8%"): the tallest bar is that figure, and
//// every other bar is read against it. A track whose readings are all
//// missing says so instead. The time axis counts in seconds when the window
//// is a second or longer and in milliseconds otherwise, never both, so its
//// labels read in one unit.
////
//// Every reading and span carries a click handler with a key of its own, and
//// `describe` writes the line the page shows for the chosen one, so the
//// numbers hover text carries are on the page too.
////
//// The drawing is bounded by the model: one rectangle per step and per
//// span, and the viewer already limits both when it builds the model.
////
//// ## Reading order
////
//// `view` computes the scale from the window length, draws each track in a
//// row (`track_group`), then the gap bands, then the axis.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg
import lustre/event
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/key.{type Key}
import pickglass_web/model.{type CoverageGap, type Span, type Step, type Track}

const label_width: Int = 170

const plot_width: Int = 1000

/// Room to the right of the plot for each track's peak.
const peak_width: Int = 96

const row_height: Int = 40

const axis_height: Int = 26

/// Draw the tracks and gaps of a window `window_ms` long.
pub fn view(
  window_ms window_ms: Int,
  tracks tracks: List(Track),
  gaps gaps: List(CoverageGap),
  selected selected: Option(Key),
  on_select on_select: fn(Key) -> msg,
) -> Element(msg) {
  let window = int.max(window_ms, 1)
  let plot_height = list.length(tracks) * row_height
  let total_height = plot_height + axis_height

  let rows =
    list.index_map(tracks, fn(track, index) {
      track_group(track, index, window, selected, on_select)
    })

  let bands = list.map(gaps, fn(gap) { gap_band(gap, window, plot_height) })

  svg.svg(
    [
      svg_util.view_box(label_width + plot_width + peak_width, total_height),
      attribute.class("graph timeline"),
      attribute.attribute("role", "img"),
      attribute.attribute("aria-label", "Timeline"),
    ],
    [
      hatch_pattern(),
      svg.g([], rows),
      svg.g([], bands),
      axis(window, plot_height),
    ],
  )
}

fn hatch_pattern() -> Element(msg) {
  svg.defs([], [
    svg.pattern(
      [
        attribute.id("hatch"),
        svg_util.num("width", 6),
        svg_util.num("height", 6),
        attribute.attribute("patternUnits", "userSpaceOnUse"),
        attribute.attribute("patternTransform", "rotate(45)"),
      ],
      [
        svg.line([
          svg_util.num("x1", 0),
          svg_util.num("y1", 0),
          svg_util.num("x2", 0),
          svg_util.num("y2", 6),
          attribute.class("hatch-line"),
        ]),
      ],
    ),
  ])
}

fn x_of(ms: Int, window: Int) -> Int {
  label_width + ms * plot_width / window
}

fn w_of(ms: Int, window: Int) -> Int {
  int.max(ms * plot_width / window, 1)
}

/// The key a click on reading or span `item` of track `track` carries.
///
/// ## Examples
///
/// ```gleam
/// timeline.item_key(2, 5)
/// // -> a key spelled "t2.5"
/// ```
pub fn item_key(track: Int, item: Int) -> Key {
  key.make("t" <> int.to_string(track) <> "." <> int.to_string(item))
}

fn track_group(
  track: Track,
  index: Int,
  window: Int,
  selected: Option(Key),
  on_select: fn(Key) -> msg,
) -> Element(msg) {
  let y = index * row_height

  case track {
    model.CounterTrack(label:, unit: u, steps:) ->
      svg.g([attribute.class("track")], [
        track_label(label, y),
        peak_label(steps, u, y),
        ..counter_steps(steps, u, index, window, selected, on_select)
      ])

    model.SpanTrack(label:, spans:) ->
      svg.g([attribute.class("track")], [
        track_label(label, y),
        ..list.index_map(spans, fn(span, position) {
          span_bar(span, index, position, window, selected, on_select)
        })
      ])
  }
}

/// The tallest known reading of a track, or nothing when none was read.
///
/// ## Examples
///
/// ```gleam
/// timeline.peak_of(steps)
/// // -> Some(780)
/// ```
pub fn peak_of(steps: List(Step)) -> Option(Int) {
  list.fold(steps, None, fn(best, step) {
    case step.value, best {
      Known(value:), Some(most) -> Some(int.max(most, value))
      Known(value:), None -> Some(value)
      _, _ -> best
    }
  })
}

/// The text at a track's right edge: its peak in its unit, or the statement
/// that nothing was read.
///
/// ## Examples
///
/// ```gleam
/// timeline.peak_text(steps, unit.Count)
/// // -> "peak 7"
/// ```
pub fn peak_text(steps: List(Step), u: Unit) -> String {
  case peak_of(steps) {
    Some(value) -> "peak " <> fmt.known(value, u)
    None -> "no reading"
  }
}

fn peak_label(steps: List(Step), u: Unit, y: Int) -> Element(msg) {
  svg.text(
    [
      svg_util.num("x", label_width + plot_width + 8),
      svg_util.num("y", y + row_height / 2 + 4),
      attribute.class("peak-label"),
    ],
    peak_text(steps, u),
  )
}

/// The line the page shows for a chosen reading or span: the track, when it
/// was, and its value, with the width of time a reading stands for.
///
/// ## Examples
///
/// ```gleam
/// timeline.describe(tracks, timeline.item_key(0, 3))
/// // -> Ok("scheduler util · +6 s · 70.0% (reading stands for 2.00 s)")
/// ```
pub fn describe(tracks: List(Track), chosen: Key) -> Result(String, Nil) {
  tracks
  |> list.index_map(fn(track, index) { #(index, track) })
  |> list.find_map(fn(entry) {
    let #(index, track) = entry

    case track {
      model.CounterTrack(label:, unit: u, steps:) ->
        steps
        |> list.index_map(fn(step, position) { #(position, step) })
        |> list.find_map(fn(item) {
          case item_key(index, item.0) == chosen {
            True ->
              Ok(
                label
                <> " · +"
                <> seconds_text(item.1.at_ms)
                <> " · "
                <> step_title(item.1.value, u, item.1.width_ms),
              )
            False -> Error(Nil)
          }
        })

      model.SpanTrack(label:, spans:) ->
        spans
        |> list.index_map(fn(span, position) { #(position, span) })
        |> list.find_map(fn(item) {
          case item_key(index, item.0) == chosen {
            True ->
              Ok(
                label
                <> " · "
                <> item.1.label
                <> " · +"
                <> seconds_text(item.1.at_ms)
                <> " for "
                <> fmt.duration_ms(item.1.length_ms),
              )
            False -> Error(Nil)
          }
        })
    }
  })
}

/// Whether a key names a reading or span of these tracks.
pub fn knows(tracks: List(Track), chosen: Key) -> Bool {
  case describe(tracks, chosen) {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

fn track_label(label: String, y: Int) -> Element(msg) {
  svg.text(
    [
      svg_util.num("x", 0),
      svg_util.num("y", y + row_height / 2 + 4),
      attribute.class("track-label"),
    ],
    svg_util.fit(label, label_width, 7),
  )
}

// Steps are scaled to the largest known reading of the track; a missing
// reading is a hatched full-height bar.
fn counter_steps(
  steps: List(Step),
  u: Unit,
  track: Int,
  window: Int,
  selected: Option(Key),
  on_select: fn(Key) -> msg,
) -> List(Element(msg)) {
  let peak = int.max(option.unwrap(peak_of(steps), 1), 1)

  list.index_map(steps, fn(step, position) {
    let id = item_key(track, position)

    step_bar(step, u, track * row_height, window, peak)
    |> clickable(id, selected, on_select)
  })
}

// A group with the item's click handler, marked when it is the chosen one.
fn clickable(
  inner: Element(msg),
  id: Key,
  selected: Option(Key),
  on_select: fn(Key) -> msg,
) -> Element(msg) {
  let chosen = case selected {
    Some(current) if current == id -> attribute.class("reading sel")
    Some(_) | None -> attribute.class("reading")
  }

  svg.g([chosen, event.on_click(on_select(id))], [inner])
}

fn step_bar(
  step: Step,
  u: Unit,
  y: Int,
  window: Int,
  peak: Int,
) -> Element(msg) {
  let usable = row_height - 8
  let x = x_of(step.at_ms, window)
  let width = w_of(step.width_ms, window)

  case step.value {
    Known(value:) -> {
      let h = int.max(value * usable / peak, 1)

      svg.rect([
        svg_util.num("x", x),
        svg_util.num("y", y + 4 + usable - h),
        svg_util.num("width", width),
        svg_util.num("height", h),
        attribute.class("step"),
      ])
    }
    _ ->
      svg.rect([
        svg_util.num("x", x),
        svg_util.num("y", y + 4),
        svg_util.num("width", width),
        svg_util.num("height", usable),
        attribute.class("step-missing"),
      ])
  }
  |> with_title(step_title(step.value, u, step.width_ms))
}

fn step_title(value: Measurement, u: Unit, width_ms: Int) -> String {
  fmt.cell(value, u)
  <> " (reading stands for "
  <> fmt.duration_ms(width_ms)
  <> ")"
}

// Wrap an element in a group so it can carry a native hover title.
fn with_title(inner: Element(msg), text: String) -> Element(msg) {
  svg.g([], [svg.title([], [element.text(text)]), inner])
}

fn span_bar(
  span: Span,
  track: Int,
  position: Int,
  window: Int,
  selected: Option(Key),
  on_select: fn(Key) -> msg,
) -> Element(msg) {
  let y = track * row_height
  let x = x_of(span.at_ms, window)
  let width = w_of(span.length_ms, window)

  span_group(span, x, y, width)
  |> clickable(item_key(track, position), selected, on_select)
}

fn span_group(span: Span, x: Int, y: Int, width: Int) -> Element(msg) {
  svg.g([attribute.class("span")], [
    svg.title([], [
      element.text(span.label <> " · " <> fmt.duration_ms(span.length_ms)),
    ]),
    svg.rect([
      svg_util.num("x", x),
      svg_util.num("y", y + 8),
      svg_util.num("width", width),
      svg_util.num("height", row_height - 16),
      svg_util.num("rx", 3),
      attribute.class("span-bar"),
    ]),
    svg.text(
      [
        svg_util.num("x", x + 5),
        svg_util.num("y", y + row_height / 2 + 4),
        attribute.class("span-label"),
      ],
      svg_util.fit(span.label, width, 7),
    ),
  ])
}

fn gap_band(gap: CoverageGap, window: Int, plot_height: Int) -> Element(msg) {
  let x = x_of(gap.from_ms, window)
  let width = w_of(gap.to_ms - gap.from_ms, window)

  svg.g([attribute.class("gap")], [
    svg.title([], [
      element.text(
        "evidence lost: "
        <> gap.reason
        <> " · events dropped "
        <> fmt.cell(gap.dropped, unit.Count),
      ),
    ]),
    svg.rect([
      svg_util.num("x", x),
      svg_util.num("y", 0),
      svg_util.num("width", width),
      svg_util.num("height", plot_height),
      attribute.class("gap-band"),
    ]),
  ])
}

/// A tick offset written in one unit for the whole axis: seconds when the
/// window is a second or longer, milliseconds when it is shorter. A tick
/// never switches unit by its own size, which is what made "+0 ms" sit
/// beside "+12.0 s".
///
/// ## Examples
///
/// ```gleam
/// timeline.axis_text(0, window: 60_000)
/// // -> "0 s"
///
/// timeline.axis_text(12_000, window: 60_000)
/// // -> "12 s"
///
/// timeline.axis_text(400, window: 800)
/// // -> "400 ms"
/// ```
pub fn axis_text(ms: Int, window window: Int) -> String {
  case window < 1000 {
    True -> int.to_string(ms) <> " ms"
    False -> seconds_text(ms)
  }
}

/// A time offset in seconds with a tenth when it is not whole.
///
/// ## Examples
///
/// ```gleam
/// timeline.seconds_text(2500)
/// // -> "2.5 s"
/// ```
pub fn seconds_text(ms: Int) -> String {
  case ms % 1000 / 100 {
    0 -> int.to_string(ms / 1000) <> " s"
    tenth -> int.to_string(ms / 1000) <> "." <> int.to_string(tenth) <> " s"
  }
}

// Five ticks across the window, labelled in the window's own offsets.
fn axis(window: Int, plot_height: Int) -> Element(msg) {
  let ticks =
    list.map([0, 1, 2, 3, 4, 5], fn(i) {
      let ms = window * i / 5
      let x = x_of(ms, window)

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
          "+" <> axis_text(ms, window:),
        ),
      ])
    })

  svg.g([attribute.class("axis")], ticks)
}
