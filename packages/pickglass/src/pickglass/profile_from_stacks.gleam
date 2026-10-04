//// Aggregated stacks from a stack-sampling probe as a core profile.
////
//// A sampling probe reads a process's current stack many times and the
//// agent counts identical stacks, so what comes back is a table: each
//// distinct stack with how many times it was seen, plus how it was taken.
//// This module turns that table into a core profile of source
//// `SampledStacks`, which is what the Flame, Icicle, Graph, Top, Peek and
//// Source views draw.
////
//// The input type is the viewer's own. The agent's wire reply is decoded
//// elsewhere into its own types, and mapping that reply onto `Aggregated`
//// is a few lines; keeping the input here means this module, and every
//// page built on it, can be tested with hand-made stacks.
////
//// Frames are listed innermost first, the order core's `Sample` uses, so
//// the first frame of a stack is the function that was running. A reply
//// that lists the outermost frame first is reversed by the mapping, not
//// here.
////
//// Each sample keeps the process status it was taken under as a label
//// (`profile/activity`), so a view can show the samples on a scheduler apart
//// from the ones waiting for a message.
////
//// Two properties are held by construction. Every stack's count is
//// positive, so the profile's total equals the sum of the input counts and
//// a sample is never dropped silently; a count below one is refused with
//// its position, because dropping it would make the total disagree with the
//// number of samples taken. And a function is one function however many
//// stacks it appears in: frames are interned by module, name and arity, and
//// the first line information seen for a function is kept.
////
//// A process that reports no stack at all (one that is hibernating, which
//// discards its stack, or one that is exiting) is a real sample, not a
//// malformed one. Refusing it would fail a whole probe because one target
//// slept, which is what happened to every loom session owner, so such a
//// stack is drawn as one frame, `no_stack`, and the notes say how many
//// samples it holds.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pickglass_core/profile.{type Profile}
import pickglass_core/profile/activity
import pickglass_core/unit

/// One frame of a sampled stack.
pub type Frame {
  Frame(
    module: String,
    function: String,
    arity: Int,
    /// The source file, when the stack carried one.
    file: Option(String),
    /// The line, when the stack carried one.
    line: Option(Int),
  )
}

/// One distinct stack and how many samples had exactly it. The agent counts a
/// stack once for each process status it was seen under, so a stack that a
/// process held both while running and while waiting arrives as two.
pub type Stack {
  Stack(
    /// The frames, innermost first.
    frames: List(Frame),
    count: Int,
    /// The process status the samples were taken under, as the agent
    /// reported it (`running`, `runnable`, `waiting`, ...). `None` for a
    /// stack that carries none.
    status: Option(String),
  )
}

/// Whether the agent kept every stack it saw.
pub type Completeness {
  /// Every sampled stack is in the table.
  AllStacks

  /// The table is capped. `dropped_samples` samples were taken and not
  /// counted into any stack.
  CutShort(dropped_samples: Int)
}

/// What a sampling probe returned.
pub type Aggregated {
  Aggregated(
    /// How the stacks were taken, as the agent names the method.
    method: String,
    /// The sampling rate the probe achieved, in samples per second.
    rate_hz: Int,
    /// The deepest stack the probe records; deeper stacks are cut at the
    /// outer end.
    depth_limit: Int,
    completeness: Completeness,
    stacks: List(Stack),
  )
}

/// The frame a stack with no frames is drawn as. The name says what the
/// process reported, not a function it was running.
pub const no_stack_frame =
  Frame(
    module: "(no stack)",
    function: "hibernating_or_exiting",
    arity: 0,
    file: None,
    line: None,
  )

/// Why a table could not become a profile.
pub type Refusal {
  /// A stack's count is below one; its position is from zero.
  NonPositiveCount(position: Int, count: Int)

  /// Core refused the profile.
  ProfileRefused(profile.BuildError)
}

/// The profile of a sampling probe's aggregated stacks. Its one value type
/// is the number of samples, and the sum of that column equals the sum of
/// the input counts.
///
/// ## Examples
///
/// ```gleam
/// profile_from_stacks.build(Aggregated(
///   method: "process_info current_stacktrace",
///   rate_hz: 50,
///   depth_limit: 16,
///   completeness: AllStacks,
///   stacks: [Stack([Frame("lists", "map", 2, None, None)], 3, Some("running")],
/// ))
/// ```
pub fn build(input: Aggregated) -> Result(Profile, Refusal) {
  use _ <- result.try(check(input.stacks, 0))

  let stacks = list.map(input.stacks, with_a_frame)
  let interned = intern(stacks)

  profile.new(
    profile.SampledStacks(method: input.method, rate: input.rate_hz),
    [profile.ValueType(name: "samples", unit: unit.Count)],
    interned.functions,
    list.map(stacks, fn(stack) {
      profile.Sample(
        frames: list.map(stack.frames, fn(frame) { id_of(interned.ids, frame) }),
        values: [stack.count],
        labels: case stack.status {
          Some(status) -> [activity.status_label(status)]
          None -> []
        },
      )
    }),
  )
  |> result.map_error(ProfileRefused)
}

fn check(stacks: List(Stack), position: Int) -> Result(Nil, Refusal) {
  case stacks {
    [] -> Ok(Nil)
    [stack, ..rest] ->
      case stack.count >= 1 {
        False -> Error(NonPositiveCount(position:, count: stack.count))
        True -> check(rest, position + 1)
      }
  }
}

// A stack with no frames is drawn as the one `no_stack_frame`, so core's
// rule that a sample has a frame holds without refusing the probe.
fn with_a_frame(stack: Stack) -> Stack {
  case stack.frames {
    [] -> Stack(..stack, frames: [no_stack_frame])
    [_, ..] -> stack
  }
}

type Interned {
  Interned(
    ids: Dict(#(String, String, Int), Int),
    functions: List(profile.Function),
  )
}

// A function is identified by module, name and arity. The first frame that
// names it supplies its file and line, because the same function can be
// reported with different lines in different stacks and the profile keeps
// one.
fn intern(stacks: List(Stack)) -> Interned {
  let frames = list.flat_map(stacks, fn(stack) { stack.frames })

  let state =
    list.fold(
      frames,
      Interned(ids: dict.new(), functions: []),
      fn(state, frame) {
        let key = key_of(frame)

        case dict.has_key(state.ids, key) {
          True -> state
          False -> {
            let id = dict.size(state.ids)

            Interned(ids: dict.insert(state.ids, key, id), functions: [
              function_of(id, frame),
              ..state.functions
            ])
          }
        }
      },
    )

  Interned(..state, functions: list.reverse(state.functions))
}

fn key_of(frame: Frame) -> #(String, String, Int) {
  #(frame.module, frame.function, frame.arity)
}

// Every frame was interned before the samples were built, so the lookup
// cannot miss; a miss would be refused by core as an unknown function.
fn id_of(ids: Dict(#(String, String, Int), Int), frame: Frame) -> Int {
  result.unwrap(dict.get(ids, key_of(frame)), -1)
}

fn function_of(id: Int, frame: Frame) -> profile.Function {
  profile.Function(
    id:,
    module: frame.module,
    name: frame.function,
    arity: frame.arity,
    file: frame.file,
    line: frame.line,
    precision: case frame.file, frame.line {
      Some(_), Some(_) -> profile.Exact
      Some(_), None -> profile.FunctionLevel
      None, _ -> profile.NoLine
    },
  )
}

/// The sentences a page shows about how the stacks were taken: what the
/// sampling can miss, the depth limit, and how many samples were left out.
///
/// ## Examples
///
/// ```gleam
/// profile_from_stacks.caveats(input)
/// // -> ["Width is a share of samples, not of time.", ...]
/// ```
pub fn caveats(input: Aggregated) -> List(String) {
  let base = [
    "Width is a share of samples, not of time.",
    "A process that is inside a long BIF or NIF is under-sampled.",
    "Stack depth is limited to "
      <> int.to_string(input.depth_limit)
      <> "; deeper stacks are cut at the outer end.",
  ]

  let cut = case input.completeness {
    AllStacks -> base
    CutShort(dropped_samples:) ->
      list.append(base, [
        int.to_string(dropped_samples)
        <> " samples were taken and are not in any stack.",
      ])
  }

  case list.filter(input.stacks, fn(stack) { stack.frames == [] }) {
    [] -> cut
    empty -> {
      let samples = list.fold(empty, 0, fn(sum, stack) { sum + stack.count })

      list.append(cut, [
        int.to_string(samples)
        <> " samples found a process with no stack, which is a hibernating or exiting process; they are drawn as "
        <> profile.function_name(function_of(0, no_stack_frame))
        <> ".",
      ])
    }
  }
}
