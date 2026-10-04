//// Peek: who calls a function and whom it calls.
////
//// Peek is pprof's per-function neighbourhood. For a function it lists the
//// callers with the weight of each call, then the function's own flat and
//// cum, then the callees with their weights. It reads the same trimmed
//// graph as the graph view, so a caller or callee that the trim removed is
//// not listed, and a call that passed through a removed node is listed with
//// the `Residual` kind, which a renderer should mark as "via removed
//// nodes". Percentages of a weight are relative to the function's `cum`,
//// which the renderer divides itself.
////
//// ## Flow
////
//// `at` finds one node in the graph and calls `links` twice to split the
//// edges around it into callers and callees. `matching` does that for
//// every node whose printable name matches a pattern, in the graph's
//// display order.

import gleam/list
import gleam/result
import pickglass_core/analysis/graph.{type EdgeKind, type Graph, type Inline}
import pickglass_core/analysis/pattern.{type PatternError}
import pickglass_core/profile.{type Profile}

/// A neighbour of the function, with the weight of the call between them.
pub type Link {
  Link(
    /// The neighbour's function id.
    function: Int,
    /// The value of the samples that contain the call.
    weight: Int,
    /// A direct call or one through removed nodes.
    kind: EdgeKind,
    /// The inline marker of the edge.
    inline: Inline,
  )
}

/// A function and its neighbours.
pub type Peek {
  Peek(
    /// The function id.
    function: Int,
    /// Its flat value.
    flat: Int,
    /// Its cum value.
    cum: Int,
    /// The callers, heaviest first.
    callers: List(Link),
    /// The callees, heaviest first.
    callees: List(Link),
  )
}

/// Peek at one function of a graph, or nothing if the graph does not hold
/// it.
///
/// ## Examples
///
/// ```gleam
/// peek.at(g, function_id)
/// ```
pub fn at(graph: Graph, function: Int) -> Result(Peek, Nil) {
  use node <- result.map(
    list.find(graph.nodes, fn(node) { node.function == function }),
  )
  Peek(
    function: function,
    flat: node.flat,
    cum: node.cum,
    callers: links(graph, fn(edge) { edge.to == function }, fn(edge) {
      edge.from
    }),
    callees: links(graph, fn(edge) { edge.from == function }, fn(edge) {
      edge.to
    }),
  )
}

// The graph's edges are already heaviest first, and filtering keeps that.
fn links(
  graph: Graph,
  wanted: fn(graph.Edge) -> Bool,
  neighbour: fn(graph.Edge) -> Int,
) -> List(Link) {
  graph.edges
  |> list.filter(wanted)
  |> list.map(fn(edge) {
    Link(
      function: neighbour(edge),
      weight: edge.weight,
      kind: edge.kind,
      inline: edge.inline,
    )
  })
}

/// Peek at every function whose printable name matches a pattern, in the
/// graph's display order. A pattern that matches nothing gives an empty
/// list, which the caller should report.
///
/// ## Examples
///
/// ```gleam
/// peek.matching(p, g, "gateway")
/// ```
pub fn matching(
  profile: Profile,
  graph: Graph,
  text: String,
) -> Result(List(Peek), PatternError) {
  use compiled <- result.map(pattern.compile(text))
  graph.nodes
  |> list.filter(fn(node) {
    pattern.matches(compiled, profile.name_of(profile, node.function))
  })
  |> list.filter_map(fn(node) { at(graph, node.function) })
}
