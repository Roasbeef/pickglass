//// A call tree probe's result as a core profile.
////
//// A call tree probe traces `call` and `return_to` events in the pinned
//// processes and folds them in the agent into call paths: each path is the
//// chain of functions a call was made through (leaf first, as core's samples
//// are) with the number of calls over it and the traced time they took. This
//// module turns those paths into a core profile of source `TracedCalls`,
//// which is what the Flame, Icicle, Graph, Top and Peek views draw.
////
//// A path becomes one sample with three values, in this order: the number of
//// calls, the inclusive time in nanoseconds (the function and everything it
//// called), and the exclusive time (the function alone, which is the
//// inclusive time less what its callees took). The views are drawn from the
//// exclusive column. A flame box is as wide as the sum of the values of the
//// samples beneath it, and only a value that excludes the callees sums to
//// the right width; the Top table's own and cumulative columns then come out
//// as the exclusive and the inclusive time of each function.
////
//// Time here is traced time. It includes any time a process was descheduled
//// while inside a traced function, it excludes everything outside the traced
//// functions, and time in a callee that was not traced is counted as the
//// caller's exclusive time. `caveats` says so beside the views.
////
//// A function is one function however many paths it appears in: frames are
//// interned by module, name and arity, as `profile_from_stacks` does. A path
//// that names a frame the table does not list, or has no frames, is refused
//// with its position rather than dropped, because dropping it would make the
//// profile's total disagree with the traced time the agent reported.
////
//// ## Flow
////
//// `value_types` names the three columns. `build` interns the frame table,
//// turns each path into a sample and asks core to validate the profile.
//// `caveats` writes what the probe's meter says about how far to trust it,
//// with `stop_text` for how the probe ended and `lost_text` for what its
//// collector lost.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None}
import gleam/result
import pickglass_core/profile.{type Profile}
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/fmt

/// The name of the call count column.
pub const calls_column = "calls"

/// The name of the inclusive time column.
pub const inclusive_column = "inclusive time"

/// The name of the exclusive time column, the one the views draw.
pub const exclusive_column = "exclusive time"

/// The three value types of a traced calls profile, in column order.
///
/// ## Examples
///
/// ```gleam
/// calltrace_profile.value_types()
/// // -> [ValueType("calls", Count), ValueType("inclusive time", Nanoseconds),
/// //     ValueType("exclusive time", Nanoseconds)]
/// ```
pub fn value_types() -> List(profile.ValueType) {
  [
    profile.ValueType(name: calls_column, unit: unit.Count),
    profile.ValueType(name: inclusive_column, unit: unit.Nanoseconds),
    profile.ValueType(name: exclusive_column, unit: unit.Nanoseconds),
  ]
}

/// Why a call tree could not become a profile.
pub type Refusal {
  /// A path has no frames; its position is from zero.
  EmptyPath(position: Int)

  /// A path names a frame index the table does not hold.
  UnknownFrame(position: Int, index: Int)

  /// Core refused the profile.
  ProfileRefused(profile.BuildError)
}

/// The profile of a call tree probe's paths.
///
/// ## Examples
///
/// ```gleam
/// calltrace_profile.build(snapshot)
/// // -> Ok(profile) with one sample per path
/// ```
pub fn build(snapshot: wire.CalltraceSnapshot) -> Result(Profile, Refusal) {
  let #(ids, functions) = intern(snapshot.frames)

  use samples <- result.try(samples_of(snapshot.paths, ids, 0, []))

  profile.new(profile.TracedCalls, value_types(), functions, samples)
  |> result.map_error(ProfileRefused)
}

// A function is identified by module, name and arity. `ids` maps a position
// in the agent's frame table to the id of the function it names, so two
// table entries that name one function share an id.
fn intern(
  frames: List(wire.StackFrame),
) -> #(Dict(Int, Int), List(profile.Function)) {
  let #(_, ids, functions) =
    list.index_fold(frames, #(dict.new(), dict.new(), []), fn(state, frame, at) {
      let #(by_name, ids, functions) = state
      let key = #(frame.module, frame.function, frame.arity)

      case dict.get(by_name, key) {
        Ok(id) -> #(by_name, dict.insert(ids, at, id), functions)
        Error(Nil) -> {
          let id = dict.size(by_name)

          #(dict.insert(by_name, key, id), dict.insert(ids, at, id), [
            profile.Function(
              id:,
              module: frame.module,
              name: frame.function,
              arity: frame.arity,
              file: None,
              line: None,
              precision: profile.NoLine,
            ),
            ..functions
          ])
        }
      }
    })

  #(ids, list.reverse(functions))
}

fn samples_of(
  paths: List(wire.CallPath),
  ids: Dict(Int, Int),
  position: Int,
  acc: List(profile.Sample),
) -> Result(List(profile.Sample), Refusal) {
  case paths {
    [] -> Ok(list.reverse(acc))
    [path, ..rest] -> {
      use frames <- result.try(case path.frames {
        [] -> Error(EmptyPath(position))
        indices ->
          list.try_map(indices, fn(index) {
            dict.get(ids, index)
            |> result.replace_error(UnknownFrame(position, index))
          })
      })

      samples_of(rest, ids, position + 1, [
        profile.Sample(
          frames:,
          values: [path.calls, path.inclusive_ns, path.exclusive_ns],
          labels: [],
        ),
        ..acc
      ])
    }
  }
}

/// The sentences a page shows about what a call tree measured: how the probe
/// ended and what it lost, and the two properties of the folding that a
/// reader of the tree must know.
///
/// ## Examples
///
/// ```gleam
/// calltrace_profile.caveats(snapshot)
/// // -> ["The probe ran to its 5.00 s window and folded 31,200 events.", ...]
/// ```
pub fn caveats(snapshot: wire.CalltraceSnapshot) -> List(String) {
  let meter = snapshot.meter
  let trace = meter.trace

  list.flatten([
    [stop_text(snapshot.stop, trace)],
    lost_text(trace),
    nonzero(
      meter.dropped_calls,
      " calls were on a path past the 5,000 path table and are not in the tree.",
    ),
    nonzero(
      meter.elided_calls,
      " calls were deeper than the recorded depth of "
        <> fmt.count(meter.depth_limit)
        <> "; their time stays in the deepest frame recorded.",
    ),
    nonzero(
      meter.forced_closes,
      " calls were still open when the probe stopped and were closed at the last event seen.",
    ),
    nonzero(meter.strays, " events could not be placed in the tree."),
    nonzero(trace.targets_gone, " traced processes exited while the probe ran."),
    [
      "Untraced time inside a traced function counts as exclusive: a callee that was not traced is charged to its caller.",
      "Recursion deeper than one level reads as two levels.",
      "Time is traced time: it includes time a process was descheduled while inside a traced function, and excludes everything outside them.",
    ],
  ])
}

fn nonzero(count: Int, rest: String) -> List(String) {
  case count {
    0 -> []
    _ -> [fmt.count(count) <> rest]
  }
}

/// How a call tree or an events probe ended, in a sentence that names the
/// limit it hit. The two kinds of probe share the stop reasons and the meter.
///
/// ## Examples
///
/// ```gleam
/// calltrace_profile.stop_text(wire.TraceBudget, meter)
/// // -> "The probe stopped at its budget of 100,000 events after 1.20 s; ..."
/// ```
pub fn stop_text(stop: wire.TraceStop, meter: wire.TraceMeter) -> String {
  let events = fmt.count(meter.events)

  case stop {
    wire.TraceDeadline | wire.TraceRunning ->
      "The probe ran to the end of its window and folded "
      <> events
      <> " events."
    wire.TraceBudget ->
      "The probe stopped at its budget of "
      <> fmt.count(meter.max_events)
      <> " events after "
      <> fmt.count(meter.elapsed_ms)
      <> " ms; what happened after that is not in the result."
    wire.TraceOverrun ->
      "The probe was stopped after "
      <> fmt.count(meter.elapsed_ms)
      <> " ms because the collector fell behind (its queue reached "
      <> fmt.count(meter.peak_queue)
      <> " of "
      <> fmt.count(meter.queue_limit)
      <> " messages); the result is partial."
    wire.TraceTargetsGone ->
      "Every traced process exited after "
      <> fmt.count(meter.elapsed_ms)
      <> " ms, and the probe ended with them."
    wire.TraceStopped ->
      "The probe was stopped after "
      <> fmt.count(meter.elapsed_ms)
      <> " ms, before the end of its window, and folded "
      <> events
      <> " events."
  }
}

/// What a stopped probe lost to the events still queued for its collector:
/// those that arrived after the stop and were discarded, and those that were
/// already queued at the stop. Nothing is said when there were none.
///
/// ## Examples
///
/// ```gleam
/// calltrace_profile.lost_text(meter)
/// // -> ["60,000 events arrived after the stop and were discarded; ..."]
/// ```
pub fn lost_text(meter: wire.TraceMeter) -> List(String) {
  case meter.dropped_events, meter.in_flight_at_stop {
    0, 0 -> []
    dropped, in_flight -> [
      fmt.count(dropped)
      <> " events arrived after the stop and were discarded unread; "
      <> fmt.count(in_flight)
      <> " were already queued when it stopped.",
    ]
  }
}
