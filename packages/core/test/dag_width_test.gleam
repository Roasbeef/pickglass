//// The width of a call graph shaped like a real Loom trace.
////
//// A real trace graph has 46 functions with names like
//// `runtime@strand_runtime:-load_operation/4-anonymous-10-/6`, a few hot
//// callers at the top and many edges that skip layers (the dispatcher calls
//// functions several levels down). That shape once laid out 8,515 units wide
//// for 46 functions: boxes were sized from the whole name, every skipped
//// layer got an invisible node that took a full gap of space, and the
//// coordinate pass only ever moved nodes right. The bound below is what the
//// layout must keep.

import fixtures
import gleam/int
import gleam/list
import gleam/string
import pickglass_core/analysis/graph.{Direct, Edge, Graph, Node, NotInline}
import pickglass_core/layout/dag

// Layer sizes of a graph of 46 functions.
const shape: List(Int) = [1, 3, 5, 7, 8, 7, 6, 5, 4]

fn names(id: Int) -> String {
  let base = [
    "load_operation", "provider_done", "read_decoded", "get_register",
    "drive_loop", "handle", "current_operation_owns",
  ]
  let pick = fixtures.below(id * 7 + 3, list.length(base)).0
  let assert Ok(name) = list.first(list.drop(base, pick))

  "runtime@strand_runtime:-"
  <> name
  <> "/"
  <> int.to_string(id % 5)
  <> "-anonymous-"
  <> int.to_string(id)
  <> "-/6"
}

// The same function as the page writes it in a box: no module, and the
// closure's own name turned into the function it lives in and a counter.
fn short(id: Int) -> String {
  let assert Ok(pick) = list.first(list.drop(string.split(names(id), ":"), 1))
  let assert Ok(enclosing) = list.first(string.split(pick, "-anonymous-"))

  string.drop_start(enclosing, 1) <> " fun#" <> int.to_string(id)
}

// The id of the first node of each layer, so an edge can name a node by its
// layer and position.
fn layer_starts() -> List(Int) {
  list.fold(shape, #(0, []), fn(state, size) {
    #(state.0 + size, list.append(state.1, [state.0]))
  }).1
}

fn graph_like_a_trace() -> graph.Graph {
  let starts = layer_starts()
  let count = int.sum(shape)

  let at = fn(layer, position) {
    let assert Ok(start) = list.first(list.drop(starts, layer))
    let assert Ok(size) = list.first(list.drop(shape, layer))
    start + position % size
  }

  // Every node below the root has a caller in the layer above it, and every
  // third also has one two or three layers up, which is the long edge.
  let edges =
    list.flat_map(fixtures.span(1, list.length(shape) - 1), fn(layer) {
      let assert Ok(size) = list.first(list.drop(shape, layer))

      list.flat_map(fixtures.span(0, size - 1), fn(position) {
        let callee = at(layer, position)
        let near = #(at(layer - 1, position * 2 / 3), callee)
        let far = case position % 3 == 0 && layer >= 3 {
          True -> [#(at(layer - 2 - position % 2, position), callee)]
          False -> []
        }
        let from_root = case position % 4 == 1 && layer >= 4 {
          True -> [#(0, callee)]
          False -> []
        }

        list.flatten([[near], far, from_root])
      })
    })

  Graph(
    nodes: list.map(fixtures.span(0, count - 1), fn(id) {
      Node(
        function: id,
        flat: case id % 11 {
          0 -> 900
          5 -> 300
          _ -> { id * 37 } % 40 + 1
        },
        cum: 100 - id,
      )
    }),
    edges: list.map(edges, fn(pair) {
      Edge(
        from: pair.0,
        to: pair.1,
        weight: 10,
        kind: Direct,
        inline: NotInline,
      )
    }),
    total: 10_000,
    original_nodes: count,
    dropped_nodes: 0,
    dropped_edges: 0,
  )
}

pub fn a_graph_like_a_real_trace_stays_within_a_few_screens_test() {
  let g = graph_like_a_trace()
  assert list.length(g.nodes) == 46

  let wide = dag.layout(g, names, dag.default_config)
  let narrow = dag.layout(g, short, dag.default_config)

  // Measured on this graph: 21,445 units before the fix with whole-name
  // labels, 2,313 after with short ones. The bound leaves room for tuning and
  // none for a return of the old behaviour.
  assert narrow.width <= 3000
  assert narrow.width < wide.width
}
