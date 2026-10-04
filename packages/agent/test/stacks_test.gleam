import gleam/int
import gleam/list
import pickglass_agent/internal/ffi_term.{type Term, coerce}
import pickglass_agent/stacks.{At, FileOnly, Frame, NoLocation}

type Tag {
  Running
  Waiting
  Lists
  Map
  Sort
  File
  Line
}

fn status(tag: Tag) -> ffi_term.Atom {
  coerce(tag)
}

fn frame(module: Tag, function: Tag, arity: Int) -> Term {
  coerce(
    #(module, function, arity, [
      coerce(#(File, ffi_term.charlist("src/x.gleam"))),
      coerce(#(Line, 12)),
    ]),
  )
}

fn bare_frame(module: Tag, function: Tag, arity: Int) -> Term {
  coerce(#(module, function, arity, []))
}

// Identical `{Status, Stack}` keys are counted together, and the snapshot
// lists the largest count first with frames as indices into one table.
pub fn identical_stacks_are_counted_together_test() {
  let hot = coerce([frame(Lists, Map, 2), frame(Lists, Sort, 1)])
  let cold = coerce([frame(Lists, Sort, 1)])
  let aggregate =
    stacks.new()
    |> stacks.record(status(Running), hot, 8)
    |> stacks.record(status(Waiting), cold, 8)
    |> stacks.record(status(Running), hot, 8)
    |> stacks.record(status(Running), hot, 8)
  let built = stacks.build(aggregate)

  assert aggregate.samples == 4
  assert aggregate.distinct == 2
  assert built.stacks
    == [stacks.Entry(3, "running", [0, 1]), stacks.Entry(1, "waiting", [1])]
  assert built.frames
    == [
      Frame("lists", "map", 2, At("src/x.gleam", 12)),
      Frame("lists", "sort", 1, At("src/x.gleam", 12)),
    ]
  assert built.truncated_samples == 0
}

// The same stack in a different status is a different key: the status split
// is what separates where a process runs from where it waits.
pub fn status_splits_a_stack_test() {
  let one = coerce([frame(Lists, Map, 2)])
  let aggregate =
    stacks.new()
    |> stacks.record(status(Running), one, 8)
    |> stacks.record(status(Waiting), one, 8)

  assert aggregate.distinct == 2
}

// A stack as deep as the node's limit may have been cut by it and is
// counted as such; a shallower one is not.
pub fn stacks_at_the_depth_limit_are_counted_test() {
  let two = coerce([frame(Lists, Map, 2), frame(Lists, Sort, 1)])
  let one = coerce([frame(Lists, Map, 2)])
  let aggregate =
    stacks.new()
    |> stacks.record(status(Running), two, 2)
    |> stacks.record(status(Running), one, 2)

  assert aggregate.at_depth_limit == 1
}

// A frame with no file, or only a file, is reported as exactly that, and a
// frame that is not a frame at all becomes an unknown one instead of
// failing the snapshot.
pub fn locations_are_never_invented_test() {
  let file_only =
    coerce(#(Lists, Map, 2, [#(File, ffi_term.charlist("lists.erl"))]))
  let odd: Term = coerce(7)
  let aggregate =
    stacks.new()
    |> stacks.record(
      status(Running),
      coerce([bare_frame(Lists, Map, 2), file_only, odd]),
      8,
    )
  let built = stacks.build(aggregate)

  assert built.frames
    == [
      Frame("lists", "map", 2, NoLocation),
      Frame("lists", "map", 2, FileOnly("lists.erl")),
      Frame("unknown", "unknown", 0, NoLocation),
    ]
}

// The map holds at most `max_stacks` distinct stacks. A sample of a new stack
// past that is dropped and counted, and a stack already held keeps counting.
pub fn the_stack_table_is_bounded_test() {
  let stack_of = fn(n: Int) -> Term { coerce([coerce(#(n, n, n, []))]) }
  let full = fill(stack_of)
  let over = stacks.record(full, status(Running), stack_of(0), 8)
  let again = stacks.record(over, status(Running), stack_of(1), 8)

  assert full.distinct == stacks.max_stacks
  assert over.dropped == 1
  assert over.distinct == stacks.max_stacks
  assert over.samples == stacks.max_stacks + 1
  assert again.dropped == 1
  assert again.samples == stacks.max_stacks + 2
}

// The frame table is bounded too. Stacks left out of it are not lost
// silently: their samples are reported as truncated, and what remains plus
// what was truncated is every sample held.
pub fn the_frame_table_is_bounded_test() {
  let stack_of = fn(n: Int) -> Term {
    coerce([
      coerce(#(n, 1, 0, [])),
      coerce(#(n, 2, 0, [])),
      coerce(#(n, 3, 0, [])),
    ])
  }
  let aggregate = fill(stack_of)
  let built = stacks.build(aggregate)
  let kept = list.fold(built.stacks, 0, fn(sum, entry) { sum + entry.count })

  assert list.length(built.frames) <= stacks.max_frames
  assert built.truncated_samples > 0
  assert kept + built.truncated_samples == aggregate.samples - aggregate.dropped
}

// An aggregate holding `max_stacks` distinct stacks, numbered from one.
fn fill(stack_of: fn(Int) -> Term) -> stacks.Aggregate {
  int.range(
    from: 1,
    to: stacks.max_stacks + 1,
    with: stacks.new(),
    run: fn(aggregate, n) {
      stacks.record(aggregate, status(Running), stack_of(n), 8)
    },
  )
}

// A relative path is shown whole; an absolute path names the build host's
// directories and is cut to its last component.
pub fn absolute_paths_lose_their_directories_test() {
  assert stacks.without_directories(<<"src/weft/actor.gleam":utf8>>)
    == Ok("src/weft/actor.gleam")
  assert stacks.without_directories(<<"/home/build/pkg/x.erl":utf8>>)
    == Ok("x.erl")
  assert stacks.without_directories(<<"/x.erl":utf8>>) == Ok("x.erl")
  assert stacks.without_directories(<<"/home/build/":utf8>>) == Error(Nil)
  assert stacks.without_directories(<<"":utf8>>) == Error(Nil)
}
