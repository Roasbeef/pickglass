import gleam/int
import gleam/list
import pickglass_agent/calltree.{type Tree}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term, coerce}
import pickglass_agent/stacks.{Frame, NoLocation}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

fn blocked() -> Pid {
  let #(pid, _) = ffi_proc.spawn_opt(fn() { sleep(60_000) }, [ffi_proc.Monitor])

  pid
}

fn mfa(function: String, arity: Int) -> Term {
  coerce(#(ffi_term.atom("pg_tree"), ffi_term.atom(function), arity))
}

// The caller of a call that has none, as the VM reports it.
fn nobody() -> Term {
  coerce(ffi_term.atom("undefined"))
}

fn ns(ticks: Int) -> Int {
  ffi_proc.convert_time(ticks, ffi_proc.Native, ffi_proc.Nanosecond)
}

fn start(targets: List(Pid)) -> Tree {
  calltree.new(targets, 100, 0)
}

fn built_after(tree: Tree) -> calltree.Built {
  calltree.build(calltree.close_all(tree))
}

fn path_of(
  built: calltree.Built,
  names: List(String),
) -> Result(calltree.Path, Nil) {
  list.find(built.paths, fn(path) {
    list.map(path.frames, fn(index) { frame_name(built, index) }) == names
  })
}

fn frame_name(built: calltree.Built, index: Int) -> String {
  case list.drop(built.frames, index) {
    [Frame(_, function, _, _), ..] -> function
    [] -> "?"
  }
}

// A callee's time is part of its caller's inclusive time and not of its
// exclusive time. Paths are named leaf first.
pub fn nested_calls_split_inclusive_and_exclusive_time_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> calltree.call(pid, mfa("outer", 0), mfa("framework", 3), 100)
    |> calltree.call(pid, mfa("inner", 0), mfa("outer", 0), 110)
    |> calltree.returned(pid, mfa("outer", 0), 130)
    |> calltree.returned(pid, mfa("framework", 3), 150)
    |> built_after

  assert path_of(built, ["inner", "outer"])
    == Ok(calltree.Path(1, ns(20), ns(20), [1, 0]))
  assert path_of(built, ["outer"]) == Ok(calltree.Path(1, ns(50), ns(30), [0]))
  assert built.forced_closes == 0
  assert built.strays == 0
}

// Paths come largest inclusive time first, and the frame table is in the
// order functions were first called, with no location.
pub fn paths_are_ordered_by_inclusive_time_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> calltree.call(pid, mfa("outer", 0), mfa("framework", 3), 0)
    |> calltree.call(pid, mfa("inner", 0), mfa("outer", 0), 10)
    |> calltree.returned(pid, mfa("outer", 0), 20)
    |> calltree.returned(pid, mfa("framework", 3), 100)
    |> built_after

  assert list.map(built.paths, fn(path) { path.inclusive_ns })
    == [ns(100), ns(10)]
  assert built.frames
    == [
      Frame("pg_tree", "outer", 0, NoLocation),
      Frame("pg_tree", "inner", 0, NoLocation),
    ]
}

// A call that returns to the same function as the frame on top is a tail call
// of that frame: the frame is replaced, not nested, and the chain returns
// once.
pub fn a_tail_call_replaces_its_caller_test() {
  let pid = blocked()
  let tree =
    start([pid])
    |> calltree.call(pid, mfa("first", 0), mfa("framework", 3), 0)
    |> calltree.call(pid, mfa("second", 0), mfa("framework", 3), 10)

  assert calltree.open_frames(tree) == 1

  let built =
    tree
    |> calltree.returned(pid, mfa("framework", 3), 30)
    |> built_after

  assert path_of(built, ["first"]) == Ok(calltree.Path(1, ns(10), ns(10), [0]))
  assert path_of(built, ["second"]) == Ok(calltree.Path(1, ns(20), ns(20), [1]))
  assert built.forced_closes == 0
}

// Functions that tail-call each other, as a state machine does, stay one
// frame deep however long the chain.
pub fn mutual_tail_calls_stay_one_frame_deep_test() {
  let pid = blocked()
  let tree =
    list.fold(upto(100), start([pid]), fn(held, round) {
      let name = case round % 2 {
        0 -> "ping"
        _ -> "pong"
      }

      calltree.call(held, pid, mfa(name, 0), mfa("framework", 3), round)
    })

  assert calltree.open_frames(tree) == 1
  assert list.length(calltree.build(calltree.close_all(tree)).paths) == 2
}

// A callback from an untraced function lands under the traced function that
// reached it, and its return ends that frame alone: the frames beneath are
// still running.
pub fn a_callback_from_untraced_code_ends_only_itself_test() {
  let pid = blocked()
  let tree =
    start([pid])
    |> calltree.call(pid, mfa("work", 1), mfa("framework", 3), 0)
    |> calltree.call(pid, mfa("helper", 1), mfa("work", 1), 10)
    |> calltree.call(pid, mfa("sort", 2), mfa("helper", 1), 20)
    |> calltree.call(pid, mfa("callback", 2), mfa("merge", 3), 30)
    |> calltree.returned(pid, mfa("merge", 3), 40)

  assert calltree.open_frames(tree) == 3

  let built =
    tree
    |> calltree.returned(pid, mfa("helper", 1), 60)
    |> calltree.returned(pid, mfa("work", 1), 70)
    |> calltree.returned(pid, mfa("framework", 3), 100)
    |> built_after

  assert path_of(built, ["callback", "sort", "helper", "work"])
    == Ok(calltree.Path(1, ns(10), ns(10), [3, 2, 1, 0]))
  assert path_of(built, ["sort", "helper", "work"])
    == Ok(calltree.Path(1, ns(40), ns(30), [2, 1, 0]))
  assert path_of(built, ["helper", "work"])
    == Ok(calltree.Path(1, ns(60), ns(20), [1, 0]))
  assert path_of(built, ["work"]) == Ok(calltree.Path(1, ns(100), ns(40), [0]))
  assert built.forced_closes == 0
}

// A return to a traced function that is deeper in the stack ends the frames
// above it as well, which is what a lost event would leave.
pub fn a_return_to_a_deeper_frame_ends_the_frames_above_it_test() {
  let pid = blocked()
  let tree =
    start([pid])
    |> calltree.call(pid, mfa("a", 0), mfa("framework", 3), 0)
    |> calltree.call(pid, mfa("b", 0), mfa("a", 0), 10)
    |> calltree.call(pid, mfa("c", 0), mfa("b", 0), 20)
    |> calltree.returned(pid, mfa("a", 0), 40)

  assert calltree.open_frames(tree) == 1
}

// A call with no known caller is folded into the frame on top when it is the
// same function, which is how a loop started by `spawn` reads, and a return
// to nothing ends the frame.
pub fn calls_without_a_caller_fold_into_the_same_function_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> calltree.call(pid, mfa("loop", 1), nobody(), 0)
    |> calltree.call(pid, mfa("loop", 1), nobody(), 10)
    |> calltree.call(pid, mfa("loop", 1), nobody(), 20)
    |> calltree.returned(pid, nobody(), 30)
    |> built_after

  assert built.paths == [calltree.Path(3, ns(30), ns(30), [0])]
  assert built.strays == 0
}

// A different function with no known caller is pushed, not folded.
pub fn a_different_function_without_a_caller_is_pushed_test() {
  let pid = blocked()
  let tree =
    start([pid])
    |> calltree.call(pid, mfa("a", 1), nobody(), 0)
    |> calltree.call(pid, mfa("b", 1), nobody(), 10)

  assert calltree.open_frames(tree) == 2
}

// Frames still open when the probe stops are closed at the latest timestamp
// seen and counted.
pub fn open_frames_are_closed_at_the_latest_timestamp_test() {
  let pid = blocked()
  let other = blocked()
  let tree =
    start([pid, other])
    |> calltree.call(pid, mfa("a", 0), mfa("framework", 3), 0)
    |> calltree.call(other, mfa("z", 0), mfa("framework", 3), 90)

  assert calltree.open_frames(tree) == 2

  let built = built_after(tree)

  assert path_of(built, ["a"]) == Ok(calltree.Path(1, ns(90), ns(90), [0]))
  assert path_of(built, ["z"]) == Ok(calltree.Path(1, ns(0), ns(0), [1]))
  assert built.forced_closes == 2
  assert calltree.open_frames(calltree.close_all(tree)) == 0
}

// Two processes keep separate stacks, and a slice names its process by its
// position in the request.
pub fn processes_have_separate_stacks_test() {
  let first = blocked()
  let second = blocked()
  let built =
    start([first, second])
    |> calltree.call(first, mfa("a", 0), mfa("framework", 3), 0)
    |> calltree.call(second, mfa("b", 0), mfa("framework", 3), 5)
    |> calltree.returned(first, mfa("framework", 3), 10)
    |> calltree.returned(second, mfa("framework", 3), 30)
    |> built_after

  assert path_of(built, ["a"]) == Ok(calltree.Path(1, ns(10), ns(10), [0]))
  assert path_of(built, ["b"]) == Ok(calltree.Path(1, ns(25), ns(25), [1]))
  assert built.timeline
    == [
      calltree.Moment(0, 0, ns(0), ns(10), 0),
      calltree.Moment(1, 1, ns(5), ns(25), 0),
    ]
}

// An event for a process that is not a target, or a call of something that is
// not an `{M, F, Arity}`, changes nothing but the stray count.
pub fn events_that_do_not_belong_are_strays_test() {
  let pid = blocked()
  let stranger = blocked()
  let built =
    start([pid])
    |> calltree.call(stranger, mfa("a", 0), nobody(), 0)
    |> calltree.call(pid, coerce(#(1, 2, 3)), nobody(), 0)
    |> calltree.call(pid, coerce(7), nobody(), 0)
    |> calltree.returned(stranger, mfa("a", 0), 0)
    |> built_after

  assert built.strays == 4
  assert built.paths == []
  assert built.frames == []
}

// The timeline keeps the first frames to close and no more.
pub fn the_timeline_is_bounded_test() {
  let pid = blocked()
  let tree = calltree.new([pid], 3, 0)
  let full =
    list.fold(upto(10), tree, fn(held, round) {
      held
      |> calltree.call(
        pid,
        mfa("f" <> int.to_string(round), 0),
        mfa("framework", 3),
        round * 10,
      )
      |> calltree.returned(pid, mfa("framework", 3), round * 10 + 5)
    })
  let built = built_after(full)

  assert list.length(built.timeline) == 3
  assert list.length(built.paths) == 10
}

// A stack deeper than `max_depth` is recorded to that depth. The calls beyond
// it are counted and their time stays in the deepest recorded frame.
pub fn depth_is_bounded_and_time_is_kept_test() {
  let pid = blocked()
  let total = calltree.max_depth + 6
  let tree =
    list.fold(upto(total), start([pid]), fn(held, depth) {
      calltree.call(
        held,
        pid,
        mfa("f" <> int.to_string(depth), 0),
        mfa("f" <> int.to_string(depth - 1), 0),
        depth,
      )
    })
  let built =
    calltree.returned(tree, pid, mfa("framework", 0), total + 100)
    |> built_after

  assert list.length(built.paths) == calltree.max_depth
  assert built.elided_calls == 6
  // Every frame is open when the probe ends, and the exclusive times of the
  // recorded ones sum to the whole time from the first call to the end.
  assert list.fold(built.paths, 0, fn(sum, path) { sum + path.exclusive_ns })
    == ns(total + 100 - 1)
}

// A call on a new path past the bound is counted, and a call on a path
// already held is still added to it.
pub fn the_path_table_is_bounded_test() {
  let pid = blocked()
  let tree =
    list.fold(upto(calltree.max_paths + 3), start([pid]), fn(held, n) {
      held
      |> calltree.call(
        pid,
        mfa("f" <> int.to_string(n), 0),
        mfa("framework", 3),
        n,
      )
      |> calltree.returned(pid, mfa("framework", 3), n)
    })
  let again =
    tree
    |> calltree.call(pid, mfa("f1", 0), mfa("framework", 3), 1)
    |> calltree.returned(pid, mfa("framework", 3), 2)
  let built = built_after(again)

  assert built.distinct_paths == calltree.max_paths
  assert list.length(built.paths) == calltree.max_paths
  assert built.dropped_calls == 3
  assert case path_of(built, ["f1"]) {
    Ok(calltree.Path(calls, _, _, _)) -> calls == 2
    Error(Nil) -> False
  }
}

// Every call event is accounted for exactly once, and the times are
// consistent, whatever order calls and returns arrive in and whether or not
// their callers agree with the stack. A small generator drives two processes
// over three functions.
pub fn random_streams_keep_their_invariants_test() {
  let first = blocked()
  let second = blocked()

  list.each(upto(40), fn(seed) {
    let #(tree, calls) = drive(first, second, seed, start([first, second]))
    let closed = calltree.close_all(tree)
    let built = calltree.build(closed)
    let held = list.fold(built.paths, 0, fn(sum, path) { sum + path.calls })

    assert calltree.open_frames(closed) == 0
    assert held + built.dropped_calls + built.elided_calls == calls
    assert list.all(built.paths, fn(path) {
      path.inclusive_ns >= path.exclusive_ns && path.exclusive_ns >= 0
    })
    assert list.all(built.paths, fn(path) {
      list.all(path.frames, fn(index) { index >= 0 && index < 3 })
    })
  })
}

// A deterministic stream of 200 events: a linear congruential step picks the
// process, whether it is a call or a return, the function and its caller,
// which is sometimes unknown.
fn drive(first: Pid, second: Pid, seed: Int, tree: Tree) -> #(Tree, Int) {
  list.fold(upto(200), #(tree, 0), fn(state, step) {
    let #(held, calls) = state
    let roll = { { seed * 7919 + step * 104_729 } * 31 + step } % 1000
    let pid = case roll % 2 {
      0 -> first
      _ -> second
    }
    let function = mfa("f" <> int.to_string(roll / 2 % 3), 0)
    let caller = case roll / 7 % 4 {
      0 -> nobody()
      other -> mfa("f" <> int.to_string(other - 1), 0)
    }

    case roll % 5 {
      0 -> #(calltree.returned(held, pid, function, step * 3), calls)
      _ -> #(calltree.call(held, pid, function, caller, step * 3), calls + 1)
    }
  })
}

// The numbers from one to `count`.
fn upto(count: Int) -> List(Int) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, index) { index + 1 })
}
