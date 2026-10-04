import fixtures
import gleam/dict
import gleam/int
import gleam/list
import pickglass_core/analysis/graph.{Direct, Edge, Graph, Node, NotInline}
import pickglass_core/layout/dag.{Forward, Reversed}

fn label(id: Int) -> String {
  "function_" <> int.to_string(id)
}

// A graph over function ids 0..count-1 with the given edges.
fn graph_of(count: Int, pairs: List(#(Int, Int))) -> graph.Graph {
  Graph(
    nodes: list.map(fixtures.span(0, count - 1), fn(id) {
      Node(function: id, flat: id + 1, cum: id + 1)
    }),
    edges: list.map(pairs, fn(pair) {
      Edge(
        from: pair.0,
        to: pair.1,
        weight: 10,
        kind: Direct,
        inline: NotInline,
      )
    }),
    total: 100,
    original_nodes: count,
    dropped_nodes: 0,
    dropped_edges: 0,
  )
}

fn layout(g: graph.Graph) -> dag.Layout {
  dag.layout(g, label, dag.default_config)
}

fn layer_of(l: dag.Layout, function: Int) -> Int {
  let assert Ok(node) = list.find(l.nodes, fn(n) { n.function == function })
  node.layer
}

pub fn a_chain_has_one_layer_per_node_test() {
  let l = layout(graph_of(3, [#(0, 1), #(1, 2)]))
  assert list.map([0, 1, 2], layer_of(l, _)) == [0, 1, 2]
  assert l.layers == 3
}

pub fn a_node_sits_below_its_deepest_caller_test() {
  // 0 -> 1 -> 2 and 0 -> 2: node 2 is two layers down.
  let l = layout(graph_of(3, [#(0, 1), #(1, 2), #(0, 2)]))
  assert layer_of(l, 2) == 2
}

// An edge over a layer passes through an invisible node there, so its
// polyline has a point for every layer it crosses.
pub fn a_long_edge_gets_a_point_per_layer_test() {
  let l = layout(graph_of(3, [#(0, 1), #(1, 2), #(0, 2)]))
  let assert Ok(long) = list.find(l.edges, fn(e) { e.from == 0 && e.to == 2 })
  assert list.length(long.points) == 3
  let assert Ok(short) = list.find(l.edges, fn(e) { e.from == 0 && e.to == 1 })
  assert list.length(short.points) == 2
}

pub fn a_cycle_is_broken_by_reversing_one_edge_test() {
  let l = layout(graph_of(2, [#(0, 1), #(1, 0)]))
  let directions = list.map(l.edges, fn(e) { e.direction })
  assert list.sort(
      list.map(directions, fn(d) {
        case d {
          Forward -> 0
          Reversed -> 1
        }
      }),
      int.compare,
    )
    == [0, 1]
  assert layer_of(l, 0) != layer_of(l, 1)
}

pub fn the_empty_graph_lays_out_to_nothing_test() {
  let l = layout(graph_of(0, []))
  assert l.nodes == []
  assert l.edges == []
  assert l.layers == 0
}

// The square-root scale: 11 + ceil(13 * sqrt(flat / max_flat)).
pub fn font_size_follows_the_square_root_scale_test() {
  assert dag.font_size(100, 100) == 24
  assert dag.font_size(25, 100) == 18
  assert dag.font_size(1, 100) == 13
  assert dag.font_size(0, 100) == dag.min_font_size
  assert dag.font_size(5, 0) == dag.min_font_size
  assert dag.min_font_size >= 11
}

pub fn hotter_nodes_get_bigger_fonts_test() {
  let l = layout(graph_of(3, [#(0, 1), #(1, 2)]))
  let sizes = list.map(l.nodes, fn(n) { n.font_size })
  assert sizes == list.sort(sizes, int.compare)
}

// A random graph over up to ten nodes: edges are drawn with no regard for
// direction, so cycles, parallel edges and long edges all occur.
fn random_graph(seed: Int) -> #(graph.Graph, Int) {
  let #(count, seed) = fixtures.below(seed, 10)
  let count = count + 1
  let #(edge_count, seed) = fixtures.below(seed, count * 2 + 1)
  let #(pairs, seed) =
    list.fold(list.repeat(Nil, edge_count), #([], seed), fn(state, _) {
      let #(acc, seed) = state
      let #(from, seed) = fixtures.below(seed, count)
      let #(to, seed) = fixtures.below(seed, count)
      #(
        case from == to {
          True -> acc
          False -> [#(from, to), ..acc]
        },
        seed,
      )
    })
  #(graph_of(count, pairs), seed)
}

pub fn edges_follow_the_layers_after_cycle_breaking_test() {
  check(1, 80, fn(l) {
    list.all(l.edges, fn(e) {
      case e.direction {
        Forward -> layer_of(l, e.from) < layer_of(l, e.to)
        Reversed -> layer_of(l, e.from) > layer_of(l, e.to)
      }
    })
  })
}

pub fn polylines_span_their_layers_test() {
  check(7, 80, fn(l) {
    list.all(l.edges, fn(e) {
      list.length(e.points)
      == int.absolute_value(layer_of(l, e.from) - layer_of(l, e.to)) + 1
    })
  })
}

pub fn boxes_in_a_layer_never_overlap_test() {
  check(11, 80, fn(l) {
    let by_layer = list.group(l.nodes, fn(n) { n.layer })
    list.all(dict.values(by_layer), fn(nodes) {
      let sorted = list.sort(nodes, fn(a, b) { int.compare(a.x, b.x) })
      list.zip(sorted, list.drop(sorted, 1))
      |> list.all(fn(pair) { { pair.0 }.x + { pair.0 }.width <= { pair.1 }.x })
    })
  })
}

pub fn everything_is_inside_the_drawing_test() {
  check(13, 80, fn(l) {
    list.all(l.nodes, fn(n) {
      n.x >= 0
      && n.y >= 0
      && n.x + n.width <= l.width
      && n.y + n.height <= l.height
    })
  })
}

pub fn the_layout_is_deterministic_test() {
  check_graph(17, 40, fn(g) { layout(g) == layout(g) })
}

fn check(seed: Int, runs: Int, property: fn(dag.Layout) -> Bool) -> Nil {
  check_graph(seed, runs, fn(g) { property(layout(g)) })
}

fn check_graph(seed: Int, runs: Int, property: fn(graph.Graph) -> Bool) -> Nil {
  case runs {
    0 -> Nil
    _ -> {
      let #(g, seed) = random_graph(seed)
      assert property(g)
      check_graph(seed, runs - 1, property)
    }
  }
}
