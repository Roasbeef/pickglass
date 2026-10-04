import fixtures
import gleam/list
import gleam/string
import pickglass_core/analysis/graph.{Config, Direct, Residual}
import pickglass_core/profile.{type Profile}
import pickglass_core/unit

fn build(p: Profile, config: graph.Config) -> graph.Graph {
  let assert Ok(g) = graph.build(p, fixtures.column(p), config)
  g
}

// Edges as `from>to` with weight and kind, in the graph's order.
fn edges(p: Profile, g: graph.Graph) -> List(#(String, Int, graph.EdgeKind)) {
  list.map(g.edges, fn(edge) {
    #(
      short(profile.name_of(p, edge.from))
        <> ">"
        <> short(profile.name_of(p, edge.to)),
      edge.weight,
      edge.kind,
    )
  })
}

// `m:a/0` is written `a` in the expectations.
fn short(name: String) -> String {
  name |> string.replace("m:", "") |> string.replace("/0", "")
}

fn node_names(p: Profile, g: graph.Graph) -> List(String) {
  g.nodes
  |> list.map(fn(node) { short(profile.name_of(p, node.function)) })
  |> list.sort(string.compare)
}

// Pprof's defaults, but with the count cut off so only the fractions act.
fn no_count() -> graph.Config {
  Config(..graph.default_config, node_count: 0)
}

pub fn flat_and_cum_are_counted_per_sample_test() {
  let p = fixtures.calls([#(["a", "b"], 7), #(["a", "c"], 3), #(["a"], 2)])
  let g = build(p, no_count())
  let by_name =
    list.map(g.nodes, fn(n) {
      #(short(profile.name_of(p, n.function)), n.flat, n.cum)
    })
    |> list.sort(fn(x, y) { string.compare(x.0, y.0) })
  assert by_name == [#("a", 2, 12), #("b", 7, 7), #("c", 3, 3)]
  assert g.total == 12
  assert edges(p, g) == [#("a>b", 7, Direct), #("a>c", 3, Direct)]
}

// Recursion must not inflate cum or create a self edge.
pub fn recursion_counts_once_per_sample_test() {
  let p = fixtures.calls([#(["a", "b", "b", "b"], 10)])
  let g = build(p, no_count())
  let assert Ok(b) = list.find(g.nodes, fn(n) { n.flat == 10 })
  assert b.cum == 10
  assert edges(p, g) == [#("a>b", 10, Direct)]
}

// The cutoff is 0.5% of the total flat. A node whose cum equals it is kept,
// and one below it is dropped.
pub fn node_fraction_boundary_test() {
  let p =
    fixtures.calls([
      #(["main", "big"], 991),
      #(["main", "x"], 5),
      #(["main", "y"], 4),
    ])
  let g = build(p, no_count())
  assert g.total == 1000
  assert node_names(p, g) == ["big", "main", "x"]
}

pub fn the_first_cut_node_is_not_an_edge_test() {
  let p =
    fixtures.calls([
      #(["main", "big"], 991),
      #(["main", "x"], 5),
      #(["main", "y"], 4),
    ])
  let g = build(p, no_count())
  // y's samples ended in a cut leaf, so they add no flat value anywhere.
  let flat = list.fold(g.nodes, 0, fn(sum, n) { sum + n.flat })
  assert flat == 996
  assert edges(p, g) == [#("main>big", 991, Direct), #("main>x", 5, Direct)]
}

// Cutting b in a -> b -> c leaves c reachable through a dotted edge.
pub fn a_cut_middle_node_leaves_a_residual_edge_test() {
  let p =
    fixtures.calls([
      #(["a", "d"], 500),
      #(["a", "b", "c"], 2),
      #(["e", "c"], 3),
    ])
  let g = build(p, no_count())
  assert node_names(p, g) == ["a", "c", "d", "e"]
  assert edges(p, g)
    == [
      #("a>d", 500, Direct),
      #("e>c", 3, Direct),
      #("a>c", 2, Residual),
    ]
}

// A residual edge is dropped when another path joins the same ends.
pub fn redundant_residual_edges_are_removed_test() {
  let p =
    fixtures.calls([
      #(["a", "d"], 500),
      #(["a", "d", "c"], 3),
      #(["a", "b", "c"], 2),
    ])
  let g = build(p, no_count())
  assert node_names(p, g) == ["a", "c", "d"]
  assert edges(p, g) == [#("a>d", 503, Direct), #("d>c", 3, Direct)]
}

// Residual is sticky: one sample through a cut node marks the merged edge.
pub fn residual_is_sticky_when_edges_merge_test() {
  let p =
    fixtures.calls([
      #(["a", "c"], 500),
      #(["a", "b", "c"], 2),
    ])
  let g = build(p, no_count())
  assert edges(p, g) == [#("a>c", 502, Residual)]
}

pub fn edge_fraction_drops_light_edges_test() {
  let p =
    fixtures.calls([
      #(["r", "p1", "c"], 9),
      #(["r", "p1", "z"], 100),
      #(["r", "p2", "c"], 60),
      #(["r", "w"], 9831),
    ])
  let g = build(p, no_count())
  assert g.total == 10_000
  assert g.dropped_edges == 1
  let names = list.map(edges(p, g), fn(e) { e.0 })
  assert !list.contains(names, "p1>c")
  assert list.contains(names, "r>p1")
  assert list.contains(names, "p2>c")
}

// A pass-through node scores zero and is the first to go when the count
// forces a cut, leaving a residual edge over it.
pub fn node_count_cuts_by_entropy_order_test() {
  let p = fixtures.calls([#(["main", "mid", "leaf"], 10)])
  let g = build(p, Config(..graph.default_config, node_count: 2))
  assert list.map(g.nodes, fn(n) { short(profile.name_of(p, n.function)) })
    == ["leaf", "main"]
  assert edges(p, g) == [#("main>leaf", 10, Residual)]
  assert g.original_nodes == 3
  assert g.dropped_nodes == 1
}

pub fn node_count_zero_keeps_everything_test() {
  let p = fixtures.calls([#(["a", "b", "c", "d"], 10)])
  let g = build(p, no_count())
  assert list.length(g.nodes) == 4
  assert g.dropped_nodes == 0
}

pub fn counter_sources_have_no_graph_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCounters,
      [profile.ValueType("calls", unit.Count)],
      [],
      [],
    )
  let assert Ok(column) = profile.column(p, 0)
  assert graph.build(p, column, graph.default_config)
    == Error(graph.NoCallStacks(profile.TracedCounters))
}
