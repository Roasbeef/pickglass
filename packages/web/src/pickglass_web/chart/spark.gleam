//// Sparklines.
////
//// A sparkline draws a short series in a small box. Its one rule is the
//// package's rule: a missing reading is not zero. The line is drawn as one
//// polyline per run of known points, so a gap breaks the line, and each
//// missing position gets a short dotted tick on the baseline, so the gap is
//// visible rather than interpolated across. A series with no known point
//// draws the word "no data" instead of an empty box.
////
//// The vertical scale runs from zero to the largest known value, which is
//// the honest scale for counters, queue lengths and utilisation, and it is
//// said in the hover text.
////
//// ## Reading order
////
//// `view` splits the points into known runs (`runs`), places each point
//// (`x_of`, `y_of`) and draws a polyline per run.

import gleam/int
import gleam/list
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/svg
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/svg_util
import pickglass_web/fmt

/// The drawing width, in SVG units.
pub const width: Int = 160

/// The drawing height, in SVG units.
pub const height: Int = 32

const pad: Int = 3

/// A point that is known, with its position in the series.
type Dot {
  Dot(index: Int, value: Int)
}

/// Draw a series. `unit` writes the maximum in the hover text.
///
/// ## Examples
///
/// ```gleam
/// spark.view([Known(1), Known(4), Missing(BudgetExhausted), Known(2)], unit.Count)
/// ```
pub fn view(points: List(Measurement), unit u: Unit) -> Element(msg) {
  let dots = known_dots(points)

  case dots {
    [] ->
      element.element("span", [attribute.class("spark-none word")], [
        element.text("no data"),
      ])
    _ -> chart(points, dots, u)
  }
}

fn chart(points: List(Measurement), dots: List(Dot), u: Unit) -> Element(msg) {
  let count = list.length(points)
  let peak = list.fold(dots, 1, fn(best, dot) { int.max(best, dot.value) })
  let missing = count - list.length(dots)

  let lines =
    runs(points)
    |> list.map(fn(run) { run_element(run, count, peak) })

  let gaps =
    points
    |> list.index_map(fn(point, index) { #(point, index) })
    |> list.filter_map(fn(pair) {
      case pair.0 {
        Known(_) -> Error(Nil)
        _ -> Ok(gap_tick(pair.1, count))
      }
    })

  svg.svg(
    [
      svg_util.view_box(width, height),
      attribute.class("spark"),
      attribute.attribute("role", "img"),
      attribute.attribute("preserveAspectRatio", "none"),
    ],
    [
      svg.title([], [element.text(hover(count, missing, peak, u))]),
      svg.line([
        svg_util.num("x1", pad),
        svg_util.num("y1", height - pad),
        svg_util.num("x2", width - pad),
        svg_util.num("y2", height - pad),
        attribute.class("spark-base"),
      ]),
      ..list.append(gaps, lines)
    ],
  )
}

fn hover(count: Int, missing: Int, peak: Int, u: Unit) -> String {
  let base =
    int.to_string(count) <> " readings, scale 0 to " <> fmt.known(peak, u)

  case missing {
    0 -> base
    n -> base <> ", " <> int.to_string(n) <> " missing (gaps, not zero)"
  }
}

fn known_dots(points: List(Measurement)) -> List(Dot) {
  points
  |> list.index_map(fn(point, index) { #(point, index) })
  |> list.filter_map(fn(pair) {
    case pair.0 {
      Known(value:) -> Ok(Dot(index: pair.1, value:))
      _ -> Error(Nil)
    }
  })
}

// Split the series into maximal runs of consecutive known points.
fn runs(points: List(Measurement)) -> List(List(Dot)) {
  let #(done, current, _) =
    list.fold(points, #([], [], 0), fn(state, point) {
      let #(done, current, index) = state

      case point {
        Known(value:) -> #(done, [Dot(index:, value:), ..current], index + 1)
        _ -> #(close(done, current), [], index + 1)
      }
    })

  list.reverse(close(done, current))
}

fn close(done: List(List(Dot)), current: List(Dot)) -> List(List(Dot)) {
  case current {
    [] -> done
    _ -> [list.reverse(current), ..done]
  }
}

fn run_element(run: List(Dot), count: Int, peak: Int) -> Element(msg) {
  let coords =
    list.map(run, fn(dot) { #(x_of(dot.index, count), y_of(dot.value, peak)) })

  case coords {
    [#(x, y)] ->
      svg.circle([
        svg_util.num("cx", x),
        svg_util.num("cy", y),
        svg_util.num("r", 2),
        attribute.class("spark-dot"),
      ])
    _ ->
      svg.polyline([
        attribute.attribute("points", svg_util.points(coords)),
        attribute.class("spark-line"),
      ])
  }
}

fn gap_tick(index: Int, count: Int) -> Element(msg) {
  let x = x_of(index, count)

  svg.line([
    svg_util.num("x1", x),
    svg_util.num("y1", pad),
    svg_util.num("x2", x),
    svg_util.num("y2", height - pad),
    attribute.class("spark-gap"),
  ])
}

fn x_of(index: Int, count: Int) -> Int {
  case count <= 1 {
    True -> width / 2
    False -> pad + index * { width - 2 * pad } / { count - 1 }
  }
}

fn y_of(value: Int, peak: Int) -> Int {
  height - pad - value * { height - 2 * pad } / peak
}
