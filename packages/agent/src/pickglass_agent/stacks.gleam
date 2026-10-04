//// The aggregate behind the stack sampling probe: identical stacks counted
//// in the agent, so that a sample costs one map update and the reply is the
//// number of distinct stacks and not the number of samples.
////
//// A sample is a process status and the stack `process_info(P,
//// current_stacktrace)` returned, leaf first. The aggregate keys a bounded
//// map by `{Status, Stack}` and counts. It holds at most `max_stacks`
//// distinct keys: a sample of a new stack past that is counted as dropped,
//// and a sample of a stack already held is always counted, so the cap limits
//// cardinality without moving counts that were already attributed.
////
//// A snapshot turns the map into a frame table and stacks as lists of frame
//// indices, largest count first. The table is built in count order and
//// stops adding stacks once it would pass `max_frames` entries, and the
//// samples of the stacks left out are reported as truncated. Frames carry
//// the module, function and arity the VM reports, and the file and line when
//// it reports them. A source file is the relative `src/...gleam` path the
//// compiler records, which is the only path pickglass shows. Some frames
//// carry an absolute path instead, such as the generated Erlang of a
//// dependency, and that path names the build host's directories, so only its
//// last component is kept. A missing location is `NoLocation`, never an empty
//// file or line zero.
////
//// Everything here is pure data work over terms the VM produced. The module
//// sends nothing and starts no process.

import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Atom, type Term}
import pickglass_agent/internal/seq

/// The most distinct `{Status, Stack}` keys one probe holds.
pub const max_stacks = 5000

/// The most frames one snapshot's table holds.
pub const max_frames = 10_000

/// The longest file path, in characters, a frame location may carry.
const max_file_chars = 255

/// Why sampling ended, or that it has not.
pub type Stop {
  /// Still sampling.
  Sampling

  /// The probe's duration passed.
  DeadlineReached

  /// The sample budget was spent.
  SampleBudget

  /// Every target exited.
  TargetsGone

  /// The viewer stopped the probe.
  Stopped
}

/// A map from `{Status, Stack}` to a count. Opaque to everything outside this
/// module's externals.
pub type StackMap

/// The counts the sampler accumulates.
pub type Aggregate {
  Aggregate(
    stacks: StackMap,
    distinct: Int,
    samples: Int,
    dropped: Int,
    at_depth_limit: Int,
  )
}

/// Where in source a frame is.
pub type Location {
  NoLocation
  FileOnly(file: String)
  At(file: String, line: Int)
}

/// One function frame.
pub type Frame {
  Frame(module: String, function: String, arity: Int, location: Location)
}

/// One distinct stack with the number of samples that saw it. `frames`
/// indexes the snapshot's frame table, leaf first.
pub type Entry {
  Entry(count: Int, status: String, frames: List(Int))
}

/// A snapshot: the frame table, the stacks over it, and how many samples of
/// held stacks the frame bound left out.
pub type Built {
  Built(frames: List(Frame), stacks: List(Entry), truncated_samples: Int)
}

@external(erlang, "maps", "new")
fn new_map() -> StackMap

@external(erlang, "maps", "get")
fn map_get(key: #(Atom, Term), map: StackMap, default: Int) -> Int

@external(erlang, "maps", "put")
fn map_put(key: #(Atom, Term), value: Int, map: StackMap) -> StackMap

@external(erlang, "maps", "to_list")
fn map_to_list(map: StackMap) -> List(#(#(Atom, Term), Int))

@external(erlang, "lists", "sort")
fn sort(items: List(#(Int, #(Atom, Term)))) -> List(#(Int, #(Atom, Term)))

/// An aggregate with nothing counted.
///
/// ## Examples
///
/// ```gleam
/// new().samples
/// // -> 0
/// ```
pub fn new() -> Aggregate {
  Aggregate(new_map(), 0, 0, 0, 0)
}

/// Count one sample. `depth_limit` is the node's backtrace depth: a stack as
/// long as the limit may have been cut by it, and is counted in
/// `at_depth_limit`. A sample of a new stack when the map is full is counted
/// in `dropped` and not stored.
///
/// ## Examples
///
/// ```gleam
/// record(new(), status, stack, 8).samples
/// // -> 1
/// ```
pub fn record(
  aggregate: Aggregate,
  status: Atom,
  stack: Term,
  depth_limit: Int,
) -> Aggregate {
  let key = #(status, stack)
  let held = map_get(key, aggregate.stacks, 0)
  let deep = case stack_depth(stack) >= depth_limit {
    True -> aggregate.at_depth_limit + 1
    False -> aggregate.at_depth_limit
  }
  let counted =
    Aggregate(..aggregate, samples: aggregate.samples + 1, at_depth_limit: deep)

  case held, aggregate.distinct >= max_stacks {
    0, True -> Aggregate(..counted, dropped: counted.dropped + 1)
    0, False ->
      Aggregate(
        ..counted,
        stacks: map_put(key, 1, counted.stacks),
        distinct: counted.distinct + 1,
      )
    _, _ -> Aggregate(..counted, stacks: map_put(key, held + 1, counted.stacks))
  }
}

fn stack_depth(stack: Term) -> Int {
  case ffi_term.is_list(stack) {
    True -> seq.length(ffi_term.coerce(stack))
    False -> 0
  }
}

type FrameTable {
  FrameTable(index: StackMap, frames: List(Term), size: Int)
}

/// Turn an aggregate into a frame table and stacks, largest count first.
///
/// ## Examples
///
/// ```gleam
/// build(record(new(), status, stack, 8))
/// // -> Built(frames: [...], stacks: [Entry(1, "running", [0, 1])], truncated_samples: 0)
/// ```
pub fn build(aggregate: Aggregate) -> Built {
  let keyed =
    seq.map(map_to_list(aggregate.stacks), fn(entry) { #(entry.1, entry.0) })
  let ordered = seq.reverse(sort(keyed))
  let #(table, entries, truncated) =
    seq.fold(ordered, #(FrameTable(new_map(), [], 0), [], 0), fn(acc, item) {
      let #(table, entries, truncated) = acc
      let #(count, #(status, stack)) = item

      case intern_stack(table, stack) {
        Error(Nil) -> #(table, entries, truncated + count)
        Ok(#(next, indices)) -> #(
          next,
          [Entry(count, ffi_term.atom_name(status), indices), ..entries],
          truncated,
        )
      }
    })

  Built(
    frames: seq.map(seq.reverse(table.frames), frame_of),
    stacks: seq.reverse(entries),
    truncated_samples: truncated,
  )
}

@external(erlang, "maps", "get")
fn index_get(key: Term, map: StackMap, default: Int) -> Int

@external(erlang, "maps", "put")
fn index_put(key: Term, value: Int, map: StackMap) -> StackMap

// Interns every frame of a stack. A stack that would take the table past
// `max_frames` is refused whole and the table is left as it was, so a stack
// is either fully described or absent.
fn intern_stack(
  table: FrameTable,
  stack: Term,
) -> Result(#(FrameTable, List(Int)), Nil) {
  case ffi_term.is_list(stack) {
    False -> Ok(#(table, []))
    True -> {
      let frames: List(Term) = ffi_term.coerce(stack)
      let #(next, indices) =
        seq.fold(frames, #(table, []), fn(acc, frame) {
          let #(table, indices) = acc
          let #(grown, index) = intern(table, frame)

          #(grown, [index, ..indices])
        })

      case next.size > max_frames {
        True -> Error(Nil)
        False -> Ok(#(next, seq.reverse(indices)))
      }
    }
  }
}

// The index of a frame, adding it when it is new. Past the bound the table
// still grows for the length of one stack, which the caller discards whole.
fn intern(table: FrameTable, frame: Term) -> #(FrameTable, Int) {
  case index_get(frame, table.index, -1) {
    -1 -> #(
      FrameTable(
        index: index_put(frame, table.size, table.index),
        frames: [frame, ..table.frames],
        size: table.size + 1,
      ),
      table.size,
    )
    found -> #(table, found)
  }
}

// A frame is `{Module, Function, Arity, Location}`, where `Location` is a
// property list with `file` and `line`. Anything else renders as an unknown
// frame instead of raising: the shape is the VM's, but the table must never
// fail the whole snapshot over one entry.
fn frame_of(frame: Term) -> Frame {
  case
    ffi_term.is_tuple(frame)
    && ffi_term.tuple_size(frame) == 4
    && ffi_term.is_atom(ffi_term.element(1, frame))
    && ffi_term.is_atom(ffi_term.element(2, frame))
    && ffi_term.is_integer(ffi_term.element(3, frame))
  {
    False -> Frame("unknown", "unknown", 0, NoLocation)
    True ->
      Frame(
        module: ffi_term.atom_name(ffi_term.coerce(ffi_term.element(1, frame))),
        function: ffi_term.atom_name(
          ffi_term.coerce(ffi_term.element(2, frame)),
        ),
        arity: ffi_term.coerce(ffi_term.element(3, frame)),
        location: location_of(ffi_term.element(4, frame)),
      )
  }
}

@external(erlang, "lists", "keyfind")
fn keyfind(key: Atom, position: Int, list: Term) -> Term

fn location_of(properties: Term) -> Location {
  case ffi_term.is_list(properties) {
    False -> NoLocation
    True ->
      case
        value_of(keyfind(ffi_term.atom("file"), 1, properties)),
        value_of(keyfind(ffi_term.atom("line"), 1, properties))
      {
        Ok(file), Ok(line) ->
          case ffi_term.is_integer(line), file_text(file) {
            True, Ok(text) -> At(text, ffi_term.coerce(line))
            False, Ok(text) -> FileOnly(text)
            _, Error(Nil) -> NoLocation
          }
        Ok(file), Error(Nil) ->
          case file_text(file) {
            Ok(text) -> FileOnly(text)
            Error(Nil) -> NoLocation
          }
        Error(Nil), _ -> NoLocation
      }
  }
}

// The value of a `{Key, Value}` tuple that `keyfind` returned, or `Error`
// for `false`.
fn value_of(found: Term) -> Result(Term, Nil) {
  case ffi_term.is_tuple(found) && ffi_term.tuple_size(found) == 2 {
    True -> Ok(ffi_term.element(2, found))
    False -> Error(Nil)
  }
}

// A source file arrives as a charlist. It becomes a binary only when it is a
// proper list short enough to show, and only through the catching call,
// since a code point above 255 makes the conversion raise.
fn file_text(file: Term) -> Result(String, Nil) {
  case ffi_safe.proper_length(file) {
    Error(Nil) -> Error(Nil)
    Ok(length) ->
      case length < 1 || length > max_file_chars {
        True -> Error(Nil)
        False ->
          case ffi_safe.call(ffi_safe.Erlang, ffi_safe.ListToBinary, [file]) {
            Ok(text) -> without_directories(ffi_term.coerce(text))
            Error(Nil) -> Error(Nil)
          }
      }
  }
}

/// A source file as it may be shown. A relative path is kept whole. An
/// absolute path, which names the directories of the machine that built the
/// code, is cut to its last component. A path with nothing after its last
/// slash has no file name to show.
///
/// ## Examples
///
/// ```gleam
/// without_directories(<<"src/weft/actor.gleam">>)
/// // -> Ok(<<"src/weft/actor.gleam">>)
/// without_directories(<<"/home/build/pkg/x.erl">>)
/// // -> Ok(<<"x.erl">>)
/// ```
pub fn without_directories(path: BitArray) -> Result(String, Nil) {
  case path {
    <<"/", _:bytes>> -> last_component(path, path)
    _ -> text_of(path)
  }
}

// Walks the bytes and restarts at the byte after each slash, so what remains
// is the text after the last one.
fn last_component(rest: BitArray, kept: BitArray) -> Result(String, Nil) {
  case rest {
    <<>> -> text_of(kept)
    <<"/", after:bytes>> -> last_component(after, after)
    <<_, after:bytes>> -> last_component(after, kept)
    _ -> Error(Nil)
  }
}

// A non-empty path as the string it is. Both inputs are binaries from
// `list_to_binary`, so the cast is the identity.
fn text_of(path: BitArray) -> Result(String, Nil) {
  case path {
    <<>> -> Error(Nil)
    _ -> Ok(ffi_term.coerce(path))
  }
}

/// The wire name of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// stop_name(SampleBudget)
/// // -> "sample_budget"
/// ```
pub fn stop_name(stop: Stop) -> String {
  case stop {
    Sampling -> "running"
    DeadlineReached -> "deadline"
    SampleBudget -> "sample_budget"
    TargetsGone -> "targets_gone"
    Stopped -> "stopped"
  }
}
