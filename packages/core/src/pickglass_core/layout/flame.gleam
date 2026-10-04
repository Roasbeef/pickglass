//// Flame and icicle graph layout with a bounded number of boxes.
////
//// A flame graph merges identical call paths into a tree and draws each
//// tree node as a box whose width is its share of the profile. A real
//// profile has far more nodes than pixels, and a server that sent every
//// node to the browser would send an unreadable page that is also slow to
//// build. This layout therefore follows pprof's renderer: a box narrower
//// than a minimum width is not drawn, its value is added to the box it hung
//// from, and the count of boxes omitted is kept, so the picture says how
//// much it left out instead of pretending to be complete. On top of that
//// sits a hard maximum number of boxes, applied by keeping the widest.
//// Both limits are deterministic functions of the profile and the config.
////
//// A box carries its x and width in integer units of the configured
//// width, its depth (zero for the root), its row (the vertical position,
//// which differs between a flame graph, where the root is at the bottom,
//// and an icicle graph, where it is at the top), its frame, its value, its
//// own share (`self`), and what was folded into it. Colour is by package:
//// the package of a function's module is hashed to one of 24 buckets, and
//// `hue` spaces the buckets by the golden ratio, as pprof does, so that
//// neighbouring packages get distinct colours.
////
//// Differential layouts follow pprof's `-diff_base`. The caller merges the
//// base (negated) and candidate profiles with `analysis/diff`, which sums
//// samples with identical stacks, so an unchanged stack cancels to zero and
//// disappears. A node's width is the sum of the absolute net values of the
//// stacks through it, and its `delta` is their signed sum: positive is a
//// regression (red), negative an improvement (green).
////
//// Counters and allocation counts have no stacks, so asking for a flame
//// graph of them is an error, not an empty picture.
////
//// ## Flow
////
//// `layout` merges samples by stack and builds the call tree (`insert`),
//// sizes it (`annotate`), walks it depth-first emitting a candidate for
//// every box wide enough (`emit`), keeps the widest boxes up to the limit
//// (`select`), recomputes what each kept box folded, and assigns rows.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import pickglass_core/profile.{
  type Column, type Profile, type Sample, type Source,
}

/// Which way the root faces.
pub type Orientation {
  /// The root is at the bottom row and callees stack above it.
  Flame

  /// The root is at the top row and callees hang below it.
  Icicle
}

/// Whether the layout compares two profiles.
pub type Mode {
  /// An ordinary profile; every box has delta zero.
  Plain

  /// A merged differential profile; boxes carry their net change.
  Differential
}

/// The limits and shape of a layout.
pub type Config {
  Config(
    /// The total width, in layout units, of the root box.
    width: Int,
    /// Boxes narrower than this are folded into their parent.
    min_width: Int,
    /// At most this many boxes are returned; the widest are kept.
    max_boxes: Int,
    /// Flame or icicle.
    orientation: Orientation,
    /// Plain or differential.
    mode: Mode,
  )
}

/// pprof's renderer constants for a 1200 unit wide chart: boxes under 4
/// units are folded.
pub const default_config: Config =
  Config(
    width: 1200,
    min_width: 4,
    max_boxes: 2000,
    orientation: Flame,
    mode: Plain,
  )

/// What a box stands for.
pub type Frame {
  /// The synthetic root that holds the whole profile.
  Root

  /// A function, by id in the profile's table.
  Function(id: Int)
}

/// One drawn box.
pub type Box {
  Box(
    /// Left edge, in layout units.
    x: Int,
    /// Width, in layout units.
    width: Int,
    /// Distance from the root; the root is zero.
    depth: Int,
    /// Vertical position from the top of the drawing, zero for the first
    /// row. Flame graphs put the root last; icicle graphs put it first.
    row: Int,
    /// The function, or the root.
    frame: Frame,
    /// The value that decides the width: for a plain profile the node's
    /// cumulative value, for a differential one the sum of absolute net
    /// changes of the stacks through it.
    value: Int,
    /// The part of `value` belonging to this node's own stacks, those that
    /// end here.
    self: Int,
    /// The signed net change through this node in a differential layout,
    /// positive for a regression; always zero in a plain layout.
    delta: Int,
    /// The colour bucket, 0 to 23, from the package of the function.
    bucket: Int,
    /// The value of the child boxes that were omitted below this box.
    folded_value: Int,
    /// The number of boxes omitted below this box, counting all their
    /// descendants.
    folded_boxes: Int,
  )
}

/// A finished layout.
pub type Layout {
  Layout(
    /// The boxes ordered by depth, then left to right.
    boxes: List(Box),
    /// The value of the root, the width's denominator. Zero means the
    /// profile has nothing to draw and `boxes` is empty.
    total: Int,
    /// The number of rows, one more than the deepest kept box's depth.
    rows: Int,
    /// The number of tree nodes that were not drawn, for either limit. The
    /// drawn and omitted counts add up to the size of the call tree.
    omitted_boxes: Int,
    /// Flame or icicle.
    orientation: Orientation,
    /// Plain or differential.
    mode: Mode,
  )
}

/// Why a layout could not be made.
pub type LayoutError {
  /// The source carries no calling context, so there is no tree to draw.
  NoCallStacks(source: Source)
}

/// The number of colour buckets.
pub const bucket_count: Int = 24

// The call tree: values are split into the positive and negative sums of
// the merged stacks that pass through, so a differential profile keeps both.
type Tree {
  Tree(
    pos: Int,
    neg: Int,
    self_pos: Int,
    self_neg: Int,
    size: Int,
    children: Dict(Int, Tree),
  )
}

/// Lay out a profile column as a flame or icicle graph.
///
/// ## Examples
///
/// ```gleam
/// flame.layout(p, column, flame.default_config)
/// ```
pub fn layout(
  profile: Profile,
  column: Column,
  config: Config,
) -> Result(Layout, LayoutError) {
  case profile.shape(profile.source(profile)) {
    profile.FunctionTotals -> Error(NoCallStacks(profile.source(profile)))
    profile.CallStacks -> Ok(lay_out(profile, column, config))
  }
}

fn lay_out(profile: Profile, column: Column, config: Config) -> Layout {
  let tree = annotate(build_tree(profile.samples(profile), column))
  let total = tree.pos + tree.neg
  let nodes = tree.size
  case total == 0 {
    True ->
      Layout(
        boxes: [],
        total: 0,
        rows: 0,
        omitted_boxes: nodes,
        orientation: config.orientation,
        mode: config.mode,
      )
    False -> {
      let candidates = emit_all(profile, tree, total, config)
      let kept = select(candidates, int.max(config.max_boxes, 1))
      let boxes = refold(kept, candidates)
      finish(boxes, nodes, total, config)
    }
  }
}

// ------------------------------------------------------------------- tree

// Merge samples with identical stacks first, summing their values, as
// pprof's profile merge does. A stack whose merged value is zero then
// contributes nothing, which is how unchanged stacks vanish from a diff.
fn build_tree(samples: List(Sample), column: Column) -> Tree {
  let merged =
    list.fold(samples, dict.new(), fn(table, sample) {
      dict.upsert(table, sample.frames, fn(existing) {
        profile.sample_value(sample, column) + option.unwrap(existing, 0)
      })
    })
  dict.fold(merged, empty_tree(), fn(tree, frames, net) {
    insert(tree, list.reverse(frames), net)
  })
}

fn empty_tree() -> Tree {
  Tree(pos: 0, neg: 0, self_pos: 0, self_neg: 0, size: 0, children: dict.new())
}

// Add a stack's net value to every node on the path from the root, and to
// the leaf's own share.
fn insert(tree: Tree, path: List(Int), net: Int) -> Tree {
  let counted = add_value(tree, net)
  case path {
    [] -> add_self(counted, net)
    [function, ..rest] -> {
      let child =
        result.lazy_unwrap(dict.get(counted.children, function), empty_tree)
      Tree(
        ..counted,
        children: dict.insert(
          counted.children,
          function,
          insert(child, rest, net),
        ),
      )
    }
  }
}

fn add_value(tree: Tree, net: Int) -> Tree {
  case net > 0 {
    True -> Tree(..tree, pos: tree.pos + net)
    False -> Tree(..tree, neg: tree.neg - net)
  }
}

fn add_self(tree: Tree, net: Int) -> Tree {
  case net > 0 {
    True -> Tree(..tree, self_pos: tree.self_pos + net)
    False -> Tree(..tree, self_neg: tree.self_neg - net)
  }
}

// Fill in each node's subtree size, itself included.
fn annotate(tree: Tree) -> Tree {
  let children =
    dict.map_values(tree.children, fn(_, child) { annotate(child) })
  let size = dict.fold(children, 1, fn(sum, _, child) { sum + child.size })
  Tree(..tree, children: children, size: size)
}

// ------------------------------------------------------------- candidates

// A box that fits, with its place in the tree of candidates.
type Candidate {
  Candidate(id: Int, parent: Int, box: Box, size: Int)
}

fn emit_all(
  profile: Profile,
  tree: Tree,
  total: Int,
  config: Config,
) -> List(Candidate) {
  let #(candidates, _) =
    emit(profile, tree, Root, 0, 0, -1, total, config, #([], 0))
  list.reverse(candidates)
}

// Emit one node as a candidate, then its children left to right. A child
// narrower than the minimum is not emitted and is added to this box's fold.
// Offsets are in value units, so a dropped child still moves its siblings
// right, and every x is a rounded division of one cumulative value, which
// is what keeps the children inside their parent.
fn emit(
  profile: Profile,
  tree: Tree,
  frame: Frame,
  depth: Int,
  offset: Int,
  parent: Int,
  total: Int,
  config: Config,
  state: #(List(Candidate), Int),
) -> #(List(Candidate), Int) {
  let magnitude = tree.pos + tree.neg
  let x = offset * config.width / total
  let width = { offset + magnitude } * config.width / total - x
  case width < config.min_width {
    True -> state
    False -> {
      let #(candidates, next_id) = state
      let id = next_id
      let ordered = ordered_children(profile, tree)
      let #(placed, folded_value, folded_boxes) =
        measure_children(ordered, offset, total, config)
      let box =
        Box(
          x: x,
          width: width,
          depth: depth,
          row: depth,
          frame: frame,
          value: magnitude,
          self: tree.self_pos + tree.self_neg,
          delta: delta_of(tree, config.mode),
          bucket: bucket_of(profile, frame),
          folded_value: folded_value,
          folded_boxes: folded_boxes,
        )
      let own = Candidate(id: id, parent: parent, box: box, size: tree.size)
      list.fold(placed, #([own, ..candidates], id + 1), fn(acc, entry) {
        let #(function, child, child_offset) = entry
        emit(
          profile,
          child,
          Function(function),
          depth + 1,
          child_offset,
          id,
          total,
          config,
          acc,
        )
      })
    }
  }
}

fn delta_of(tree: Tree, mode: Mode) -> Int {
  case mode {
    Plain -> 0
    Differential -> tree.pos - tree.neg
  }
}

// Children widest first, then by function name and id, so that equal
// profiles always give equal pictures.
fn ordered_children(profile: Profile, tree: Tree) -> List(#(Int, Tree)) {
  tree.children
  |> dict.to_list
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare(magnitude(b.1), magnitude(a.1)),
      order.break_tie(
        string.compare(
          profile.name_of(profile, a.0),
          profile.name_of(profile, b.0),
        ),
        int.compare(a.0, b.0),
      ),
    )
  })
}

fn magnitude(tree: Tree) -> Int {
  tree.pos + tree.neg
}

// Give each child its offset, and total up the children too narrow to draw.
fn measure_children(
  ordered: List(#(Int, Tree)),
  offset: Int,
  total: Int,
  config: Config,
) -> #(List(#(Int, Tree, Int)), Int, Int) {
  let #(_, placed, folded_value, folded_boxes) =
    list.fold(ordered, #(offset, [], 0, 0), fn(state, entry) {
      let #(at, placed, value, boxes) = state
      let #(function, child) = entry
      let next = at + magnitude(child)
      let x = at * config.width / total
      let width = next * config.width / total - x
      case width < config.min_width {
        True -> #(next, placed, value + magnitude(child), boxes + child.size)
        False -> #(next, [#(function, child, at), ..placed], value, boxes)
      }
    })
  #(list.reverse(placed), folded_value, folded_boxes)
}

fn bucket_of(profile: Profile, frame: Frame) -> Int {
  case frame {
    Root -> 0
    Function(id) ->
      case profile.function(profile, id) {
        Ok(function) -> colour_bucket(profile.package_of(function.module))
        Error(Nil) -> 0
      }
  }
}

// -------------------------------------------------------------- selection

// The ids of the `limit` widest candidates. Ties go to the shallower box,
// then the leftmost, then the earlier one. A child is never wider than its
// parent, so a kept child always has its parent kept.
fn select(candidates: List(Candidate), limit: Int) -> set.Set(Int) {
  candidates
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare(b.box.width, a.box.width),
      order.break_tie(
        int.compare(a.box.depth, b.box.depth),
        order.break_tie(int.compare(a.box.x, b.box.x), int.compare(a.id, b.id)),
      ),
    )
  })
  |> list.take(limit)
  |> list.map(fn(candidate) { candidate.id })
  |> set.from_list
}

// Add to each kept box what its dropped candidate children carried. The
// drops for being too narrow were counted in `emit`; these are the ones
// the box limit removed.
fn refold(kept: set.Set(Int), candidates: List(Candidate)) -> List(Box) {
  let cut =
    list.filter(candidates, fn(candidate) {
      !set.contains(kept, candidate.id) && set.contains(kept, candidate.parent)
    })
  let extra =
    list.fold(cut, dict.new(), fn(table, candidate) {
      dict.upsert(table, candidate.parent, fn(existing) {
        let #(value, boxes) = option.unwrap(existing, #(0, 0))
        #(value + candidate.box.value, boxes + candidate.size)
      })
    })
  candidates
  |> list.filter(fn(candidate) { set.contains(kept, candidate.id) })
  |> list.map(fn(candidate) {
    let #(value, boxes) = result.unwrap(dict.get(extra, candidate.id), #(0, 0))
    Box(
      ..candidate.box,
      folded_value: candidate.box.folded_value + value,
      folded_boxes: candidate.box.folded_boxes + boxes,
    )
  })
}

// Order the boxes, assign rows and report the omitted count.
fn finish(boxes: List(Box), nodes: Int, total: Int, config: Config) -> Layout {
  let ordered =
    list.sort(boxes, fn(a, b) {
      order.break_tie(int.compare(a.depth, b.depth), int.compare(a.x, b.x))
    })
  let deepest =
    list.fold(ordered, 0, fn(most, box) { int.max(most, box.depth) })
  let rowed =
    list.map(ordered, fn(box) {
      case config.orientation {
        Icicle -> box
        Flame -> Box(..box, row: deepest - box.depth)
      }
    })
  Layout(
    boxes: rowed,
    total: total,
    rows: deepest + 1,
    omitted_boxes: nodes - list.length(rowed),
    orientation: config.orientation,
    mode: config.mode,
  )
}

// ------------------------------------------------------------------ colour

/// The colour bucket of a package: its name hashed with FNV-1a, modulo 24.
/// pprof hashes the package name the same way in spirit (it uses SHA-256);
/// all that matters is that the same package always gets the same bucket.
///
/// ## Examples
///
/// ```gleam
/// flame.colour_bucket("loom") == flame.colour_bucket("loom")
/// // -> True
/// ```
pub fn colour_bucket(package: String) -> Int {
  let hash =
    package
    |> string.to_utf_codepoints
    |> list.fold(2_166_136_261, fn(hash, codepoint) {
      let mixed =
        int.bitwise_exclusive_or(hash, string.utf_codepoint_to_int(codepoint))
      mixed * 16_777_619 % 4_294_967_296
    })
  hash % bucket_count
}

/// The hue, in degrees from 0 to 359, of a colour bucket. Buckets are
/// spaced by multiples of the golden ratio, which spreads consecutive
/// buckets around the colour wheel the way pprof's flame graph does.
///
/// ## Examples
///
/// ```gleam
/// flame.hue(1)
/// // -> 222
/// ```
pub fn hue(bucket: Int) -> Int {
  bucket * 618_033_988 % 1_000_000_000 * 360 / 1_000_000_000
}
