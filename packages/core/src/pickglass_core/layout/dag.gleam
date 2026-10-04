//// A layered layout for the call graph, so no Graphviz is needed.
////
//// pprof hands its graph to Graphviz to draw. Pickglass draws server
//// side, in SVG, from boxes and polylines computed here, and the graph it
//// draws has at most 80 nodes, so the classic layered (Sugiyama) layout is
//// enough. The layout is deterministic: nodes arrive in display order and
//// every tie is broken by that order, so equal graphs always give equal
//// pictures.
////
//// The coordinate space is abstract integers. A renderer scales it. Node
//// boxes are sized from the label (so the text fits) and from the node's
//// `flat` value through pprof's square-root scale, `11 + ceil(13 *
//// sqrt(flat / max_flat))` points of font, which exaggerates differences
//// between hot and cold nodes without letting one node swallow the page. The
//// smallest size is 11 where pprof's is 8, because pprof draws at natural
//// size and a page that scales the picture down to fit would otherwise
//// leave the coldest labels unreadable.
////
//// ## Flow
////
//// `layout` runs five stages, each its own function below:
////
//// 1. `break_cycles` finds the edges that close a cycle in a depth-first
////    walk and treats them as reversed, so the oriented graph is acyclic.
//// 2. `assign_layers` puts each node one layer below its deepest caller.
//// 3. `add_dummies` replaces an edge that spans several layers with a chain
////    through one invisible node per layer, so every segment joins
////    neighbouring layers.
//// 4. `reduce_crossings` orders the nodes in each layer by the average
////    position of their neighbours, sweeping down and up a few times.
//// 5. `assign_x` packs each layer, then alternately places each layer as
////    close as its order and gaps allow to the centres of its neighbours,
////    and `build_layout` turns each chain into a polyline.
////
//// ## Why the drawing stays narrow
////
//// Width is what a reader scrolls, so three things keep it down. A box is as
//// wide as its first line and its second line need, and the caller passes the
//// function name without its module for the first. An invisible node that
//// routes a long edge through a layer takes `edge_gap` of room, not
//// `node_gap`, because a layer of a real trace holds dozens of them. And a
//// layer is placed by `place_layer`, which finds the placement nearest the
//// wishes that keeps the order and the gaps. The greedy placement it
//// replaced only ever moved a node right, so every sweep pushed whole layers
//// further from the origin and a 46 function graph came out 17,000 units
//// wide.
////
//// After stage 1 every oriented edge goes from a lower layer to a higher
//// one; `PlacedEdge.direction` records which edges were reversed, so a
//// renderer can draw the arrowhead at the right end.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import pickglass_core/analysis/graph.{type EdgeKind, type Graph}

/// Spacing and effort of the layout.
pub type Config {
  Config(
    /// Vertical space between two layers.
    layer_gap: Int,
    /// Horizontal space between two boxes in a layer.
    node_gap: Int,
    /// Horizontal space between an invisible edge-routing node and the node
    /// beside it. It is smaller than `node_gap` because a long edge adds one
    /// such node to every layer it crosses.
    edge_gap: Int,
    /// How many down-and-up sweeps to run in both ordering and placement.
    sweeps: Int,
  )
}

/// Defaults that suit a 14 point label.
pub const default_config: Config =
  Config(layer_gap: 40, node_gap: 16, edge_gap: 4, sweeps: 4)

/// Whether an edge was drawn the way it was given or against its
/// direction to break a cycle.
pub type Direction {
  /// The edge goes from an upper layer to a lower one.
  Forward

  /// The edge closes a cycle, so its caller is in a lower layer than its
  /// callee. Draw the arrowhead at the upper end.
  Reversed
}

/// A node box.
pub type PlacedNode {
  PlacedNode(
    /// The function id.
    function: Int,
    /// The layer, zero at the top.
    layer: Int,
    /// Left edge.
    x: Int,
    /// Top edge.
    y: Int,
    /// Box width.
    width: Int,
    /// Box height.
    height: Int,
    /// Label font size in points, from the square-root scale of flat.
    font_size: Int,
    /// The node's flat value, for the label.
    flat: Int,
    /// The node's cum value, for the label.
    cum: Int,
  )
}

/// An edge as a polyline.
pub type PlacedEdge {
  PlacedEdge(
    /// The caller's function id.
    from: Int,
    /// The callee's function id.
    to: Int,
    /// The weight, for line width and label.
    weight: Int,
    /// Direct or residual (drawn dotted).
    kind: EdgeKind,
    /// Whether the edge runs with or against the layers.
    direction: Direction,
    /// Points from the caller's box to the callee's, through the layers in
    /// between.
    points: List(#(Int, Int)),
  )
}

/// The finished layout.
pub type Layout {
  Layout(
    /// Node boxes in display order.
    nodes: List(PlacedNode),
    /// Edge polylines in the graph's edge order.
    edges: List(PlacedEdge),
    /// Total width of the drawing.
    width: Int,
    /// Total height of the drawing.
    height: Int,
    /// The number of layers.
    layers: Int,
  )
}

/// Lay out a graph. `label` gives the first line of a function's box, which
/// is the function's name with no module, used only to size the box.
///
/// ## Examples
///
/// ```gleam
/// dag.layout(g, fn(id) { profile.name_of(p, id) }, dag.default_config)
/// ```
pub fn layout(
  graph: Graph,
  label: fn(Int) -> String,
  config: Config,
) -> Layout {
  let nodes = graph.nodes
  let count = list.length(nodes)
  let index =
    nodes
    |> list.index_map(fn(node, position) { #(node.function, position) })
    |> dict.from_list

  // Edges between two shown, distinct nodes, by position in the graph's
  // edge list.
  let usable =
    list.filter_map(graph.edges, fn(edge) {
      use from <- result.try(dict.get(index, edge.from))
      use to <- result.try(dict.get(index, edge.to))
      case from == to {
        True -> Error(Nil)
        False -> Ok(#(edge, from, to))
      }
    })
  let pairs = list.map(usable, fn(entry) { #(entry.1, entry.2) })

  // Stage 1: reverse the edges that close cycles, so every oriented edge
  // can point downward.
  let reversed = break_cycles(count, pairs)
  let oriented =
    list.index_map(pairs, fn(pair, position) {
      case set.contains(reversed, position) {
        True -> #(pair.1, pair.0)
        False -> pair
      }
    })

  // Stages 2 and 3: put each node in a layer and split long edges.
  let layer_of = assign_layers(count, oriented)
  let chains = add_dummies(count, oriented, layer_of)

  // Stage 4: order each layer to reduce crossings between layers.
  let orders =
    reduce_crossings(
      layer_order(chains.layer_of),
      chains.segments,
      config.sweeps,
    )

  // Stage 5: size the boxes, place them, and read the polylines off.
  let sizes = box_sizes(nodes, label, chains.next_id)
  let placed = assign_x(orders, chains.segments, sizes, config)
  build_layout(nodes, usable, reversed, chains, placed, sizes, orders, config)
}

// ----------------------------------------------------------- cycle breaking

type Color {
  OnStack
  Done
}

// The search state: node colors and the edges found to close a cycle.
type Search {
  Search(colors: Dict(Int, Color), back: Set(Int))
}

// The positions in `pairs` of edges that close a cycle in a depth-first
// walk. The walk starts from nodes with no incoming edge, then from the
// remaining nodes in display order, and follows out-edges in list order.
fn break_cycles(count: Int, pairs: List(#(Int, Int))) -> Set(Int) {
  let out =
    list.index_fold(pairs, dict.new(), fn(table, pair, position) {
      dict.upsert(table, pair.0, fn(existing) {
        list.append(option.unwrap(existing, []), [#(pair.1, position)])
      })
    })
  let targets = set.from_list(list.map(pairs, fn(pair) { pair.1 }))
  let all = span(0, count - 1)
  let roots = list.filter(all, fn(node) { !set.contains(targets, node) })
  let start = Search(dict.new(), set.new())
  let finished =
    list.fold(list.append(roots, all), start, fn(search, node) {
      search_from(node, out, search)
    })
  finished.back
}

fn search_from(
  node: Int,
  out: Dict(Int, List(#(Int, Int))),
  search: Search,
) -> Search {
  case dict.has_key(search.colors, node) {
    True -> search
    False -> {
      let entered =
        Search(..search, colors: dict.insert(search.colors, node, OnStack))
      let walked =
        list.fold(
          result.unwrap(dict.get(out, node), []),
          entered,
          fn(state, edge) { follow(edge, out, state) },
        )
      Search(..walked, colors: dict.insert(walked.colors, node, Done))
    }
  }
}

fn follow(
  edge: #(Int, Int),
  out: Dict(Int, List(#(Int, Int))),
  search: Search,
) -> Search {
  let #(target, position) = edge
  case dict.get(search.colors, target) {
    // The target is an ancestor in the walk, so this edge closes a cycle.
    Ok(OnStack) -> Search(..search, back: set.insert(search.back, position))
    Ok(Done) -> search
    Error(Nil) -> search_from(target, out, search)
  }
}

// ---------------------------------------------------------------- layering

// The longest path from any root: a node sits one layer below its deepest
// caller.
fn assign_layers(count: Int, oriented: List(#(Int, Int))) -> Dict(Int, Int) {
  let callers =
    list.fold(oriented, dict.new(), fn(table, pair) {
      dict.upsert(table, pair.1, fn(existing) {
        [pair.0, ..option.unwrap(existing, [])]
      })
    })
  list.fold(span(0, count - 1), dict.new(), fn(memo, node) {
    layer_of(node, callers, memo).1
  })
}

// Memoised depth. The oriented graph is acyclic, so the recursion ends.
fn layer_of(
  node: Int,
  callers: Dict(Int, List(Int)),
  memo: Dict(Int, Int),
) -> #(Int, Dict(Int, Int)) {
  case dict.get(memo, node) {
    Ok(layer) -> #(layer, memo)
    Error(Nil) -> {
      let #(deepest, memo) =
        list.fold(
          result.unwrap(dict.get(callers, node), []),
          #(-1, memo),
          fn(state, caller) {
            let #(layer, memo) = layer_of(caller, callers, state.1)
            #(int.max(state.0, layer), memo)
          },
        )
      #(deepest + 1, dict.insert(memo, node, deepest + 1))
    }
  }
}

// ----------------------------------------------------------- dummy chains

// The result of splitting long edges.
type Chains {
  Chains(
    // The layer of every node, real and dummy.
    layer_of: Dict(Int, Int),
    // Each oriented edge as the nodes along it, top to bottom.
    paths: List(List(Int)),
    // Every segment between neighbouring layers, upper node first.
    segments: List(#(Int, Int)),
    // The first unused node id.
    next_id: Int,
  )
}

fn add_dummies(
  count: Int,
  oriented: List(#(Int, Int)),
  layers: Dict(Int, Int),
) -> Chains {
  let start = Chains(layers, [], [], count)
  let done =
    list.fold(oriented, start, fn(chains, pair) {
      let top = layer_value(layers, pair.0)
      let bottom = layer_value(layers, pair.1)
      let inner = span(top + 1, bottom - 1)
      let #(ids, next, assigned) =
        list.fold(
          inner,
          #([], chains.next_id, chains.layer_of),
          fn(state, layer) {
            #(
              [state.1, ..state.0],
              state.1 + 1,
              dict.insert(state.2, state.1, layer),
            )
          },
        )
      let path = list.flatten([[pair.0], list.reverse(ids), [pair.1]])
      Chains(
        layer_of: assigned,
        paths: [path, ..chains.paths],
        segments: list.append(chains.segments, consecutive(path)),
        next_id: next,
      )
    })
  Chains(..done, paths: list.reverse(done.paths))
}

fn layer_value(layers: Dict(Int, Int), node: Int) -> Int {
  result.unwrap(dict.get(layers, node), 0)
}

fn consecutive(path: List(Int)) -> List(#(Int, Int)) {
  list.zip(path, list.drop(path, 1))
}

// ------------------------------------------------------ crossing reduction

// Every layer's nodes in ascending id order, which is display order for
// real nodes and creation order for dummies; the start of the sweeps.
fn layer_order(layers: Dict(Int, Int)) -> List(List(Int)) {
  let grouped =
    dict.fold(layers, dict.new(), fn(table, node, layer) {
      dict.upsert(table, layer, fn(existing) {
        [node, ..option.unwrap(existing, [])]
      })
    })
  let depth = dict.size(grouped)
  list.map(span(0, depth - 1), fn(layer) {
    grouped
    |> dict.get(layer)
    |> result.unwrap([])
    |> list.sort(int.compare)
  })
}

fn neighbours(
  segments: List(#(Int, Int)),
) -> #(Dict(Int, List(Int)), Dict(Int, List(Int))) {
  let below =
    list.fold(segments, dict.new(), fn(table, segment) {
      dict.upsert(table, segment.0, fn(existing) {
        list.append(option.unwrap(existing, []), [segment.1])
      })
    })
  let above =
    list.fold(segments, dict.new(), fn(table, segment) {
      dict.upsert(table, segment.1, fn(existing) {
        list.append(option.unwrap(existing, []), [segment.0])
      })
    })
  #(above, below)
}

// Sweep down (ordering each layer by its neighbours above) and then up
// (by its neighbours below), `sweeps` times.
fn reduce_crossings(
  orders: List(List(Int)),
  segments: List(#(Int, Int)),
  sweeps: Int,
) -> List(List(Int)) {
  let #(above, below) = neighbours(segments)
  list.fold(span(1, sweeps), orders, fn(current, _) {
    let down = sweep_down(current, above)
    sweep_up(down, below)
  })
}

// Reorder each layer after the first against the layer above it.
fn sweep_down(
  orders: List(List(Int)),
  above: Dict(Int, List(Int)),
) -> List(List(Int)) {
  case orders {
    [] -> []
    [first, ..rest] -> [first, ..sweep_rest(first, rest, above)]
  }
}

fn sweep_rest(
  fixed: List(Int),
  rest: List(List(Int)),
  neighbours: Dict(Int, List(Int)),
) -> List(List(Int)) {
  case rest {
    [] -> []
    [layer, ..more] -> {
      let ordered = barycentre_order(layer, fixed, neighbours)
      [ordered, ..sweep_rest(ordered, more, neighbours)]
    }
  }
}

// Reorder each layer before the last against the layer below it, by
// reversing the layers and reusing the downward pass.
fn sweep_up(
  orders: List(List(Int)),
  below: Dict(Int, List(Int)),
) -> List(List(Int)) {
  orders
  |> list.reverse
  |> sweep_down(below)
  |> list.reverse
}

// Order a layer by the mean position of each node's neighbours in the
// fixed layer. A node with no neighbours there keeps its own position.
// Ties keep the current order, because the sort is stable.
fn barycentre_order(
  layer: List(Int),
  fixed: List(Int),
  neighbours: Dict(Int, List(Int)),
) -> List(Int) {
  let positions =
    fixed
    |> list.index_map(fn(node, position) { #(node, position) })
    |> dict.from_list
  layer
  |> list.index_map(fn(node, own) {
    let at =
      neighbours
      |> dict.get(node)
      |> result.unwrap([])
      |> list.filter_map(fn(other) { dict.get(positions, other) })
    #(node, barycentre(at, own))
  })
  |> list.sort(fn(a, b) { float.compare(a.1, b.1) })
  |> list.map(fn(entry) { entry.0 })
}

fn barycentre(positions: List(Int), own: Int) -> Float {
  case positions {
    [] -> int.to_float(own)
    _ ->
      int.to_float(int.sum(positions)) /. int.to_float(list.length(positions))
  }
}

// ------------------------------------------------------------------- sizes

// The width and height of every node's box. Dummy nodes are thin and flat.
fn box_sizes(
  nodes: List(graph.Node),
  label: fn(Int) -> String,
  next_id: Int,
) -> Dict(Int, #(Int, Int, Int)) {
  let max_flat =
    list.fold(nodes, 0, fn(most, node) {
      int.max(most, int.absolute_value(node.flat))
    })
  let real =
    list.index_map(nodes, fn(node, position) {
      let font = font_size(node.flat, max_flat)
      let name_width = string.length(label(node.function)) * font * 6 / 10
      let width = int.max(name_width, detail_width) + 8
      #(position, #(width, font + lines_below_name, font))
    })
  let dummies =
    list.map(span(list.length(nodes), next_id - 1), fn(id) { #(id, #(2, 0, 0)) })
  dict.from_list(list.append(real, dummies))
}

// The width the lines under a node's name need: the module and the two lines
// "flat (x%)" and "of cum (y%)" are at most 22 characters, set in the smallest
// size at 7 units a character with the renderer's allowance. Their width does
// not grow with the node's font, and a node with a short name is still this
// wide.
const detail_width: Int = 154

/// The height of the lines under a node's name: the module, flat and
/// cumulative, one line each, and a little room below them. A box is its
/// font size plus this.
const lines_below_name: Int = 44

/// The smallest label font size a node gets, in points.
pub const min_font_size: Int = 11

/// The font size of the square-root label scale: `11 + ceil(13 *
/// sqrt(flat / max_flat))`, from 11 to 24 points. A node with no flat value
/// gets the smallest size.
///
/// ## Examples
///
/// ```gleam
/// dag.font_size(100, 100)
/// // -> 24
///
/// dag.font_size(25, 100)
/// // -> 18
/// ```
pub fn font_size(flat: Int, max_flat: Int) -> Int {
  case max_flat == 0 {
    True -> min_font_size
    False -> {
      let ratio =
        int.to_float(int.absolute_value(flat)) /. int.to_float(max_flat)
      let root = result.unwrap(float.square_root(ratio), 0.0)
      min_font_size + float.round(float.ceiling(13.0 *. root))
    }
  }
}

// ------------------------------------------------------------ coordinates

// Each node's left edge, from packing each layer and then pulling nodes
// toward their neighbours' centres.
fn assign_x(
  orders: List(List(Int)),
  segments: List(#(Int, Int)),
  sizes: Dict(Int, #(Int, Int, Int)),
  config: Config,
) -> Dict(Int, Int) {
  let #(above, below) = neighbours(segments)
  let packed =
    list.fold(orders, dict.new(), fn(lefts, layer) {
      place_layer(layer, sizes, config, lefts, fn(_) { None })
    })
  let settled =
    list.fold(span(1, config.sweeps), packed, fn(lefts, _) {
      let down = pull_layers(list.drop(orders, 1), above, sizes, config, lefts)
      pull_layers(
        list.reverse(list.take(orders, int.max(list.length(orders) - 1, 0))),
        below,
        sizes,
        config,
        down,
      )
    })
  let smallest =
    dict.fold(settled, 0, fn(least, _, left) { int.min(least, left) })
  dict.map_values(settled, fn(_, left) { left - smallest })
}

// Re-place each of the layers, in the order given, with each node's wish
// being the mean centre of its neighbours in the layer already placed.
fn pull_layers(
  layers: List(List(Int)),
  neighbours: Dict(Int, List(Int)),
  sizes: Dict(Int, #(Int, Int, Int)),
  config: Config,
  lefts: Dict(Int, Int),
) -> Dict(Int, Int) {
  list.fold(layers, lefts, fn(current, layer) {
    place_layer(layer, sizes, config, current, fn(node) {
      let centres =
        neighbours
        |> dict.get(node)
        |> result.unwrap([])
        |> list.filter_map(fn(other) { centre(current, sizes, other) })
      case centres {
        [] -> None
        _ -> Some(int.sum(centres) / list.length(centres))
      }
    })
  })
}

fn centre(
  lefts: Dict(Int, Int),
  sizes: Dict(Int, #(Int, Int, Int)),
  node: Int,
) -> Result(Int, Nil) {
  use left <- result.try(dict.get(lefts, node))
  use size <- result.map(dict.get(sizes, node))
  left + size.0 / 2
}

// Place one layer. Each node has a wished centre, or none, in which case it
// wishes to stay where it is. The layer keeps its order and keeps each pair
// of neighbours a gap apart, and within those limits it is placed as near the
// wishes as it can be, in the least-squares sense.
//
// That is an isotonic regression. Write each node's left edge as its offset
// (the room the nodes before it need) plus a shift. The gap limits say only
// that shifts do not decrease from left to right, and the nearest such shifts
// to the wished ones are found by pooling neighbours that are out of order.
fn place_layer(
  layer: List(Int),
  sizes: Dict(Int, #(Int, Int, Int)),
  config: Config,
  lefts: Dict(Int, Int),
  wish: fn(Int) -> Option(Int),
) -> Dict(Int, Int) {
  let offsets = layer_offsets(layer, sizes, config)

  let targets =
    list.map(offsets, fn(entry) {
      let #(node, offset) = entry
      let wanted = case wish(node) {
        Some(centre) -> centre - width_of(sizes, node) / 2
        None -> result.unwrap(dict.get(lefts, node), 0)
      }
      wanted - offset
    })

  let shifts = nondecreasing(targets)

  list.zip(offsets, shifts)
  |> list.fold(lefts, fn(table, entry) {
    dict.insert(table, entry.0.0, entry.0.1 + entry.1)
  })
}

fn width_of(sizes: Dict(Int, #(Int, Int, Int)), node: Int) -> Int {
  dict.get(sizes, node)
  |> result.map(fn(size) { size.0 })
  |> result.unwrap(0)
}

// An invisible edge-routing node has no height, and no real box does.
fn is_dummy(sizes: Dict(Int, #(Int, Int, Int)), node: Int) -> Bool {
  dict.get(sizes, node)
  |> result.map(fn(size) { size.1 == 0 })
  |> result.unwrap(False)
}

// Each node of the layer with the room the nodes before it take, which is
// its left edge when the layer is packed as tightly as the gaps allow.
fn layer_offsets(
  layer: List(Int),
  sizes: Dict(Int, #(Int, Int, Int)),
  config: Config,
) -> List(#(Int, Int)) {
  let #(_, reversed) =
    list.fold(layer, #(None, []), fn(state, node) {
      let #(previous, acc) = state
      let offset = case previous {
        None -> 0
        Some(#(before, before_offset)) -> {
          let gap = case is_dummy(sizes, before) || is_dummy(sizes, node) {
            True -> config.edge_gap
            False -> config.node_gap
          }
          before_offset + width_of(sizes, before) + gap
        }
      }
      #(Some(#(node, offset)), [#(node, offset), ..acc])
    })
  list.reverse(reversed)
}

// The sequence nearest to `targets` that never decreases, by pooling
// adjacent runs whose means are out of order. A pooled run takes its mean,
// rounded toward zero, which keeps the sequence non-decreasing.
fn nondecreasing(targets: List(Int)) -> List(Int) {
  targets
  |> list.fold([], fn(runs, target) { pool([#(target, 1), ..runs]) })
  |> list.reverse
  |> list.flat_map(fn(run) { list.repeat(run.0 / run.1, run.1) })
}

// Runs are kept newest first as #(sum, count). While the newest run's mean
// is below the one before it, merge them.
fn pool(runs: List(#(Int, Int))) -> List(#(Int, Int)) {
  case runs {
    [#(sum, count), #(before_sum, before_count), ..rest] ->
      case before_sum * count > sum * before_count {
        True -> pool([#(before_sum + sum, before_count + count), ..rest])
        False -> runs
      }
    _ -> runs
  }
}

// ----------------------------------------------------------------- output

fn build_layout(
  nodes: List(graph.Node),
  usable: List(#(graph.Edge, Int, Int)),
  reversed: Set(Int),
  chains: Chains,
  lefts: Dict(Int, Int),
  sizes: Dict(Int, #(Int, Int, Int)),
  orders: List(List(Int)),
  config: Config,
) -> Layout {
  let tops = layer_tops(orders, sizes, config.layer_gap)
  let placed_nodes =
    list.index_map(nodes, fn(node, position) {
      let size = result.unwrap(dict.get(sizes, position), #(0, 0, 0))
      PlacedNode(
        function: node.function,
        layer: layer_value(chains.layer_of, position),
        x: result.unwrap(dict.get(lefts, position), 0),
        y: result.unwrap(
          dict.get(tops, layer_value(chains.layer_of, position)),
          0,
        ),
        width: size.0,
        height: size.1,
        font_size: size.2,
        flat: node.flat,
        cum: node.cum,
      )
    })
  let placed_edges =
    list.index_map(list.zip(usable, chains.paths), fn(entry, position) {
      let #(#(edge, _, _), path) = entry
      let direction = case set.contains(reversed, position) {
        True -> Reversed
        False -> Forward
      }
      let points = polyline(path, chains.layer_of, lefts, sizes, tops)
      PlacedEdge(
        from: edge.from,
        to: edge.to,
        weight: edge.weight,
        kind: edge.kind,
        direction: direction,
        points: case direction {
          Forward -> points
          Reversed -> list.reverse(points)
        },
      )
    })
  let width =
    list.fold(placed_nodes, 0, fn(most, node) {
      int.max(most, node.x + node.width)
    })
  let height =
    list.fold(placed_nodes, 0, fn(most, node) {
      int.max(most, node.y + node.height)
    })
  Layout(
    nodes: placed_nodes,
    edges: placed_edges,
    width: width,
    height: height,
    layers: list.length(orders),
  )
}

// The top of each layer: layers stack with a gap, each as tall as its
// tallest box.
fn layer_tops(
  orders: List(List(Int)),
  sizes: Dict(Int, #(Int, Int, Int)),
  gap: Int,
) -> Dict(Int, Int) {
  let #(_, tops) =
    list.index_fold(orders, #(0, dict.new()), fn(state, layer, position) {
      let tallest =
        list.fold(layer, 0, fn(most, node) {
          int.max(most, result.unwrap(dict.get(sizes, node), #(0, 0, 0)).1)
        })
      #(state.0 + tallest + gap, dict.insert(state.1, position, state.0))
    })
  tops
}

// A polyline through the centres of the nodes along a path, entering the
// first box at its bottom and the last at its top.
fn polyline(
  path: List(Int),
  layers: Dict(Int, Int),
  lefts: Dict(Int, Int),
  sizes: Dict(Int, #(Int, Int, Int)),
  tops: Dict(Int, Int),
) -> List(#(Int, Int)) {
  list.index_map(path, fn(node, position) {
    let size = result.unwrap(dict.get(sizes, node), #(0, 0, 0))
    let x = result.unwrap(dict.get(lefts, node), 0) + size.0 / 2
    let top = result.unwrap(dict.get(tops, layer_value(layers, node)), 0)
    let y = case position {
      0 -> top + size.1
      _ -> top
    }
    #(x, y)
  })
}

// The integers from `from` through `to`, empty when `to` is smaller.
fn span(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..span(from + 1, to)]
  }
}
