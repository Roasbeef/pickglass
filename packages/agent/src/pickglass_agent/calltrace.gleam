//// The call tree probe: a traced call tree of pinned processes, with
//// inclusive and exclusive time per call path.
////
//// The probe traces `call` and `return_to` for the functions its patterns
//// name, with local calls included, in the processes the viewer pinned and
//// no others. Each call also carries its caller, which is what lets a tail
//// call be told from a nested call. The VM sends the probe's tracer one
//// message per event, stamped with the monotonic clock, and the tracer folds
//// each into a tree of paths (`calltree`) instead of storing it, which is
//// what makes the probe's memory a function of its bounds and not of how hot
//// the traced code is. The reasons `return_to` was chosen over a return trace,
//// and how the caller rebuilds the stack, are in `calltree`.
////
//// What the probe can claim is narrow and stated here so no view claims
//// more. It reports call paths among the traced functions of the traced
//// processes, with the time between each call and its return. It cannot
//// report time outside the traced functions. Time spent descheduled is
//// included, because the probe does not trace `running`. Directly recursive
//// calls more than one level deep read as two. The cost is a few hundred
//// nanoseconds per event before the tracer's own, so a hot function floods
//// the tracer, and the probe then stops with `overrun` rather than let its
//// mailbox grow.
////
//// A module reloaded during the window drops its function patterns from the
//// session silently, and the probe does not detect it: events from that module
//// simply stop.
////
//// ## Flow
////
//// `start` reduces and checks the patterns with the same rules a counters
//// probe uses, then hands `tracer.launch` an arming function, `arm`. Arming
//// sets the patterns first, through `arm_patterns`, and the process flags
//// last, through `trace_targets`, so no event is sent before every pattern
//// is in place. Each event the tracer receives goes through `ingest`, and a
//// read is written by `report`.

import pickglass_agent/calltree.{type Tree}
import pickglass_agent/counters.{type Pattern, type Refusal, Refusal}
import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_events.{type Event}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/ffi_trace.{type Session}
import pickglass_agent/reply
import pickglass_agent/tracer.{type Ingest, type Launched}
import pickglass_agent/tracing

/// What the agent needs to run one call tree probe.
pub type Config {
  Config(
    /// The agent, which is told when the probe stops.
    agent: Pid,
    /// The probe's id.
    id: Int,
    /// The processes to trace, already resolved from pins and without
    /// repeats.
    targets: List(Pid),
    /// The functions to trace.
    patterns: List(Pattern),
    /// The window, in milliseconds.
    duration_ms: Int,
    /// The most events folded before the tracer stops the stream.
    max_events: Int,
    /// The most raw call slices kept for a timeline.
    timeline_limit: Int,
  )
}

// The process flags of the probe. `arity` sends `{M, F, Arity}` and not a
// copy of the arguments, so an event's cost does not depend on its data.
const flags = [
  ffi_trace.Call,
  ffi_trace.ReturnTo,
  ffi_trace.Arity,
  ffi_trace.MonotonicTimestamp,
]

/// Start a probe: launch its tracer, create its session and arm it. On any
/// failure nothing is left behind.
///
/// ## Examples
///
/// ```gleam
/// start(Config(agent, 1, [pid], [Pattern(module, function)], 2000, 100_000, 500), 4_000_000)
/// // -> Ok(Launched(session, tracer, 3))
/// ```
pub fn start(config: Config, heap_words: Int) -> Result(Launched, Refusal) {
  let patterns = counters.distinct_patterns(config.patterns)

  use _ <- fallible.then(counters.check_patterns(patterns))

  tracer.launch(
    tracer.Config(
      agent: config.agent,
      id: config.id,
      targets: config.targets,
      duration_ms: config.duration_ms,
      max_events: config.max_events,
      queue_limit: tracing.queue_limit,
      flags: flags,
      body: calltree.new(
        config.targets,
        config.timeline_limit,
        ffi_proc.monotonic_time(ffi_proc.Native),
      ),
      ingest: ingest,
      close: calltree.close_all,
      report: report,
    ),
    ffi_trace.PickglassCalltrace,
    heap_words,
    fn(session) { arm(session, patterns, config.targets) },
  )
}

fn ingest(tree: Tree, event: Event) -> Ingest(Tree) {
  case event {
    ffi_events.Called(pid, function, caller, at) ->
      tracer.Counted(calltree.call(tree, pid, function, caller, at))
    ffi_events.ReturnedTo(pid, function, at) ->
      tracer.Counted(calltree.returned(tree, pid, function, at))
    ffi_events.ScheduledIn(_, _)
    | ffi_events.ScheduledOut(_, _)
    | ffi_events.CollectionStarted(_, _, _)
    | ffi_events.CollectionEnded(_, _, _)
    | ffi_events.LongCollection(_, _)
    | ffi_events.LongTimeslice(_, _)
    | ffi_events.NotTrace -> tracer.Ignored
  }
}

fn report(report: tracer.Report(Tree)) -> Term {
  reply.calltrace(
    report.id,
    report.phase,
    report.stop,
    report.meter,
    calltree.build(report.body),
  )
}

fn arm(
  session: Session,
  patterns: List(Pattern),
  targets: List(Pid),
) -> Result(Int, Refusal) {
  use matched <- fallible.then(arm_patterns(session, patterns, 0))

  case matched > counters.max_functions {
    True ->
      Error(Refusal(
        "too_many_functions",
        "the patterns match more functions than a probe may trace",
      ))
    False -> {
      use _ <- fallible.then(trace_targets(session, targets))

      Ok(matched)
    }
  }
}

// Each pattern is armed in turn. A pattern that matches nothing refuses the
// whole probe, so a misspelt name among several is loud and not a silently
// empty tree.
fn arm_patterns(
  session: Session,
  patterns: List(Pattern),
  matched: Int,
) -> Result(Int, Refusal) {
  case patterns {
    [] -> Ok(matched)
    [pattern, ..rest] -> {
      use count <- fallible.then(arm_pattern(session, pattern))

      arm_patterns(session, rest, matched + count)
    }
  }
}

fn arm_pattern(session: Session, pattern: Pattern) -> Result(Int, Refusal) {
  case
    ffi_trace.trace_call_messages(session, pattern.module, pattern.function)
  {
    Error(Nil) ->
      Error(Refusal("trace_failed", "the VM refused the function pattern"))
    Ok(0) ->
      Error(Refusal(
        "no_match",
        "the pattern "
          <> ffi_term.atom_name(pattern.module)
          <> ":"
          <> ffi_term.atom_name(pattern.function)
          <> " matches no loaded function",
      ))
    Ok(count) -> Ok(count)
  }
}

fn trace_targets(session: Session, targets: List(Pid)) -> Result(Nil, Refusal) {
  case targets {
    [] -> Ok(Nil)
    [pid, ..rest] ->
      case ffi_trace.set_process_flags(session, ffi_term.coerce(pid), flags) {
        Ok(_) -> trace_targets(session, rest)
        Error(Nil) ->
          Error(Refusal(
            "target_gone",
            "a target process exited before it could be traced",
          ))
      }
  }
}
