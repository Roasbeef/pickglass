//// Flame, icicle and differential graphs as SVG.
////
//// The layout is core's: boxes already folded and capped, with integer
//// positions in a fixed width. This module only turns each box into SVG. A
//// box is a `<g>` holding a native `<title>` for the hover text, a `<rect>`
//// whose colour is a class, and a `<text>` label fitted by character count
//// (the face is monospace, so the server needs no font metrics). The
//// elements are keyed by the box's place in the tree, so a zoom or a new
//// selection re-renders moved boxes with keyed moves instead of rewrites.
////
//// Each box has its own click handler, which sends the box's `Key` and
//// nothing else. The number of boxes is the layout's, which core bounds by
//// `max_boxes`; this module adds none, so the element count on the page is
//// at most that bound plus one backing rectangle.
////
//// The synthetic root, "all", is not drawn: pprof and speedscope do not
//// spend a row on it, and its width is the chart's own. The rows below it
//// start at the first row, so the picture is one row shorter than the
//// layout.
////
//// The same boxes draw both orientations. A flame has the root on the
//// bottom row and an icicle has it on the top, so the icicle tab flips each
//// row against the layout's row count rather than asking core for a second
//// layout.
////
//// ## Reading order
////
//// `view` builds the whole `<svg>`; `box_key` is the key a click carries, so
//// the viewer can map a key back to a box of the layout it computed.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/keyed
import lustre/element/svg
import lustre/event
import pickglass_core/layout/flame.{type Box, type Layout}
import pickglass_core/measure
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/colour
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/key.{type Key}

/// The height of one row of boxes, in layout units.
pub const row_height: Int = 22

/// The width of one glyph of the label face, in layout units.
const glyph: Int = 7

const svg_namespace: String = "http://www.w3.org/2000/svg"

/// Which way up to draw a layout.
pub type Facing {
  /// Root at the bottom.
  RootBelow

  /// Root at the top.
  RootAbove
}

/// Whether a differential graph colours its boxes by the sign of the change.
pub type Verdict {
  /// Colour boxes red where they grew and blue where they shrank.
  Directed

  /// Draw every box in one neutral colour, because the two captures are not
  /// comparable and a direction would be a verdict nobody may give.
  Withheld
}

/// What a search matched in a layout.
pub type SearchSummary {
  SearchSummary(
    /// Boxes whose name contains the text.
    boxes: Int,
    /// The value of the samples whose stack holds a matching box.
    value: Int,
    /// The layout's total, for the share.
    total: Int,
  )
}

/// Count what a search matches, ignoring case. The value is taken over the
/// outermost matching boxes only, because a box inside a matching box is
/// already part of its value; adding it again would count a sample twice.
/// An empty needle matches nothing.
///
/// ## Examples
///
/// ```gleam
/// flame.search_summary(layout, name_of, "keeper")
/// // -> SearchSummary(boxes: 24, value: 3340, total: 10708)
/// ```
pub fn search_summary(
  layout: Layout,
  name_of: fn(Int) -> String,
  needle: String,
) -> SearchSummary {
  case needle {
    "" -> SearchSummary(boxes: 0, value: 0, total: layout.total)
    text -> {
      let wanted = string.lowercase(text)

      let hits =
        layout.boxes
        |> list.filter(fn(box) {
          case box.frame {
            flame.Root -> False
            flame.Function(id:) ->
              string.contains(string.lowercase(name_of(id)), wanted)
          }
        })
        |> list.sort(fn(a, b) { int.compare(a.depth, b.depth) })

      let outer =
        list.fold(hits, [], fn(kept: List(Box), box) {
          case list.any(kept, fn(parent) { covers(parent, box) }) {
            True -> kept
            False -> [box, ..kept]
          }
        })

      SearchSummary(
        boxes: list.length(hits),
        value: list.fold(outer, 0, fn(sum, box) { sum + box.value }),
        total: layout.total,
      )
    }
  }
}

// A box covers another that sits above it in the tree and inside its span.
fn covers(parent: Box, child: Box) -> Bool {
  parent.depth < child.depth
  && parent.x <= child.x
  && parent.x + parent.width >= child.x + child.width
}

/// The key a click on `box` carries. It is built from the box's depth, left
/// edge and function id, which are integers from the layout, never from a
/// name.
///
/// ## Examples
///
/// ```gleam
/// flame.box_key(box)
/// // -> a key such as "b2.140.17"
/// ```
pub fn box_key(box: Box) -> Key {
  let function = case box.frame {
    flame.Root -> "r"
    flame.Function(id:) -> int.to_string(id)
  }

  key.make(
    "b"
    <> int.to_string(box.depth)
    <> "."
    <> int.to_string(box.x)
    <> "."
    <> function,
  )
}

/// Draw a layout.
///
/// `name_of` gives a function's display name; `selected` is the key of the
/// highlighted box; `search` dims boxes whose name lacks that text, ignoring
/// case, and does nothing when empty; `on_select` builds the message a click sends. The unit
/// is the profile column's, for the hover text.
pub fn view(
  layout layout: Layout,
  facing facing: Facing,
  name_of name_of: fn(Int) -> String,
  unit u: Unit,
  selected selected: Option(Key),
  search search: String,
  verdict verdict: Verdict,
  on_select on_select: fn(Key) -> msg,
) -> Element(msg) {
  let rows = int.max(layout.rows - 1, 1)
  let height = rows * row_height + 2

  let boxes =
    layout.boxes
    |> list.filter(fn(box) { box.frame != flame.Root })
    |> list.map(fn(box) {
      let box_id = box_key(box)

      #(
        key.to_string(box_id),
        box_element(
          layout,
          facing,
          verdict,
          box,
          name_of,
          u,
          selected,
          search,
          on_select,
        ),
      )
    })

  svg.svg(
    [
      svg_util.view_box(1200, height),
      attribute.class("graph flame"),
      attribute.attribute("preserveAspectRatio", "xMinYMin meet"),
      attribute.attribute("role", "img"),
      attribute.attribute("aria-label", "Flame graph"),
    ],
    [keyed.namespaced(svg_namespace, "g", [], boxes)],
  )
}

fn box_element(
  layout: Layout,
  facing: Facing,
  verdict: Verdict,
  box: Box,
  name_of: fn(Int) -> String,
  u: Unit,
  selected: Option(Key),
  search: String,
  on_select: fn(Key) -> msg,
) -> Element(msg) {
  let box_id = box_key(box)
  let name = frame_name(box, name_of)
  let row = display_row(layout, facing, box)
  let y = row * row_height

  svg.g(
    [
      attribute.class("box"),
      selection_class(selected, box_id),
      search_class(search, name),
      event.on_click(on_select(box_id)),
    ],
    [
      svg.title([], [element.text(hover_text(layout, box, name, u))]),
      svg.rect([
        svg_util.num("x", box.x),
        svg_util.num("y", y),
        svg_util.num("width", int.max(box.width - 1, 1)),
        svg_util.num("height", row_height - 1),
        attribute.class(fill_class(layout, verdict, box)),
      ]),
      label(box, name, y),
    ],
  )
}

// The label sits inside the box when it fits and is absent otherwise.
fn label(box: Box, name: String, y: Int) -> Element(msg) {
  case svg_util.fit(name, box.width, glyph) {
    "" -> element.none()
    text ->
      svg.text(
        [
          svg_util.num("x", box.x + 4),
          svg_util.num("y", y + row_height - 7),
          attribute.class("box-label"),
        ],
        text,
      )
  }
}

// With a search active, boxes whose name does not contain it are dimmed.
fn search_class(search: String, name: String) -> attribute.Attribute(msg) {
  case search {
    "" -> attribute.none()
    needle ->
      case string.contains(string.lowercase(name), string.lowercase(needle)) {
        True -> attribute.class("hit")
        False -> attribute.class("dim")
      }
  }
}

fn selection_class(selected: Option(Key), id: Key) -> attribute.Attribute(msg) {
  case selected {
    Some(chosen) if chosen == id -> attribute.class("sel")
    Some(_) | None -> attribute.none()
  }
}

// A plain layout is coloured by package; a differential one by the sign and
// size of the change, with the root left neutral.
fn fill_class(layout: Layout, verdict: Verdict, box: Box) -> String {
  case layout.mode, box.frame {
    flame.Differential, flame.Function(_) ->
      case verdict {
        Directed -> colour.diff(delta: box.delta, of: box.value)
        Withheld -> "diff-same"
      }
    flame.Differential, flame.Root -> "diff-same"
    flame.Plain, flame.Root -> "root-box"
    flame.Plain, flame.Function(_) -> colour.hue(box.bucket)
  }
}

fn frame_name(box: Box, name_of: fn(Int) -> String) -> String {
  case box.frame {
    flame.Root -> "all"
    flame.Function(id:) -> name_of(id)
  }
}

// The layout's own orientation says where it put the root; the wanted
// facing may differ, in which case the row is mirrored.
//
// The root's row is not drawn. With the root at the top, every other row
// moves up by one; with it at the bottom, the other rows are already the
// first ones.
fn display_row(layout: Layout, facing: Facing, box: Box) -> Int {
  let mirrored = layout.rows - 1 - box.row

  let with_root = case layout.orientation, facing {
    flame.Flame, RootBelow -> box.row
    flame.Icicle, RootAbove -> box.row
    flame.Flame, RootAbove -> mirrored
    flame.Icicle, RootBelow -> mirrored
  }

  case facing {
    RootAbove -> int.max(with_root - 1, 0)
    RootBelow -> with_root
  }
}

fn hover_text(layout: Layout, box: Box, name: String, u: Unit) -> String {
  let share = fmt.share(box.value, of: layout.total)
  let base =
    name
    <> "\n"
    <> fmt.known(box.value, u)
    <> " ("
    <> share
    <> " of "
    <> fmt.known(layout.total, u)
    <> ") · self "
    <> fmt.known(box.self, u)

  let with_delta = case layout.mode {
    flame.Differential -> base <> " · change " <> fmt.signed(delta(box), u)
    flame.Plain -> base
  }

  case box.folded_boxes {
    0 -> with_delta
    n ->
      with_delta
      <> "\n"
      <> int.to_string(n)
      <> " narrower boxes folded in ("
      <> fmt.known(box.folded_value, u)
      <> ")"
  }
}

fn delta(box: Box) -> measure.Measurement {
  measure.Known(box.delta)
}
