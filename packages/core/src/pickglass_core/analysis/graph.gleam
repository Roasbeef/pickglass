//// The pprof call graph, rebuilt from a profile.
////
//// The graph view of `go tool pprof` is not a plain call graph. It counts
//// each function once per sample however deeply it recurses, drops
//// functions and calls too small to see, and keeps the picture honest
//// about what it dropped: when a function in the middle of a chain is cut,
//// the call from its caller to its callee is kept as a dotted "residual"
//// edge, so the callee is still reachable. This module implements that
//// algorithm over a `Profile`, following pprof's `newTrimmedGraph` step by
//// step, so a pickglass graph and a pprof graph of the same data agree.
////
//// The steps, with pprof's defaults:
////
//// 1. Build the full graph. A node is a function; `cum` is the value of the
////    samples that pass through it, counted once per sample; `flat` is the
////    value of the samples that end in it. An edge from caller to callee
////    carries the value of the samples that contain the call, again once
////    per sample. The total is the sum of the flat values.
//// 2. Drop nodes whose absolute `cum` is below `node_fraction` (0.005) of
////    the total, and rebuild the graph from the samples keeping only the
////    survivors. A call whose path ran through a dropped node becomes a
////    residual edge.
//// 3. If there are more than `node_count` (80) nodes, order them by
////    `entropy order`, keep the first `node_count`, and rebuild again.
//// 4. Drop edges whose absolute weight is below `edge_fraction` (0.001) of
////    the total.
//// 5. Remove a residual edge when another path already connects its two
////    ends, so a dotted shortcut never repeats what the drawn nodes say.
////
//// Entropy order ranks a node higher when it branches or ends a chain and
//// lower when it only passes weight from one caller to one callee, so that
//// when the node count forces a cut it keeps the structure.
////
//// Two details of pprof are left out on purpose. Label "nodelets" (the
//// small boxes that show a node's tags) are not built, so the node count
//// counts nodes only. The profile model has no inlined frames, because a
//// BEAM stack has none, so `Edge.inline` is always `NotInline`; the field
//// exists so a renderer can treat both kinds the way pprof does if a
//// source ever produces them. Profiles with negative values (a diff) keep
//// negative nodes and edges, and every cutoff compares absolute values.
////
//// ## Flow
////
//// `build` checks the profile has stacks and takes the column's samples.
//// `graph_of` builds the raw graph (`build_raw`), cuts nodes by fraction,
//// cuts them by count, then `finish` trims edges and removes redundant
//// ones. The result is a `Graph` ready for `layout/dag`.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import pickglass_core/analysis/transform.{type Display}
import pickglass_core/profile.{
  type Column, type Profile, type Sample, type Source,
}

/// The thresholds of the trim. Zero for a field means "no limit".
pub type Config {
  Config(
    /// Nodes below this fraction of the total are dropped.
    node_fraction: Float,
    /// Edges below this fraction of the total are dropped.
    edge_fraction: Float,
    /// At most this many nodes are kept; zero keeps all.
    node_count: Int,
  )
}

/// pprof's defaults: 0.5% of the total for nodes, 0.1% for edges, and 80
/// nodes.
pub const default_config: Config =
  Config(node_fraction: 0.005, edge_fraction: 0.001, node_count: 80)

/// Whether an edge is a call the profile recorded or a shortcut over
/// dropped nodes.
pub type EdgeKind {
  /// The caller called the callee directly in the samples.
  Direct

  /// At least one sample reached the callee through a node that the trim
  /// removed. Drawn dotted.
  Residual
}

/// Whether an edge joins two lines of one inlined location.
pub type Inline {
  /// An ordinary call.
  NotInline

  /// A call that was inlined into its caller.
  Inlined
}

/// A function in the graph.
pub type Node {
  Node(
    /// The function id in the profile's table.
    function: Int,
    /// The value of samples whose leaf is this function.
    flat: Int,
    /// The value of samples that pass through this function.
    cum: Int,
  )
}

/// A call from one function to another.
pub type Edge {
  Edge(
    /// The caller's function id.
    from: Int,
    /// The callee's function id.
    to: Int,
    /// The value of the samples that contain the call.
    weight: Int,
    /// Direct or residual.
    kind: EdgeKind,
    /// Inline marker; see the module documentation.
    inline: Inline,
  )
}

/// The trimmed graph.
pub type Graph {
  Graph(
    /// The surviving nodes in display order, best entropy score first.
    nodes: List(Node),
    /// The surviving edges, heaviest first.
    edges: List(Edge),
    /// The total every fraction was taken of: the sum of flat values of the
    /// full graph.
    total: Int,
    /// The number of nodes after the fraction cut and before the count cut.
    original_nodes: Int,
    /// The number of nodes the count cut removed.
    dropped_nodes: Int,
    /// The number of edges the edge fraction removed.
    dropped_edges: Int,
  )
}

/// Why a graph could not be built.
pub type BuildError {
  /// The profile's source has no calling context, so there is nothing to
  /// connect. The source is carried so the message can name it.
  NoCallStacks(source: Source)
}

/// Apply the display settings a transform chain collected over a base
/// config. A setting the chain did not set keeps the base value.
///
/// ## Examples
///
/// ```gleam
/// graph.with_display(graph.default_config, applied.display)
/// ```
pub fn with_display(config: Config, display: Display) -> Config {
  Config(
    node_fraction: option.unwrap(display.node_fraction, config.node_fraction),
    edge_fraction: option.unwrap(display.edge_fraction, config.edge_fraction),
    node_count: option.unwrap(display.node_count, config.node_count),
  )
}

/// Build and trim the graph of one column of a profile.
///
/// ## Examples
///
/// ```gleam
/// graph.build(p, column, graph.default_config)
/// ```
pub fn build(
  profile: Profile,
  column: Column,
  config: Config,
) -> Result(Graph, BuildError) {
  case profile.shape(profile.source(profile)) {
    profile.FunctionTotals -> Error(NoCallStacks(profile.source(profile)))
    profile.CallStacks -> {
      let names = fn(id) { profile.name_of(profile, id) }
      Ok(graph_of(profile.samples(profile), column, config, names))
    }
  }
}

// The accumulated value of one node.
type NodeValue {
  NodeValue(flat: Int, cum: Int)
}

// The accumulated value of one edge.
type EdgeValue {
  EdgeValue(weight: Int, kind: EdgeKind)
}

// A graph before trimming: nodes by function id, edges by caller and
// callee.
type Raw {
  Raw(nodes: Dict(Int, NodeValue), edges: Dict(#(Int, Int), EdgeValue))
}

// What one sample's walk carries from frame to frame.
type Walk {
  Walk(
    parent: Option(Int),
    residual: EdgeKind,
    seen_nodes: Set(Int),
    seen_edges: Set(#(Int, Int)),
    raw: Raw,
  )
}

fn graph_of(
  samples: List(Sample),
  column: Column,
  config: Config,
  names: fn(Int) -> String,
) -> Graph {
  let full = build_raw(samples, column, None)
  let total = list.fold(dict.values(full.nodes), 0, fn(sum, n) { sum + n.flat })
  let node_cutoff = cutoff(total, config.node_fraction)
  let edge_cutoff = cutoff(total, config.edge_fraction)

  // Step 2: cut nodes below the fraction and rebuild from the samples, so
  // the calls that passed through a cut node reappear as residual edges.
  let by_fraction = case node_cutoff >. 0.0 {
    True -> {
      let kept = nodes_at_least(full, node_cutoff)
      build_raw(samples, column, Some(kept))
    }
    False -> full
  }
  let original_nodes = dict.size(by_fraction.nodes)

  // Step 3: when there are too many nodes, rank them and keep the top.
  let by_count = case
    config.node_count > 0 && config.node_count < original_nodes
  {
    True -> {
      let top =
        sorted_nodes(by_fraction, names)
        |> list.take(config.node_count)
        |> list.map(fn(node) { node.function })
        |> set.from_list
      build_raw(samples, column, Some(top))
    }
    False -> by_fraction
  }

  finish(by_count, total, edge_cutoff, original_nodes, names)
}

fn cutoff(total: Int, fraction: Float) -> Float {
  float.absolute_value(int.to_float(total) *. fraction)
}

// The ids of nodes whose absolute cum reaches the cutoff.
fn nodes_at_least(raw: Raw, node_cutoff: Float) -> Set(Int) {
  raw.nodes
  |> dict.to_list
  |> list.filter(fn(pair) {
    int.to_float(int.absolute_value({ pair.1 }.cum)) >=. node_cutoff
  })
  |> list.map(fn(pair) { pair.0 })
  |> set.from_list
}

// Build the raw graph from the samples. With `keep`, a frame whose
// function is not in the set is skipped and marks the next edge residual.
fn build_raw(
  samples: List(Sample),
  column: Column,
  keep: Option(Set(Int)),
) -> Raw {
  let raw =
    list.fold(samples, Raw(dict.new(), dict.new()), fn(raw, sample) {
      let value = profile.sample_value(sample, column)
      let start = Walk(None, Direct, set.new(), set.new(), raw)

      // Samples are leaf first, so the walk reverses them to run from the
      // root to the leaf.
      let end = walk(list.reverse(sample.frames), value, keep, start)
      add_leaf(end, value)
    })
  drop_empty(raw)
}

// Visit the frames from the root to the leaf. A function counts once per
// sample, and a call counts once per sample, so recursion does not inflate
// either. A call from a function to itself is not an edge.
fn walk(
  frames: List(Int),
  value: Int,
  keep: Option(Set(Int)),
  state: Walk,
) -> Walk {
  case frames {
    [] -> state
    [function, ..rest] ->
      case is_kept(keep, function) {
        False -> walk(rest, value, keep, Walk(..state, residual: Residual))
        True -> walk(rest, value, keep, visit(function, value, state))
      }
  }
}

fn is_kept(keep: Option(Set(Int)), function: Int) -> Bool {
  case keep {
    None -> True
    Some(kept) -> set.contains(kept, function)
  }
}

fn visit(function: Int, value: Int, state: Walk) -> Walk {
  let counted = case set.contains(state.seen_nodes, function) {
    True -> state
    False ->
      Walk(
        ..state,
        seen_nodes: set.insert(state.seen_nodes, function),
        raw: add_cum(state.raw, function, value),
      )
  }
  let linked = case counted.parent {
    Some(parent) -> link(counted, parent, function, value)
    None -> counted
  }

  // A kept node ends any pending residual: the next edge is a direct call
  // from it.
  Walk(..linked, parent: Some(function), residual: Direct)
}

fn link(state: Walk, parent: Int, function: Int, value: Int) -> Walk {
  let key = #(parent, function)
  case parent == function || set.contains(state.seen_edges, key) {
    True -> state
    False ->
      Walk(
        ..state,
        seen_edges: set.insert(state.seen_edges, key),
        raw: add_edge(state.raw, key, value, state.residual),
      )
  }
}

// The leaf gets the flat value only when it was kept and nothing was cut
// between it and its kept parent.
fn add_leaf(state: Walk, value: Int) -> Raw {
  case state.parent, state.residual {
    Some(leaf), Direct -> add_flat(state.raw, leaf, value)
    Some(_), Residual | None, _ -> state.raw
  }
}

fn add_cum(raw: Raw, function: Int, value: Int) -> Raw {
  let updated = case dict.get(raw.nodes, function) {
    Ok(NodeValue(flat:, cum:)) -> NodeValue(flat: flat, cum: cum + value)
    Error(Nil) -> NodeValue(flat: 0, cum: value)
  }
  Raw(..raw, nodes: dict.insert(raw.nodes, function, updated))
}

fn add_flat(raw: Raw, function: Int, value: Int) -> Raw {
  let updated = case dict.get(raw.nodes, function) {
    Ok(NodeValue(flat:, cum:)) -> NodeValue(flat: flat + value, cum: cum)
    Error(Nil) -> NodeValue(flat: value, cum: 0)
  }
  Raw(..raw, nodes: dict.insert(raw.nodes, function, updated))
}

// Residual is sticky: once any sample reaches the callee over a cut node,
// the merged edge is residual.
fn add_edge(raw: Raw, key: #(Int, Int), value: Int, kind: EdgeKind) -> Raw {
  let updated = case dict.get(raw.edges, key) {
    Ok(EdgeValue(weight:, kind: Direct)) ->
      EdgeValue(weight: weight + value, kind: kind)
    Ok(EdgeValue(weight:, kind: Residual)) ->
      EdgeValue(weight: weight + value, kind: Residual)
    Error(Nil) -> EdgeValue(weight: value, kind: kind)
  }
  Raw(..raw, edges: dict.insert(raw.edges, key, updated))
}

// A node with no value at all and the edges touching it are not drawn.
fn drop_empty(raw: Raw) -> Raw {
  let nodes =
    dict.filter(raw.nodes, fn(_, node) { node.flat != 0 || node.cum != 0 })
  let edges =
    dict.filter(raw.edges, fn(key, _) {
      dict.has_key(nodes, key.0) && dict.has_key(nodes, key.1)
    })
  Raw(nodes: nodes, edges: edges)
}

// Steps 4 and 5: trim light edges, remove redundant residual edges, and
// produce the public graph.
fn finish(
  raw: Raw,
  total: Int,
  edge_cutoff: Float,
  original_nodes: Int,
  names: fn(Int) -> String,
) -> Graph {
  let before = dict.size(raw.edges)
  let trimmed =
    Raw(
      ..raw,
      edges: dict.filter(raw.edges, fn(_, edge) {
        int.to_float(int.absolute_value(edge.weight)) >=. edge_cutoff
      }),
    )
  let dropped_edges = before - dict.size(trimmed.edges)
  let ordered = sorted_nodes(trimmed, names)
  let pruned = remove_redundant_edges(trimmed, ordered, names)
  Graph(
    nodes: ordered,
    edges: public_edges(pruned, names),
    total: total,
    original_nodes: original_nodes,
    dropped_nodes: original_nodes - dict.size(pruned.nodes),
    dropped_edges: dropped_edges,
  )
}

fn public_edges(raw: Raw, names: fn(Int) -> String) -> List(Edge) {
  raw.edges
  |> dict.to_list
  |> list.map(fn(pair) {
    Edge(
      from: pair.0.0,
      to: pair.0.1,
      weight: { pair.1 }.weight,
      kind: { pair.1 }.kind,
      inline: NotInline,
    )
  })
  |> list.sort(fn(a, b) { compare_edges(a, b, names) })
}

// Heaviest first by absolute weight, then by the names of the endpoints,
// so equal weights always come out in the same order.
fn compare_edges(a: Edge, b: Edge, names: fn(Int) -> String) -> Order {
  order.break_tie(
    int.compare(int.absolute_value(b.weight), int.absolute_value(a.weight)),
    order.break_tie(
      string.compare(names(a.from), names(b.from)),
      string.compare(names(a.to), names(b.to)),
    ),
  )
}

// ----------------------------------------------------------------- order

// The nodes ranked by entropy order, best first.
fn sorted_nodes(raw: Raw, names: fn(Int) -> String) -> List(Node) {
  let scores = entropy_scores(raw)
  raw.nodes
  |> dict.to_list
  |> list.map(fn(pair) {
    Node(function: pair.0, flat: { pair.1 }.flat, cum: { pair.1 }.cum)
  })
  |> list.sort(fn(a, b) { compare_nodes(a, b, scores, names) })
}

fn compare_nodes(
  a: Node,
  b: Node,
  scores: Dict(Int, Int),
  names: fn(Int) -> String,
) -> Order {
  let score = fn(node: Node) {
    result.unwrap(dict.get(scores, node.function), 0)
  }
  order.break_tie(
    int.compare(score(b), score(a)),
    order.break_tie(
      string.compare(names(a.function), names(b.function)),
      order.break_tie(
        int.compare(int.absolute_value(b.flat), int.absolute_value(a.flat)),
        order.break_tie(
          int.compare(int.absolute_value(b.cum), int.absolute_value(a.cum)),
          int.compare(a.function, b.function),
        ),
      ),
    ),
  )
}

// pprof's `EntropyOrder` score for every node: the entropy of its incoming
// edge weights (or one if it has none) plus the entropy of its outgoing
// weights with its own flat value as a further share (or one if it has
// none), times cum, plus flat.
fn entropy_scores(raw: Raw) -> Dict(Int, Int) {
  let incoming = group_weights(raw, fn(key) { key.1 })
  let outgoing = group_weights(raw, fn(key) { key.0 })
  dict.map_values(raw.nodes, fn(function, node) {
    let into = case dict.get(incoming, function) {
      Ok(weights) -> entropy(weights, 0)
      Error(Nil) -> 1
    }
    let out = case dict.get(outgoing, function) {
      Ok(weights) -> entropy(weights, node.flat)
      Error(Nil) -> 1
    }
    { into + out } * node.cum + node.flat
  })
}

// The edge weights grouped by one endpoint.
fn group_weights(
  raw: Raw,
  endpoint: fn(#(Int, Int)) -> Int,
) -> Dict(Int, List(Int)) {
  dict.fold(raw.edges, dict.new(), fn(groups, key, edge) {
    dict.upsert(groups, endpoint(key), fn(existing) {
      [edge.weight, ..option.unwrap(existing, [])]
    })
  })
}

// Shannon entropy in bits over the edge weights, with `own` as an extra
// share when positive, truncated to an integer as pprof does.
fn entropy(weights: List(Int), own: Int) -> Int {
  let positive =
    list.fold(weights, own, fn(sum, w) {
      case w > 0 {
        True -> sum + int.absolute_value(w)
        False -> sum
      }
    })
  case positive {
    0 -> 0
    total -> {
      let shares = case own > 0 {
        True -> [own, ..weights]
        False -> weights
      }
      let bits =
        list.fold(shares, 0.0, fn(sum, w) {
          sum +. term(int.absolute_value(w), total)
        })
      float.truncate(bits)
    }
  }
}

// -frac * log2(frac) for one share.
fn term(weight: Int, total: Int) -> Float {
  let fraction = int.to_float(weight) /. int.to_float(total)
  case float.logarithm(fraction) {
    Ok(natural) -> 0.0 -. fraction *. natural /. ln_two
    Error(Nil) -> 0.0
  }
}

const ln_two: Float = 0.6931471805599453

// ------------------------------------------------------ redundant edges

// pprof's `RemoveRedundantEdges`: walk the nodes from the last, and for
// each node its incoming edges from the lightest. Stop at the first
// non-residual edge, so no edge heavier than a real call is removed. A
// residual edge goes if its source still reaches its destination along the
// other edges.
fn remove_redundant_edges(
  raw: Raw,
  ordered: List(Node),
  names: fn(Int) -> String,
) -> Raw {
  list.fold(list.reverse(ordered), raw, fn(current, node) {
    let incoming =
      current.edges
      |> dict.to_list
      |> list.filter(fn(pair) { pair.0.1 == node.function })
      |> list.map(fn(pair) {
        Edge(
          from: pair.0.0,
          to: pair.0.1,
          weight: { pair.1 }.weight,
          kind: { pair.1 }.kind,
          inline: NotInline,
        )
      })
      |> list.sort(fn(a, b) { compare_edges(a, b, names) })
      |> list.reverse
    remove_lightest_first(current, incoming)
  })
}

fn remove_lightest_first(raw: Raw, incoming: List(Edge)) -> Raw {
  case incoming {
    [] -> raw
    [Edge(kind: Direct, ..), ..] -> raw
    [edge, ..rest] ->
      case is_redundant(raw, edge) {
        True ->
          remove_lightest_first(
            Raw(..raw, edges: dict.delete(raw.edges, #(edge.from, edge.to))),
            rest,
          )
        False -> remove_lightest_first(raw, rest)
      }
  }
}

// Whether the edge's source reaches its destination by a path that does
// not use the edge: a search backwards from the destination.
fn is_redundant(raw: Raw, edge: Edge) -> Bool {
  let sources =
    dict.fold(raw.edges, dict.new(), fn(groups, key, _) {
      dict.upsert(groups, key.1, fn(existing) {
        [key.0, ..option.unwrap(existing, [])]
      })
    })
  search_back([edge.to], set.from_list([edge.to]), sources, edge)
}

fn search_back(
  queue: List(Int),
  seen: Set(Int),
  sources: Dict(Int, List(Int)),
  edge: Edge,
) -> Bool {
  case queue {
    [] -> False
    [node, ..rest] -> {
      let parents =
        sources
        |> dict.get(node)
        |> result.unwrap([])
        |> list.filter(fn(parent) {
          !{ node == edge.to && parent == edge.from }
        })
        |> list.filter(fn(parent) { !set.contains(seen, parent) })
      case list.contains(parents, edge.from) {
        True -> True
        False ->
          search_back(
            list.append(rest, parents),
            list.fold(parents, seen, set.insert),
            sources,
            edge,
          )
      }
    }
  }
}
