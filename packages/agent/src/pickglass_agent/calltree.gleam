//// The aggregate behind the call tree probe: call and return events folded
//// into a tree of paths as they arrive, so that the tracer keeps counts and
//// times and never the events.
////
//// ## What an event stream can say
////
//// The tracer sees two kinds of event for a traced process. `call` says a
//// traced function was entered, and `return_to` says control went back to a
//// function, traced or not. The probe asks for `return_to` and not for
//// `{return_trace}` because the second changes the program it measures: a
//// function with a return trace is no longer tail recursive, so a looping
//// process would grow its stack for as long as the probe runs, and every
//// return would copy its value into a message. `return_to` copies nothing and
//// leaves tail calls alone.
////
//// A bare `call` cannot tell a tail call from a nested call, and a bare
//// `return_to` cannot say how many frames it ends. The probe therefore adds
//// the caller to each `call` with the match specification action
//// `{message, {caller}}`. The caller is the function the call will return to,
//// which for a tail call is the caller of the whole chain and for a nested
//// call is the calling function. That one fact settles the stack.
////
//// ## How the stack is rebuilt
////
//// Each target has a stack of open frames, innermost first, and each frame
//// remembers the function it returns to. A `call` whose caller is known first
//// closes the frames on top that return to the same function, because a
//// frame that shares the new call's continuation tail-called it, and then
//// pushes the new frame. A callback from an untraced framework, a nested call
//// and a tail call each land correctly, and a state machine whose functions
//// tail-call each other stays one frame deep. A `return_to` ends the frame on
//// top, and also any frames above the function it names when that function is
//// on the stack, which only an event lost to a reload can leave there.
////
//// The caller is `undefined` when the VM cannot say, which is the bottom of
//// a process: a loop started by `spawn` has no continuation. For those calls
//// the stack is rebuilt as a less exact guess: a call to the function on
//// top of the stack, itself without a known return, is folded into that frame
//// and only counts, and any other call is pushed. Directly recursive calls
//// more than one level deep share a continuation with the level above, so
//// they read as two levels.
////
//// ## What is kept
////
//// Closing a frame adds one observation to its path, the list of functions
//// from the frame outward to the root, leaf first. A path keeps its call
//// count, its inclusive time (the frame's whole duration, descheduled time
//// included, since the probe does not trace `running`) and its exclusive time
//// (the inclusive time less what its children took). Exclusive times over all
//// paths sum to the traced time, which is what makes a flame graph of the
//// result honest. Depth is bounded at `max_depth`: a deeper call is counted
//// and its time stays in its nearest recorded ancestor. Distinct paths are
//// bounded at `max_paths`: a call on a new path past that is counted as
//// dropped. Frames still open when the probe stops are closed at the latest
//// timestamp seen, and the first `slice_limit` closed frames are kept as raw
//// slices for a timeline.
////
//// Times are kept as the native monotonic ticks the VM stamped and converted
//// to nanoseconds only in `build`, so no event pays for a conversion. This
//// module is pure over terms the VM produced and sends nothing.

import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/seq
import pickglass_agent/stacks.{Frame, NoLocation}

/// The most distinct paths one probe holds.
pub const max_paths = 5000

/// The deepest stack recorded, in frames.
pub const max_depth = 64

/// An opaque map. Keys and values are terms the module owns.
pub type Table

@external(erlang, "maps", "new")
fn new_table() -> Table

@external(erlang, "maps", "get")
fn get(key: Term, table: Table, default: Term) -> Term

@external(erlang, "maps", "put")
fn put(key: Term, value: Term, table: Table) -> Table

@external(erlang, "maps", "to_list")
fn entries(table: Table) -> List(#(Term, Term))

@external(erlang, "lists", "sort")
fn sort(
  items: List(#(Int, #(Int, Int, List(Int)))),
) -> List(#(Int, #(Int, Int, List(Int))))

/// Whether a frame is counted in the paths or was too deep to be.
pub type Recording {
  Counted
  Elided
}

/// What a frame will return to. A traced function's caller is known except at
/// the bottom of a process.
pub type Return {
  ReturnsTo(function: Term)
  ReturnsUnknown
}

/// One open frame on a process's stack. `path` is the frame's own path, leaf
/// first, which an elided frame shares with its nearest recorded ancestor.
/// `children` is the inclusive time of the recorded frames that have closed
/// directly beneath this one, and `calls` how many calls were folded into it.
/// `returns` is the function the frame's chain returns to.
pub type Open {
  Open(
    function: Int,
    path: List(Int),
    started: Int,
    children: Int,
    calls: Int,
    recording: Recording,
    returns: Return,
  )
}

/// One traced process: its position in the request's target list, which is
/// how a slice names it, and the frames it has open.
pub type Process {
  Process(pid: Pid, index: Int, stack: List(Open), depth: Int)
}

/// A closed frame, kept for a timeline. Times are native ticks; `start` is the
/// absolute timestamp.
pub type Slice {
  Slice(process: Int, function: Int, start: Int, duration: Int, depth: Int)
}

/// The accumulated tree.
pub type Tree {
  Tree(
    processes: List(Process),
    paths: Table,
    distinct: Int,
    functions: Table,
    table: List(Term),
    known: Int,
    epoch: Int,
    latest: Int,
    slices: List(Slice),
    slice_count: Int,
    slice_limit: Int,
    dropped_calls: Int,
    elided_calls: Int,
    forced_closes: Int,
    strays: Int,
  )
}

/// A path with its totals, in nanoseconds. `frames` indexes the snapshot's
/// frame table, leaf first.
pub type Path {
  Path(calls: Int, inclusive_ns: Int, exclusive_ns: Int, frames: List(Int))
}

/// A closed frame for a timeline. `start_ns` counts from the tracer's start.
pub type Moment {
  Moment(process: Int, frame: Int, start_ns: Int, duration_ns: Int, depth: Int)
}

/// A snapshot: the frame table, the paths over it largest inclusive time
/// first, and the timeline in the order frames closed, with the text of each
/// target's pid in request order and the counts that say what the paths leave
/// out. `forced_closes` is how many frames were still open when the probe
/// stopped, `dropped_calls` the calls on paths past the bound, `elided_calls`
/// the calls deeper than the recorded depth, and `strays` the events for
/// processes or functions the tree could not use.
pub type Built {
  Built(
    frames: List(stacks.Frame),
    paths: List(Path),
    timeline: List(Moment),
    processes: List(String),
    distinct_paths: Int,
    dropped_calls: Int,
    elided_calls: Int,
    forced_closes: Int,
    strays: Int,
  )
}

/// An empty tree over `targets`. `slice_limit` bounds the raw slices kept and
/// `epoch` is the native monotonic time slice starts are measured from.
///
/// ## Examples
///
/// ```gleam
/// new([pid], 100, monotonic_time(Native))
/// ```
pub fn new(targets: List(Pid), slice_limit: Int, epoch: Int) -> Tree {
  Tree(
    processes: processes_of(targets, 0),
    paths: new_table(),
    distinct: 0,
    functions: new_table(),
    table: [],
    known: 0,
    epoch: epoch,
    latest: epoch,
    slices: [],
    slice_count: 0,
    slice_limit: slice_limit,
    dropped_calls: 0,
    elided_calls: 0,
    forced_closes: 0,
    strays: 0,
  )
}

fn processes_of(targets: List(Pid), index: Int) -> List(Process) {
  case targets {
    [] -> []
    [pid, ..rest] -> [
      Process(pid, index, [], 0),
      ..processes_of(rest, index + 1)
    ]
  }
}

/// Fold a `call` event. `caller` is the function the call returns to, or
/// anything else, such as the atom `undefined`, when that is not known. An
/// event for a process that is not a target, or whose function is not
/// `{Module, Function, Arity}`, is counted as a stray and changes nothing
/// else.
///
/// ## Examples
///
/// ```gleam
/// call(new([pid], 0, 0), pid, mfa, caller, 10)
/// ```
pub fn call(
  tree: Tree,
  pid: Pid,
  function: Term,
  caller: Term,
  at: Int,
) -> Tree {
  case is_function(function), find_process(tree.processes, pid) {
    True, Ok(process) -> {
      let #(interned, id) = intern(note_time(tree, at), function)
      let #(entered, held, elided) =
        enter(interned, process, id, return_of(caller), at)

      store(Tree(..entered, elided_calls: entered.elided_calls + elided), held)
    }
    True, Error(Nil) -> stray(tree)
    False, _ -> stray(tree)
  }
}

/// Fold a `return_to` event: end the frame on top of the process's stack,
/// and any frames above `function` when it is on the stack. `function` is
/// where control went, and may be a function the probe did not trace or the
/// atom `undefined` for a process that has run out of frames.
///
/// ## Examples
///
/// ```gleam
/// returned(call(new([pid], 0, 0), pid, mfa, caller, 10), pid, caller, 20)
/// ```
pub fn returned(tree: Tree, pid: Pid, function: Term, at: Int) -> Tree {
  case find_process(tree.processes, pid) {
    Error(Nil) -> stray(tree)
    Ok(process) -> {
      let timed = note_time(tree, at)
      let #(ended, remaining) = end_top(timed, process, at)
      let #(unwound, finished) =
        unwind_to(ended, remaining, function_id(ended, function), at)

      store(unwound, finished)
    }
  }
}

/// Close every frame still open, at the latest timestamp seen. Called when
/// the probe stops, and on a copy when a running probe is read.
///
/// ## Examples
///
/// ```gleam
/// close_all(tree)
/// ```
pub fn close_all(tree: Tree) -> Tree {
  let forced = tree.forced_closes + open_frames(tree)
  let closed =
    seq.fold(
      tree.processes,
      Tree(..tree, forced_closes: forced, processes: []),
      fn(acc, process) {
        let #(next, finished) = unwind(acc, process, -1, acc.latest)

        Tree(..next, processes: [finished, ..next.processes])
      },
    )

  Tree(..closed, processes: seq.reverse(closed.processes))
}

/// How many frames are open across all targets.
///
/// ## Examples
///
/// ```gleam
/// open_frames(call(new([pid], 0, 0), pid, mfa, 10))
/// // -> 1
/// ```
pub fn open_frames(tree: Tree) -> Int {
  seq.fold(tree.processes, 0, fn(total, process) { total + process.depth })
}

fn stray(tree: Tree) -> Tree {
  Tree(..tree, strays: tree.strays + 1)
}

fn note_time(tree: Tree, at: Int) -> Tree {
  case at > tree.latest {
    True -> Tree(..tree, latest: at)
    False -> tree
  }
}

fn is_function(term: Term) -> Bool {
  ffi_term.is_tuple(term)
  && ffi_term.tuple_size(term) == 3
  && ffi_term.is_atom(ffi_term.element(1, term))
  && ffi_term.is_atom(ffi_term.element(2, term))
  && ffi_term.is_integer(ffi_term.element(3, term))
}

fn find_process(processes: List(Process), pid: Pid) -> Result(Process, Nil) {
  seq.find(processes, fn(process) { process.pid == pid })
}

// A process keeps its place in the list, so a slice's process index and the
// order of the targets in the reply stay the request's.
fn store(tree: Tree, process: Process) -> Tree {
  Tree(
    ..tree,
    processes: seq.map(tree.processes, fn(held) {
      case held.index == process.index {
        True -> process
        False -> held
      }
    }),
  )
}

// The id of a function in the frame table, adding it when it is new. Only
// `call` interns, so the table holds the functions that were traced.
fn intern(tree: Tree, function: Term) -> #(Tree, Int) {
  case function_id(tree, function) {
    -1 -> #(
      Tree(
        ..tree,
        functions: put(function, ffi_term.coerce(tree.known), tree.functions),
        table: [function, ..tree.table],
        known: tree.known + 1,
      ),
      tree.known,
    )
    id -> #(tree, id)
  }
}

fn function_id(tree: Tree, function: Term) -> Int {
  ffi_term.coerce(get(function, tree.functions, ffi_term.coerce(-1)))
}

fn return_of(caller: Term) -> Return {
  case is_function(caller) {
    True -> ReturnsTo(caller)
    False -> ReturnsUnknown
  }
}

// A call with a known caller ends the frames on top that return to the same
// function, which tail-called it, and then pushes its own. A call without one
// is folded into the frame on top when that is the same function and has no
// known return either, and pushed otherwise.
fn enter(
  tree: Tree,
  process: Process,
  id: Int,
  returns: Return,
  at: Int,
) -> #(Tree, Process, Int) {
  case returns, process.stack {
    ReturnsTo(_), _ -> {
      let #(replaced, trimmed) = end_tail_frames(tree, process, returns, at)
      let #(pushed, elided) = push(trimmed, id, returns, at)

      #(replaced, pushed, elided)
    }
    ReturnsUnknown, [top, ..rest]
      if top.function == id && top.returns == ReturnsUnknown
    -> #(
      tree,
      Process(..process, stack: [Open(..top, calls: top.calls + 1), ..rest]),
      folded_into(top),
    )
    ReturnsUnknown, _ -> {
      let #(pushed, elided) = push(process, id, returns, at)

      #(tree, pushed, elided)
    }
  }
}

fn end_tail_frames(
  tree: Tree,
  process: Process,
  returns: Return,
  at: Int,
) -> #(Tree, Process) {
  case process.stack {
    [top, ..] if top.returns == returns -> {
      let #(ended, trimmed) = end_top(tree, process, at)

      end_tail_frames(ended, trimmed, returns, at)
    }
    _ -> #(tree, process)
  }
}

// A call folded into an elided frame is an elided call, since the frame it
// joins is not in the paths.
fn folded_into(frame: Open) -> Int {
  case frame.recording {
    Counted -> 0
    Elided -> 1
  }
}

// The frame is recorded, or elided when the stack is already as deep as it is
// recorded.
fn push(
  process: Process,
  id: Int,
  returns: Return,
  at: Int,
) -> #(Process, Int) {
  let parent = case process.stack {
    [] -> []
    [top, ..] -> top.path
  }

  case process.depth >= max_depth {
    True -> #(
      Process(
        ..process,
        stack: [Open(id, parent, at, 0, 1, Elided, returns), ..process.stack],
        depth: process.depth + 1,
      ),
      1,
    )
    False -> #(
      Process(
        ..process,
        stack: [
          Open(id, [id, ..parent], at, 0, 1, Counted, returns),
          ..process.stack
        ],
        depth: process.depth + 1,
      ),
      0,
    )
  }
}

// Ends the frame on top.
fn end_top(tree: Tree, process: Process, at: Int) -> #(Tree, Process) {
  case process.stack {
    [] -> #(tree, process)
    [top, ..rest] -> {
      let depth = process.depth - 1
      let #(closed, parents) = close(tree, process.index, top, rest, depth, at)

      #(closed, Process(..process, stack: parents, depth: depth))
    }
  }
}

// Closes the frames above the nearest frame of `target`, when there is one.
// A target that is not on the stack, such as an untraced framework function,
// closes nothing: the frames beneath the one that returned are still running.
fn unwind_to(
  tree: Tree,
  process: Process,
  target: Int,
  at: Int,
) -> #(Tree, Process) {
  case seq.any(process.stack, fn(frame) { frame.function == target }) {
    True -> unwind(tree, process, target, at)
    False -> #(tree, process)
  }
}

// Closes frames from the top until `target` is on top. A target of -1 is no
// function, so every frame closes.
fn unwind(
  tree: Tree,
  process: Process,
  target: Int,
  at: Int,
) -> #(Tree, Process) {
  case process.stack {
    [] -> #(tree, process)
    [top, ..] if top.function == target -> #(tree, process)
    [top, ..rest] -> {
      let depth = process.depth - 1
      let #(closed, parents) = close(tree, process.index, top, rest, depth, at)

      unwind(
        closed,
        Process(..process, stack: parents, depth: depth),
        target,
        at,
      )
    }
  }
}

// One frame closes. A recorded frame adds its observation to its path and
// credits its inclusive time to the frame beneath it. An elided frame does
// neither, so its time stays in the nearest recorded ancestor's exclusive
// time.
fn close(
  tree: Tree,
  index: Int,
  frame: Open,
  parents: List(Open),
  depth: Int,
  at: Int,
) -> #(Tree, List(Open)) {
  let inclusive = non_negative(at - frame.started)

  case frame.recording {
    Elided -> #(tree, parents)
    Counted -> {
      let exclusive = non_negative(inclusive - frame.children)
      let sliced = keep_slice(tree, index, frame, depth, inclusive)

      #(
        add_observation(sliced, frame, inclusive, exclusive),
        credit(parents, inclusive),
      )
    }
  }
}

fn non_negative(value: Int) -> Int {
  case value < 0 {
    True -> 0
    False -> value
  }
}

fn credit(parents: List(Open), inclusive: Int) -> List(Open) {
  case parents {
    [] -> []
    [parent, ..rest] -> [
      Open(..parent, children: parent.children + inclusive),
      ..rest
    ]
  }
}

fn keep_slice(
  tree: Tree,
  index: Int,
  frame: Open,
  depth: Int,
  inclusive: Int,
) -> Tree {
  case tree.slice_count < tree.slice_limit {
    False -> tree
    True ->
      Tree(
        ..tree,
        slices: [
          Slice(index, frame.function, frame.started, inclusive, depth),
          ..tree.slices
        ],
        slice_count: tree.slice_count + 1,
      )
  }
}

// A path is new when the map has no entry for it, and every stored entry has
// at least one call, so a zero count is the absent default. A new path past
// the bound is not stored and its calls are counted as dropped.
fn add_observation(
  tree: Tree,
  frame: Open,
  inclusive: Int,
  exclusive: Int,
) -> Tree {
  let key: Term = ffi_term.coerce(frame.path)
  let held: #(Int, Int, Int) =
    ffi_term.coerce(get(key, tree.paths, ffi_term.coerce(#(0, 0, 0))))

  case held, tree.distinct >= max_paths {
    #(0, _, _), True ->
      Tree(..tree, dropped_calls: tree.dropped_calls + frame.calls)
    #(0, _, _), False ->
      Tree(
        ..tree,
        paths: put(
          key,
          ffi_term.coerce(#(frame.calls, inclusive, exclusive)),
          tree.paths,
        ),
        distinct: tree.distinct + 1,
      )
    #(calls, total, own), _ ->
      Tree(
        ..tree,
        paths: put(
          key,
          ffi_term.coerce(#(
            calls + frame.calls,
            total + inclusive,
            own + exclusive,
          )),
          tree.paths,
        ),
      )
  }
}

/// Turn a tree into a snapshot. Open frames are not closed here; the caller
/// closes a copy first, so that a read of a running probe leaves it running.
///
/// ## Examples
///
/// ```gleam
/// build(close_all(tree))
/// ```
pub fn build(tree: Tree) -> Built {
  let ordered =
    seq.reverse(
      sort(
        seq.map(entries(tree.paths), fn(entry) {
          let #(calls, inclusive, exclusive): #(Int, Int, Int) =
            ffi_term.coerce(entry.1)
          let key: List(Int) = ffi_term.coerce(entry.0)

          #(inclusive, #(calls, exclusive, key))
        }),
      ),
    )

  Built(
    frames: seq.map(seq.reverse(tree.table), frame_of),
    paths: seq.map(ordered, fn(item) {
      let #(inclusive, #(calls, exclusive, key)) = item

      Path(calls, nanoseconds(inclusive), nanoseconds(exclusive), key)
    }),
    timeline: seq.map(seq.reverse(tree.slices), fn(slice) {
      Moment(
        slice.process,
        slice.function,
        nanoseconds(non_negative(slice.start - tree.epoch)),
        nanoseconds(slice.duration),
        slice.depth,
      )
    }),
    processes: seq.map(tree.processes, fn(process) {
      ffi_term.pid_text(process.pid)
    }),
    distinct_paths: tree.distinct,
    dropped_calls: tree.dropped_calls,
    elided_calls: tree.elided_calls,
    forced_closes: tree.forced_closes,
    strays: tree.strays,
  )
}

fn nanoseconds(ticks: Int) -> Int {
  ffi_proc.convert_time(ticks, ffi_proc.Native, ffi_proc.Nanosecond)
}

// The table holds `{Module, Function, Arity}` terms that `is_function`
// accepted, so the casts are safe.
fn frame_of(function: Term) -> stacks.Frame {
  Frame(
    module: ffi_term.atom_name(ffi_term.coerce(ffi_term.element(1, function))),
    function: ffi_term.atom_name(ffi_term.coerce(ffi_term.element(2, function))),
    arity: ffi_term.coerce(ffi_term.element(3, function)),
    location: NoLocation,
  )
}
