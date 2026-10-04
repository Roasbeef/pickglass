//// Chart labels: the most specific part of a name that fits its box.

import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import lustre/element
import pickglass_core/layout/flame
import pickglass_core/profile
import pickglass_core/unit
import pickglass_web/chart/flame as flame_chart
import pickglass_web/chart/names
import pickglass_web/fixture/stacks
import pickglass_web/key

const long: String = "runtime@strand_runtime:drive_loop/2"

pub fn a_wide_box_shows_the_whole_name_test() {
  assert names.fit(long, 400, 7) == long
}

// The module prefix is shared by almost every function of a real trace, so
// when the whole name does not fit the label is the function and arity.
pub fn a_narrower_box_drops_the_module_test() {
  assert names.fit(long, 120, 7) == "drive_loop/2"
}

pub fn a_box_too_narrow_for_the_function_cuts_it_test() {
  assert names.fit(long, 70, 7) == "drive_l…"
}

pub fn a_box_with_no_room_has_no_label_test() {
  assert names.fit(long, 20, 7) == ""
}

pub fn a_name_without_a_module_is_cut_like_any_other_test() {
  assert names.fit("init", 400, 7) == "init"
  assert names.fit("a_long_function_name/3", 60, 7) == "a_long…"
}

pub fn a_gleam_closure_is_written_as_its_function_and_counter_test() {
  assert names.readable("-drive_loop/2-anonymous-0-/2") == "drive_loop/2 fun#0"

  assert names.readable("-handle/1-fun-3-/1") == "handle/1 fun#3"

  assert names.split("runtime@strand_runtime:-drive_loop/2-anonymous-0-/2")
    == names.Parts("runtime@strand_runtime", "drive_loop/2 fun#0")
}

// A name that only looks like a closure is left alone, because a guess at a
// compiler's naming would print a different name.
pub fn an_unrecognised_dashed_name_is_unchanged_test() {
  assert names.readable("-handle/2-lc$^0/1-0-") == "-handle/2-lc$^0/1-0-"
  assert names.readable("plain/1") == "plain/1"
}

pub fn the_closure_form_shows_in_a_label_but_the_full_name_is_not_lost_test() {
  let closure = "runtime@strand_runtime:-drive_loop/2-anonymous-0-/2"

  assert names.fit(closure, 300, 7)
    == "runtime@strand_runtime:drive_loop/2 fun#0"

  assert names.fit(closure, 140, 7) == "drive_loop/2 fun#0"
}

fn draw_named(
  layout: flame.Layout,
  facing: flame_chart.Facing,
  name_of: fn(Int) -> String,
) -> String {
  flame_chart.view(
    layout:,
    facing:,
    name_of:,
    unit: unit.Count,
    selected: None,
    search: "",
    verdict: flame_chart.Directed,
    on_select: fn(box) { key.to_string(box) },
  )
  |> element.to_string
}

// Every function in a real Loom trace begins with the same module. A box too
// narrow for the whole name must still read as its function, and its hover
// title must keep the whole name, in a flame and in an icicle.
pub fn flame_boxes_read_as_their_function_not_the_shared_module_test() {
  let assert Ok(p) = stacks.build(stacks.Base) as "the fixture profile builds"
  let assert Ok(column) = profile.column_named(p, "samples") as "samples"
  let assert Ok(layout) = flame.layout(p, column, flame.default_config)
    as "layout succeeds"

  let name_of = fn(id) {
    "runtime@strand_runtime:" <> profile.name_of(p, id) <> "/2"
  }

  list.each([flame_chart.RootBelow, flame_chart.RootAbove], fn(facing) {
    let html = draw_named(layout, facing, name_of)
    let labels = labels_of(html)

    assert labels != []
    assert !list.any(labels, fn(text) { string.starts_with(text, "runtime@…") })
    assert string.contains(html, "<title>runtime@strand_runtime:")
  })
}

// The text of each `box-label` element.
fn labels_of(html: String) -> List(String) {
  string.split(html, "<text ")
  |> list.drop(1)
  |> list.map(fn(rest) {
    case string.split_once(rest, ">"), string.split_once(rest, "</text>") {
      Ok(#(_, after)), Ok(_) ->
        case string.split_once(after, "</text>") {
          Ok(#(text, _)) -> text
          Error(Nil) -> ""
        }
      _, _ -> ""
    }
  })
}

pub fn the_label_never_exceeds_the_room_of_its_box_test() {
  list.each(list.repeat(Nil, 41) |> list.index_map(fn(_, i) { i }), fn(columns) {
    let width = 8 + columns * 7
    let label = names.fit(long, width, 7)

    assert string.length(label) <= int.max(columns, 0)
  })
}
