//// The call graph as SVG, from core's layered layout.
////
//// `layout/dag` has already placed every node and routed every edge as a
//// polyline through the layers, so this module draws what it is given: a
//// rectangle and a label per node, a polyline per edge. Following pprof,
//// a node's text size comes from its flat value (the layout computed
//// `font_size`), its fill from its cumulative share of the total, an edge's
//// width from its weight, and a residual edge, one that stands for removed
//// nodes between its ends, is dotted.
////
//// The layout is bounded by the graph's own node cap of 80, so the element
//// count is bounded without a limit here. Every node has a click handler
//// that sends its `Key`, built from the integer function id.
////
//// ## Reading order
////
//// `view` draws the whole graph; `node_key` is the key a click carries.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/keyed
import lustre/element/svg
import lustre/event
import pickglass_core/analysis/graph
import pickglass_core/layout/dag.{type Layout, type PlacedEdge, type PlacedNode}
import pickglass_core/unit.{type Unit}
import pickglass_web/chart/svg_util
import pickglass_web/fmt
import pickglass_web/key.{type Key}

const svg_namespace: String = "http://www.w3.org/2000/svg"

const margin: Int = 12

/// The key a click on the node for `function` carries.
///
/// ## Examples
///
/// ```gleam
/// call_graph.node_key(17)
/// // -> a key spelled "n.17"
/// ```
pub fn node_key(function: Int) -> Key {
  key.indexed("n", function)
}

/// Draw a graph layout. `total` is the profile total the shares are taken
/// against; `name_of` gives function names; `selected` is the highlighted
/// node's key; `on_select` builds the message a click sends.
pub fn view(
  layout layout: Layout,
  total total: Int,
  name_of name_of: fn(Int) -> String,
  unit u: Unit,
  selected selected: Option(Key),
  on_select on_select: fn(Key) -> msg,
) -> Element(msg) {
  let #(min_x, max_x, min_y, max_y) = bounds(layout)

  let edges =
    list.index_map(layout.edges, fn(edge, index) {
      #(edge_key(edge, index), edge_element(edge))
    })

  let nodes =
    list.map(layout.nodes, fn(node) {
      #(
        key.to_string(node_key(node.function)),
        node_element(node, total, name_of, u, selected, on_select),
      )
    })

  svg.svg(
    [
      attribute.attribute(
        "viewBox",
        int.to_string(min_x - margin)
          <> " "
          <> int.to_string(min_y - margin)
          <> " "
          <> int.to_string(max_x - min_x + 2 * margin)
          <> " "
          <> int.to_string(max_y - min_y + 2 * margin),
      ),
      attribute.class("graph call-graph"),
      attribute.attribute("role", "img"),
      attribute.attribute("aria-label", "Call graph"),
    ],
    [
      arrow_defs(),
      keyed.namespaced(svg_namespace, "g", [], list.append(edges, nodes)),
    ],
  )
}

// The layout's own width and height count the invisible nodes that route
// long edges between layers, which can sit far from every visible node and
// leave the picture small and off to one side. The drawing is fitted to the
// boxes and edge points that are actually drawn instead.
fn bounds(layout: Layout) -> #(Int, Int, Int, Int) {
  let corners =
    list.flat_map(layout.nodes, fn(node) {
      [#(node.x, node.y), #(node.x + node.width, node.y + node.height)]
    })

  let points =
    list.append(corners, list.flat_map(layout.edges, fn(edge) { edge.points }))

  case points {
    [] -> #(0, layout.width, 0, layout.height)
    [first, ..rest] ->
      list.fold(rest, #(first.0, first.0, first.1, first.1), fn(box, point) {
        #(
          int.min(box.0, point.0),
          int.max(box.1, point.0),
          int.min(box.2, point.1),
          int.max(box.3, point.1),
        )
      })
  }
}

// Two arrowheads, one for each end an edge may point at, so a reversed edge
// (one that closes a cycle) has its head at the upper end.
fn arrow_defs() -> Element(msg) {
  svg.defs([], [
    marker("arrow-end", "auto"),
    marker("arrow-start", "auto-start-reverse"),
  ])
}

fn marker(id: String, orient: String) -> Element(msg) {
  svg.marker(
    [
      attribute.id(id),
      attribute.attribute("viewBox", "0 0 10 10"),
      attribute.attribute("refX", "9"),
      attribute.attribute("refY", "5"),
      attribute.attribute("markerWidth", "6"),
      attribute.attribute("markerHeight", "6"),
      attribute.attribute("orient", orient),
    ],
    [svg.path([attribute.attribute("d", "M 0 0 L 10 5 L 0 10 z")])],
  )
}

fn edge_key(edge: PlacedEdge, index: Int) -> String {
  "e"
  <> int.to_string(index)
  <> "."
  <> int.to_string(edge.from)
  <> "."
  <> int.to_string(edge.to)
}

fn edge_element(edge: PlacedEdge) -> Element(msg) {
  let kind_class = case edge.kind {
    graph.Direct -> "edge"
    graph.Residual -> "edge residual"
  }

  let head = case edge.direction {
    dag.Forward -> attribute.attribute("marker-end", "url(#arrow-end)")
    dag.Reversed -> attribute.attribute("marker-start", "url(#arrow-start)")
  }

  svg.polyline([
    attribute.attribute("points", svg_util.points(edge.points)),
    attribute.class(kind_class),
    svg_util.num("stroke-width", stroke(edge.weight)),
    head,
  ])
}

// Edge weights span orders of magnitude, so the width grows with the number
// of digits of the weight, between one and six units.
fn stroke(weight: Int) -> Int {
  int.min(1 + digits(weight) / 2, 6)
}

fn digits(n: Int) -> Int {
  case n < 10 {
    True -> 1
    False -> 1 + digits(n / 10)
  }
}

fn node_element(
  node: PlacedNode,
  total: Int,
  name_of: fn(Int) -> String,
  u: Unit,
  selected: Option(Key),
  on_select: fn(Key) -> msg,
) -> Element(msg) {
  let id = node_key(node.function)
  let name = name_of(node.function)

  svg.g(
    [
      attribute.class("node"),
      selection_class(selected, id),
      event.on_click(on_select(id)),
    ],
    [
      svg.title([], [element.text(hover_text(node, total, name, u))]),
      svg.rect([
        svg_util.num("x", node.x),
        svg_util.num("y", node.y),
        svg_util.num("width", node.width),
        svg_util.num("height", node.height),
        svg_util.num("rx", 3),
        attribute.class(heat_class(node.cum, total)),
      ]),
      svg.text(
        [
          svg_util.num("x", node.x + node.width / 2),
          svg_util.num("y", node.y + node.height / 2 + node.font_size / 3),
          svg_util.num("font-size", node.font_size),
          attribute.attribute("text-anchor", "middle"),
          attribute.class("node-label"),
        ],
        name,
      ),
    ],
  )
}

fn selection_class(selected: Option(Key), id: Key) -> attribute.Attribute(msg) {
  case selected {
    Some(chosen) if chosen == id -> attribute.class("sel")
    Some(_) | None -> attribute.none()
  }
}

// Heat is the node's cumulative share, in six steps, as whole class names.
fn heat_class(cum: Int, total: Int) -> String {
  case total <= 0 {
    True -> "heat-0"
    False ->
      case cum * 100 / total {
        pct if pct >= 60 -> "heat-5"
        pct if pct >= 40 -> "heat-4"
        pct if pct >= 20 -> "heat-3"
        pct if pct >= 8 -> "heat-2"
        pct if pct >= 2 -> "heat-1"
        _ -> "heat-0"
      }
  }
}

fn hover_text(node: PlacedNode, total: Int, name: String, u: Unit) -> String {
  name
  <> "\nflat "
  <> fmt.known(node.flat, u)
  <> " ("
  <> fmt.share(node.flat, of: total)
  <> ") · cum "
  <> fmt.known(node.cum, u)
  <> " ("
  <> fmt.share(node.cum, of: total)
  <> ")"
}
