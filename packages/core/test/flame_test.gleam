import fixtures
import gleam/dict
import gleam/int
import gleam/list
import gleam/set
import pickglass_core/analysis/diff
import pickglass_core/layout/flame.{Differential, Flame, Function, Icicle, Root}
import pickglass_core/profile.{type Profile}
import pickglass_core/unit

// Total 10: a(9) holds b(6) and c(3); d(1) stands alone.
fn small() -> Profile {
  fixtures.calls([#(["a", "b"], 6), #(["a", "c"], 3), #(["d"], 1)])
}

fn layout(p: Profile, config: flame.Config) -> flame.Layout {
  let assert Ok(l) = flame.layout(p, fixtures.column(p), config)
  l
}

fn config(width: Int, min_width: Int, max_boxes: Int) -> flame.Config {
  flame.Config(
    ..flame.default_config,
    width: width,
    min_width: min_width,
    max_boxes: max_boxes,
  )
}

fn name(p: Profile, box: flame.Box) -> String {
  case box.frame {
    Root -> "root"
    Function(id) -> profile.name_of(p, id)
  }
}

// Boxes as name, x, width, depth for a readable expectation.
fn shape(p: Profile, l: flame.Layout) -> List(#(String, Int, Int, Int)) {
  list.map(l.boxes, fn(b) { #(name(p, b), b.x, b.width, b.depth) })
}

pub fn widths_are_shares_of_the_total_test() {
  let p = small()
  let l = layout(p, config(100, 4, 100))
  assert l.total == 10
  assert shape(p, l)
    == [
      #("root", 0, 100, 0),
      #("m:a/0", 0, 90, 1),
      #("m:d/0", 90, 10, 1),
      #("m:b/0", 0, 60, 2),
      #("m:c/0", 60, 30, 2),
    ]
  assert l.omitted_boxes == 0
}

pub fn value_and_self_are_reported_test() {
  let p = small()
  let l = layout(p, config(100, 4, 100))
  let assert Ok(a) = list.find(l.boxes, fn(b) { name(p, b) == "m:a/0" })
  assert a.value == 9
  assert a.self == 0
  let assert Ok(d) = list.find(l.boxes, fn(b) { name(p, b) == "m:d/0" })
  assert d.value == 1
  assert d.self == 1
  assert d.delta == 0
}

// A box under the minimum is not drawn; its value goes to its parent.
pub fn narrow_boxes_fold_into_the_parent_test() {
  let p = small()
  let l = layout(p, config(100, 15, 100))
  assert list.map(l.boxes, fn(b) { name(p, b) })
    == ["root", "m:a/0", "m:b/0", "m:c/0"]
  let assert [root, ..] = l.boxes
  assert root.folded_value == 1
  assert root.folded_boxes == 1
  assert l.omitted_boxes == 1
}

pub fn folding_removes_subtrees_whole_test() {
  let p = small()
  let l = layout(p, config(100, 40, 100))
  assert list.map(l.boxes, fn(b) { name(p, b) }) == ["root", "m:a/0", "m:b/0"]
  let assert Ok(a) = list.find(l.boxes, fn(b) { name(p, b) == "m:a/0" })
  assert a.folded_value == 3
  assert a.folded_boxes == 1
  // Five tree nodes, three drawn.
  assert l.omitted_boxes == 2
}

// The box limit keeps the widest boxes and always a parent with its child.
pub fn the_box_limit_keeps_the_widest_test() {
  let p = small()
  let l = layout(p, config(100, 1, 3))
  assert list.map(l.boxes, fn(b) { name(p, b) }) == ["root", "m:a/0", "m:b/0"]
  let assert [root, a, _] = l.boxes
  assert root.folded_value == 1
  assert root.folded_boxes == 1
  assert a.folded_value == 3
  assert a.folded_boxes == 1
  assert l.omitted_boxes == 2

  // With two boxes both of a's children are folded into a.
  let two = layout(p, config(100, 1, 2))
  let assert [_, a] = two.boxes
  assert a.folded_value == 9
  assert a.folded_boxes == 2
}

pub fn the_box_limit_never_goes_below_one_test() {
  let l = layout(small(), config(100, 1, 0))
  assert list.length(l.boxes) == 1
}

pub fn flame_puts_the_root_at_the_bottom_test() {
  let p = small()
  let flame_rows = layout(p, config(100, 4, 100))
  let icicle_rows =
    layout(p, flame.Config(..config(100, 4, 100), orientation: Icicle))
  assert list.map(flame_rows.boxes, fn(b) { b.row }) == [2, 1, 1, 0, 0]
  assert list.map(icicle_rows.boxes, fn(b) { b.row }) == [0, 1, 1, 2, 2]
  assert flame_rows.rows == 3
  assert flame_rows.orientation == Flame
}

pub fn recursion_nests_in_the_tree_test() {
  let p = fixtures.calls([#(["a", "a", "a"], 4)])
  let l = layout(p, config(100, 4, 100))
  assert list.map(l.boxes, fn(b) { b.depth }) == [0, 1, 2, 3]
  assert list.all(l.boxes, fn(b) { b.width == 100 })
}

pub fn an_empty_profile_has_no_boxes_test() {
  let l = layout(fixtures.calls([]), config(100, 4, 100))
  assert l.boxes == []
  assert l.total == 0
}

pub fn counters_have_no_flame_graph_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCounters,
      [profile.ValueType("calls", unit.Count)],
      [],
      [],
    )
  let assert Ok(column) = profile.column(p, 0)
  assert flame.layout(p, column, flame.default_config)
    == Error(flame.NoCallStacks(profile.TracedCounters))
}

// ------------------------------------------------------------ properties

// The number of nodes of the call tree: every distinct root-first prefix of
// a stack, plus the root.
fn tree_size(p: Profile) -> Int {
  let prefixes =
    list.fold(profile.samples(p), set.new(), fn(seen, sample) {
      let frames = list.reverse(sample.frames)
      list.fold(fixtures.span(1, list.length(frames)), seen, fn(seen, n) {
        set.insert(seen, list.take(frames, n))
      })
    })
  set.size(prefixes) + 1
}

fn random_config(seed: Int) -> #(flame.Config, Int) {
  let #(width, seed) = fixtures.below(seed, 400)
  let #(min_width, seed) = fixtures.below(seed, 12)
  let #(max_boxes, seed) = fixtures.below(seed, 40)
  #(config(width + 50, min_width + 1, max_boxes + 1), seed)
}

fn check(
  seed: Int,
  runs: Int,
  property: fn(Profile, flame.Config, flame.Layout) -> Bool,
) -> Nil {
  case runs {
    0 -> Nil
    _ -> {
      let #(p, seed) = fixtures.random_calls(seed, 10, 25, 7)
      let #(cfg, seed) = random_config(seed)
      assert property(p, cfg, layout(p, cfg))
      check(seed, runs - 1, property)
    }
  }
}

pub fn the_box_count_is_bounded_test() {
  check(3, 100, fn(_, cfg, l) { list.length(l.boxes) <= cfg.max_boxes })
}

pub fn every_box_is_at_least_the_minimum_width_test() {
  check(5, 100, fn(_, cfg, l) {
    list.all(l.boxes, fn(b) { b.width >= cfg.min_width })
  })
}

// Drawn and omitted boxes account for every node of the call tree.
pub fn drawn_and_omitted_boxes_add_up_test() {
  check(9, 100, fn(p, _, l) {
    list.length(l.boxes) + l.omitted_boxes == tree_size(p)
  })
}

// Each box's folded boxes are exactly the omitted ones below it, so the
// per-box counts sum to the layout's.
pub fn folded_counts_sum_to_the_omitted_count_test() {
  check(15, 100, fn(_, _, l) {
    list.fold(l.boxes, 0, fn(sum, b) { sum + b.folded_boxes })
    == l.omitted_boxes
  })
}

// Children lie inside their parent and their widths never sum past it.
pub fn children_fit_inside_their_parent_test() {
  check(21, 100, fn(_, _, l) {
    let by_depth = list.group(l.boxes, fn(b) { b.depth })
    list.all(l.boxes, fn(parent) {
      let children =
        dict.get(by_depth, parent.depth + 1)
        |> result_or_empty
        |> list.filter(fn(child) {
          child.x >= parent.x
          && child.x + child.width <= parent.x + parent.width
        })
      let inside = list.fold(children, 0, fn(sum, c) { sum + c.width })
      inside <= parent.width
    })
  })
}

// Every non-root box is inside some box one level up: no orphans.
pub fn every_box_has_a_parent_test() {
  check(25, 100, fn(_, _, l) {
    let by_depth = list.group(l.boxes, fn(b) { b.depth })
    list.all(l.boxes, fn(child) {
      case child.depth {
        0 -> True
        d ->
          dict.get(by_depth, d - 1)
          |> result_or_empty
          |> list.any(fn(parent) {
            child.x >= parent.x
            && child.x + child.width <= parent.x + parent.width
          })
      }
    })
  })
}

pub fn boxes_in_a_row_do_not_overlap_test() {
  check(27, 100, fn(_, _, l) {
    let by_depth = list.group(l.boxes, fn(b) { b.depth })
    list.all(dict.values(by_depth), fn(row) {
      let sorted = list.sort(row, fn(a, b) { int.compare(a.x, b.x) })
      list.zip(sorted, list.drop(sorted, 1))
      |> list.all(fn(pair) { { pair.0 }.x + { pair.0 }.width <= { pair.1 }.x })
    })
  })
}

pub fn the_layout_is_deterministic_test() {
  check(31, 50, fn(p, cfg, l) { l == layout(p, cfg) })
}

fn result_or_empty(result: Result(List(a), Nil)) -> List(a) {
  case result {
    Ok(items) -> items
    Error(Nil) -> []
  }
}

// ------------------------------------------------------------------ colour

pub fn colour_buckets_are_stable_and_in_range_test() {
  assert flame.colour_bucket("loom") == flame.colour_bucket("loom")
  list.each(["loom", "weft", "lists", "gleam", "", "erlang"], fn(package) {
    let bucket = flame.colour_bucket(package)
    assert bucket >= 0 && bucket < 24
  })
}

pub fn the_same_package_shares_a_colour_test() {
  let p = fixtures.calls([#(["a"], 1)])
  let assert Ok(function) = profile.function(p, 0)
  assert flame.colour_bucket(profile.package_of(function.module))
    == flame.colour_bucket("m")
}

// Golden-ratio spacing: consecutive buckets are far apart on the wheel.
pub fn hues_are_spread_by_the_golden_ratio_test() {
  assert flame.hue(0) == 0
  assert flame.hue(1) == 222
  assert flame.hue(2) == 84
  let hues = list.map(fixtures.span(0, 23), flame.hue)
  assert list.length(list.unique(hues)) == 24
  assert list.all(hues, fn(h) { h >= 0 && h < 360 })
}

// -------------------------------------------------------------------- diff

fn merged(base: Profile, candidate: Profile, n: diff.Normalize) -> Profile {
  let assert Ok(p) = diff.merge(base, candidate, n)
  p
}

fn diff_layout(p: Profile) -> flame.Layout {
  layout(p, flame.Config(..config(100, 1, 100), mode: Differential))
}

pub fn identical_profiles_diff_to_nothing_test() {
  let p = small()
  let l = diff_layout(merged(p, p, diff.Unnormalized))
  assert l.total == 0
  assert l.boxes == []
  assert list.all(l.boxes, fn(b) { b.delta == 0 })
}

pub fn identical_random_profiles_have_zero_deltas_test() {
  diff_identical(41, 40)
}

fn diff_identical(seed: Int, runs: Int) -> Nil {
  case runs {
    0 -> Nil
    _ -> {
      let #(p, seed) = fixtures.random_calls(seed, 8, 15, 6)
      let l = diff_layout(merged(p, p, diff.Unnormalized))
      assert list.all(l.boxes, fn(b) { b.delta == 0 })
      assert l.total == 0
      diff_identical(seed, runs - 1)
    }
  }
}

// Growth is positive (a regression) and shrinkage negative, per stack.
pub fn differences_carry_their_sign_test() {
  let base = fixtures.calls([#(["a", "b"], 5), #(["a", "c"], 4)])
  let candidate = fixtures.calls([#(["a", "b"], 8), #(["a", "c"], 1)])
  let p = merged(base, candidate, diff.Unnormalized)
  let l = diff_layout(p)
  let delta_of = fn(wanted: String) {
    let assert Ok(box) = list.find(l.boxes, fn(b) { name(p, b) == wanted })
    box.delta
  }
  assert delta_of("m:b/0") == 3
  assert delta_of("m:c/0") == -3
  // Width counts both: 3 grew and 3 shrank.
  assert l.total == 6
  // The net through a is zero, though its width is not.
  assert delta_of("m:a/0") == 0
  let assert Ok(a) = list.find(l.boxes, fn(b) { name(p, b) == "m:a/0" })
  assert a.value == 6
}

pub fn a_new_function_appears_in_the_diff_test() {
  let base = fixtures.calls([#(["a"], 5)])
  let candidate = fixtures.calls([#(["a"], 5), #(["x"], 2)])
  let p = merged(base, candidate, diff.Unnormalized)
  let l = diff_layout(p)
  assert list.map(l.boxes, fn(b) { name(p, b) }) == ["root", "m:x/0"]
}

// Scaling the candidate to the base's total removes a pure change of
// length: a run twice as long has the same shape.
pub fn normalising_removes_a_uniform_scale_test() {
  let base = fixtures.calls([#(["a"], 10), #(["b"], 10)])
  let candidate = fixtures.calls([#(["a"], 20), #(["b"], 20)])
  let raw = diff_layout(merged(base, candidate, diff.Unnormalized))
  assert raw.total == 20
  let scaled = diff_layout(merged(base, candidate, diff.Normalized))
  assert scaled.total == 0
}

pub fn diff_percentages_are_relative_to_the_base_test() {
  let base = fixtures.calls([#(["a"], 10)])
  let candidate = fixtures.calls([#(["a"], 25)])
  let p = merged(base, candidate, diff.Unnormalized)
  assert profile.total(p, fixtures.column(p)) == 10
}

pub fn mismatched_value_types_are_refused_test() {
  let a = fixtures.calls([#(["a"], 1)])
  let assert Ok(b) =
    profile.new(
      profile.TracedCalls,
      [profile.ValueType("time", unit.Nanoseconds)],
      [],
      [],
    )
  let assert Error(diff.IncompatibleValueTypes(..)) =
    diff.merge(a, b, diff.Unnormalized)
}
