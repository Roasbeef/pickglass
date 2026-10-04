//// How the call graph writes a node and sizes its drawing.

import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/element
import pickglass_core/analysis/graph.{Direct, Edge, Graph, Node, NotInline}
import pickglass_core/layout/dag
import pickglass_core/unit
import pickglass_web/chart/call_graph
import pickglass_web/chart/names
import pickglass_web/key
import support

fn name_of(id: Int) -> String {
  case id {
    0 -> "runtime@strand_runtime:handle/2"
    1 -> "runtime@strand_runtime:-drive_loop/2-anonymous-0-/2"
    _ -> "runtime@writer:get_register/3"
  }
}

fn drawn() -> String {
  let g =
    Graph(
      nodes: [
        Node(function: 0, flat: 5, cum: 100),
        Node(function: 1, flat: 10, cum: 60),
        Node(function: 2, flat: 40, cum: 40),
      ],
      edges: [
        Edge(from: 0, to: 1, weight: 60, kind: Direct, inline: NotInline),
        Edge(from: 1, to: 2, weight: 40, kind: Direct, inline: NotInline),
      ],
      total: 100,
      original_nodes: 3,
      dropped_nodes: 0,
      dropped_edges: 0,
    )

  let layout =
    dag.layout(g, fn(id) { names.short(name_of(id)) }, dag.default_config)

  call_graph.view(
    layout:,
    total: 100,
    name_of:,
    unit: unit.Count,
    selected: None,
    on_select: fn(node) { key.to_string(node) },
  )
  |> element.to_string
}

// The name in the box is the function, and the whole name is in the title.
pub fn a_node_is_labelled_with_its_function_and_titled_with_its_name_test() {
  let html = drawn()

  assert string.contains(html, ">drive_loop/2 fun#0</text>")
  assert string.contains(html, ">get_register/3</text>")
  assert string.contains(
    html,
    "<title>runtime@strand_runtime:-drive_loop/2-anonymous-0-/2",
  )
}

// A node whose heaviest caller is in its own module does not repeat it, and
// one called from another module says which module it is in.
pub fn the_module_line_is_dropped_when_the_caller_shares_it_test() {
  let html = drawn()

  // The root has no caller, so it names its module; the second node shares
  // the root's, and the third does not.
  assert support.count(html, "class=\"node-module\"") == 2
  assert support.count(html, ">runtime@strand_runtime</text>") == 1
  assert support.count(html, ">runtime@writer</text>") == 1
}

// The picture is sized and boxed the same, so the stylesheet can show it at
// its natural size or scaled down to the frame.
pub fn the_drawing_has_a_natural_size_and_a_matching_view_box_test() {
  let html = drawn()
  let assert Ok(#(_, after_width)) = string.split_once(html, "width=\"")
  let assert Ok(#(width, _)) = string.split_once(after_width, "\"")

  assert string.contains(html, " " <> width <> " ")
  assert list.length(string.split(html, "viewBox=\"")) >= 2
}
