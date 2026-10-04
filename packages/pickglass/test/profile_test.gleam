//// The profiles built from probe results: counters and aggregated stacks.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass/counters_profile
import pickglass/profile_from_stacks.{Aggregated, Frame, Stack}
import pickglass_core/profile
import pickglass_core/unit
import pickglass_core/wire

fn snapshot(rows: List(wire.FunctionRow)) -> wire.CountersSnapshot {
  wire.CountersSnapshot(
    probe_id: 7,
    state: wire.ProbeFinished,
    matched_functions: 5,
    elapsed_ms: 30_000,
    functions: 5,
    with_calls: list.length(rows),
    invalidated: 0,
    rows:,
  )
}

pub fn counters_become_one_total_per_called_function_test() {
  let assert Ok(built) =
    counters_profile.build(
      snapshot([
        wire.FunctionRow("lists", "map", 2, 10, 5),
        wire.FunctionRow("lists", "foldl", 3, 0, 0),
        wire.FunctionRow("maps", "get", 2, 3, 9),
      ]),
    )
  let assert Ok(calls) =
    profile.column_named(built, counters_profile.calls_column)
  let assert Ok(time) =
    profile.column_named(built, counters_profile.time_column)

  assert profile.source(built) == profile.TracedCounters
  assert profile.shape(profile.source(built)) == profile.FunctionTotals

  // The uncalled function has no row, and time is in nanoseconds.
  assert list.length(profile.samples(built)) == 2
  assert profile.total(built, calls) == 13
  assert profile.total(built, time) == 14_000
  assert list.map(profile.value_types(built), fn(v) { v.unit })
    == [unit.Count, unit.Nanoseconds]
}

pub fn a_probe_that_saw_no_calls_is_an_empty_profile_not_an_error_test() {
  let assert Ok(built) = counters_profile.build(snapshot([]))

  assert profile.samples(built) == []
}

fn frame(name: String, line: option.Option(Int)) -> profile_from_stacks.Frame {
  Frame(
    module: "loom@runtime",
    function: name,
    arity: 1,
    file: case line {
      Some(_) -> Some("src/loom.gleam")
      None -> None
    },
    line:,
  )
}

fn input(
  stacks: List(profile_from_stacks.Stack),
) -> profile_from_stacks.Aggregated {
  Aggregated(
    method: "process_info current_stacktrace",
    rate_hz: 50,
    depth_limit: 16,
    completeness: profile_from_stacks.AllStacks,
    stacks:,
  )
}

pub fn the_profile_total_equals_the_sum_of_the_counts_test() {
  let stacks = [
    Stack(
      [frame("leaf", Some(10)), frame("mid", Some(20)), frame("root", None)],
      7,
      None,
    ),
    Stack([frame("leaf", Some(11)), frame("root", None)], 5, None),
    Stack([frame("other", None)], 1, None),
  ]
  let assert Ok(built) = profile_from_stacks.build(input(stacks))
  let assert Ok(samples) = profile.column_named(built, "samples")

  assert profile.total(built, samples) == 13
  assert profile.source(built)
    == profile.SampledStacks("process_info current_stacktrace", 50)
}

pub fn a_function_is_one_function_in_every_stack_test() {
  let stacks = [
    Stack([frame("leaf", Some(10)), frame("root", None)], 1, None),
    Stack([frame("leaf", Some(99)), frame("root", None)], 1, None),
  ]
  let assert Ok(built) = profile_from_stacks.build(input(stacks))

  // Two distinct functions, and the first line seen for `leaf` is kept.
  assert list.length(profile.functions(built)) == 2

  let assert Ok(leaf) =
    list.find(profile.functions(built), fn(function) { function.name == "leaf" })

  assert leaf.line == Some(10)
  assert leaf.precision == profile.Exact
}

pub fn line_precision_follows_what_the_frame_carried_test() {
  let stacks = [
    Stack(
      [
        Frame("m", "exact", 0, Some("f.gleam"), Some(3)),
        Frame("m", "file_only", 0, Some("f.gleam"), None),
        Frame("m", "bare", 0, None, None),
      ],
      1,
      None,
    ),
  ]
  let assert Ok(built) = profile_from_stacks.build(input(stacks))
  let precision = fn(name) {
    let assert Ok(function) =
      list.find(profile.functions(built), fn(f) { f.name == name })

    function.precision
  }

  assert precision("exact") == profile.Exact
  assert precision("file_only") == profile.FunctionLevel
  assert precision("bare") == profile.NoLine
}

pub fn frames_keep_their_order_innermost_first_test() {
  let stacks = [Stack([frame("leaf", None), frame("root", None)], 2, None)]
  let assert Ok(built) = profile_from_stacks.build(input(stacks))
  let assert [sample] = profile.samples(built)

  assert list.map(sample.frames, fn(id) { profile.name_of(built, id) })
    == ["loom@runtime:leaf/1", "loom@runtime:root/1"]
}

pub fn a_bad_count_is_refused_with_its_position_test() {
  assert profile_from_stacks.build(
      input([
        Stack([frame("a", None)], 1, None),
        Stack([frame("a", None)], 0, None),
      ]),
    )
    == Error(profile_from_stacks.NonPositiveCount(position: 1, count: 0))
}

// A hibernating process reports an empty stack. Loom's session processes
// hibernate, so refusing it failed every profile of a session owner.
pub fn a_stack_with_no_frames_is_drawn_as_one_no_stack_frame_test() {
  let stacks = [
    Stack([frame("a", None)], 2, Some("running")),
    Stack([], 3, Some("waiting")),
  ]
  let assert Ok(built) = profile_from_stacks.build(input(stacks))
  let assert [_, asleep] = profile.samples(built)

  assert list.map(asleep.frames, fn(id) { profile.name_of(built, id) })
    == ["(no stack):hibernating_or_exiting/0"]
  assert asleep.values == [3]
  assert list.any(profile_from_stacks.caveats(input(stacks)), fn(line) {
    string.contains(line, "3 samples found a process with no stack")
  })
}

pub fn no_stacks_at_all_is_an_empty_profile_test() {
  let assert Ok(built) = profile_from_stacks.build(input([]))

  assert profile.samples(built) == []
}

pub fn caveats_state_the_depth_limit_and_what_was_dropped_test() {
  let whole = profile_from_stacks.caveats(input([]))
  let cut =
    profile_from_stacks.caveats(
      Aggregated(..input([]), completeness: profile_from_stacks.CutShort(12)),
    )

  assert list.any(whole, fn(line) {
    line
    == "Stack depth is limited to 16; deeper stacks are cut at the outer end."
  })
  assert list.length(cut) == list.length(whole) + 1
  assert list.any(cut, fn(line) {
    line == "12 samples were taken and are not in any stack."
  })
}
