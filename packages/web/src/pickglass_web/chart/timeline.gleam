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
//// The drawing is bounded by the model: one rectangle per step and per
//// span, and the viewer already limits both when it builds the model.
////
//// ## Reading order
////
//// `view` computes the scale from the window length, draws each track in a
//// row (`track_group`), then the gap bands, then the axis.

import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/model.{type CoverageGap, type Span, type Step, type Track}

const label_width: Int = 170

const plot_width: Int = 1000

const row_height: Int = 40

const axis_height: Int = 26

/// Draw the tracks and gaps of a window `window_ms` long.
pub fn view(
  window_ms window_ms: Int,
  tracks tracks: List(Track),
  gaps gaps: List(CoverageGap),
) -> Element(msg) {
  let window = int.max(window_ms, 1)
  let plot_height = list.length(tracks) * row_height
  let total_height = plot_height + axis_height

  let rows =
    list.index_map(tracks, fn(track, index) {
      track_group(track, index * row_height, window)
    })

  let bands = list.map(gaps, fn(gap) { gap_band(gap, window, plot_height) })

  svg.svg(
    [
      svg_util.view_box(label_width + plot_width + 8, total_height),
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

fn track_group(track: Track, y: Int, window: Int) -> Element(msg) {
  case track {
    model.CounterTrack(label:, unit: u, steps:) ->
      svg.g([attribute.class("track")], [
        track_label(label, y),
        ..counter_steps(steps, u, y, window)
      ])

    model.SpanTrack(label:, spans:) ->
      svg.g([attribute.class("track")], [
        track_label(label, y),
        ..list.map(spans, fn(span) { span_bar(span, y, window) })
      ])
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
  y: Int,
  window: Int,
) -> List(Element(msg)) {
  let peak =
    list.fold(steps, 1, fn(best, step) {
      case step.value {
        Known(value:) -> int.max(best, value)
        _ -> best
      }
    })

  list.map(steps, fn(step) { step_bar(step, u, y, window, peak) })
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

fn span_bar(span: Span, y: Int, window: Int) -> Element(msg) {
  let x = x_of(span.at_ms, window)
  let width = w_of(span.length_ms, window)

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
          "+" <> fmt.duration_ms(ms),
        ),
      ])
    })

  svg.g([attribute.class("axis")], ticks)
}
