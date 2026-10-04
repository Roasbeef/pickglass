//// Small helpers shared by the SVG charts.
////
//// Every chart sets geometry with numeric presentation attributes (`x`,
//// `width`, `points`) and colour with classes. None builds a `style`
//// attribute, none sets an attribute name from data, and every label goes in
//// as a text node, so a function name from a profile can never become markup
//// or a handler.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute.{type Attribute}

/// An integer attribute, such as `x` or `height`.
pub fn num(name: String, value: Int) -> Attribute(msg) {
  attribute.attribute(name, int.to_string(value))
}

/// A `viewBox` from a width and height.
pub fn view_box(width: Int, height: Int) -> Attribute(msg) {
  attribute.attribute(
    "viewBox",
    "0 0 " <> int.to_string(width) <> " " <> int.to_string(height),
  )
}

/// A `points` or path string from integer coordinates.
pub fn points(coords: List(#(Int, Int))) -> String {
  coords
  |> list.map(fn(point) {
    int.to_string(point.0) <> "," <> int.to_string(point.1)
  })
  |> string.join(" ")
}

/// Cut a label to what fits in `width` units of a monospace face whose
/// glyphs are `glyph` units wide, ending with an ellipsis when it was cut.
/// A box too narrow for three characters has no label.
///
/// ## Examples
///
/// ```gleam
/// svg_util.fit("loom@runtime@keeper:handle/2", 100, 7)
/// // -> "loom@runtime…"
/// ```
pub fn fit(label: String, width: Int, glyph: Int) -> String {
  let room = { width - 8 } / glyph

  case room < 3 {
    True -> ""
    False ->
      case string.length(label) <= room {
        True -> label
        False -> string.slice(label, 0, room - 1) <> "…"
      }
  }
}
