//// The scheduling and garbage collection probe: when pinned processes ran,
//// when they collected, and which processes anywhere on the node had a slow
//// collection or timeslice.
////
//// The probe sets the `running` and `garbage_collection` trace flags on the
//// pinned processes, and the VM sends the probe's tracer an `in` and an
//// `out` for every scheduling and a start and an end for every collection,
//// each stamped with the monotonic clock. The tracer pairs them as they
//// arrive (`activity`) and keeps totals and the first slices, never the
//// stream. A process's time between `in` and `out` is its time on a
//// scheduler, the closest the BEAM has to a per-process CPU time.
////
//// Optionally the probe also asks the VM, through `trace:system/3`, for a
//// message when any process on the node has a collection or a timeslice
//// longer than a threshold. That is the one thing it reports about
//// unpinned processes, as counts and a bounded list of what the VM said, and
//// it exists only on OTP 28 and later: a request for it on an older release
//// is refused with `thresholds_unavailable` and nothing is armed.
////
//// ## Flow
////
//// `start` hands `tracer.launch` an arming function, `arm`. Arming sets the
//// thresholds first, through `arm_threshold`, and the process flags last,
//// through `trace_targets`, so no per-process event is sent before the
//// thresholds are in place. Each event the tracer receives goes through
//// `ingest`, and a read is written by `report`.

import pickglass_agent/activity.{type Activity}
import pickglass_agent/counters.{type Refusal, Refusal}
import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_events.{type Event}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/ffi_trace.{type Session}
import pickglass_agent/reply
import pickglass_agent/tracer.{type Ingest, type Launched}
import pickglass_agent/tracing

/// What the agent needs to run one events probe.
pub type Config {
  Config(
    /// The agent, which is told when the probe stops.
    agent: Pid,
    /// The probe's id.
    id: Int,
    /// The processes to trace, already resolved from pins and without
    /// repeats.
    targets: List(Pid),
    /// The window, in milliseconds.
    duration_ms: Int,
    /// The most scheduling and collection events folded before the tracer
    /// stops the stream.
    max_events: Int,
    /// The most slices kept for a timeline.
    slice_limit: Int,
    /// Report any collection longer than this many milliseconds, node-wide.
    /// Zero is off.
    long_gc_ms: Int,
    /// Report any timeslice longer than this many milliseconds, node-wide.
    /// Zero is off.
    long_schedule_ms: Int,
  )
}

const flags = [
  ffi_trace.Running,
  ffi_trace.GarbageCollection,
  ffi_trace.MonotonicTimestamp,
]

/// Start a probe: launch its tracer, create its session and arm it. On any
/// failure nothing is left behind.
///
/// ## Examples
///
/// ```gleam
/// start(Config(agent, 1, [pid], 2000, 100_000, 1000, 0, 0), 4_000_000)
/// // -> Ok(Launched(session, tracer, 0))
/// ```
pub fn start(config: Config, heap_words: Int) -> Result(Launched, Refusal) {
  tracer.launch(
    tracer.Config(
      agent: config.agent,
      id: config.id,
      targets: config.targets,
      duration_ms: config.duration_ms,
      max_events: config.max_events,
      queue_limit: tracing.queue_limit,
      flags: flags,
      body: activity.new(
        config.targets,
        config.slice_limit,
        ffi_proc.monotonic_time(ffi_proc.Native),
      ),
      ingest: fn(held, event) { ingest(config.agent, held, event) },
      close: activity.close_all,
      report: fn(found) { report(config, found) },
    ),
    ffi_trace.PickglassEvents,
    heap_words,
    fn(session) { arm(session, config) },
  )
}

// Scheduling and collection events count toward the budget. A threshold event
// does not, and one about the agent or the tracer is dropped: the probe's own
// cost is not what it is asked about.
fn ingest(agent: Pid, held: Activity, event: Event) -> Ingest(Activity) {
  case event {
    ffi_events.ScheduledIn(pid, at) ->
      tracer.Counted(activity.scheduled_in(held, pid, at))
    ffi_events.ScheduledOut(pid, at) ->
      tracer.Counted(activity.scheduled_out(held, pid, at))
    ffi_events.CollectionStarted(pid, kind, at) ->
      tracer.Counted(activity.collection_started(held, pid, kind, at))
    ffi_events.CollectionEnded(pid, kind, at) ->
      tracer.Counted(activity.collection_ended(held, pid, kind, at))
    ffi_events.LongCollection(pid, info) ->
      threshold(agent, pid, fn() { activity.long_collection(held, pid, info) })
    ffi_events.LongTimeslice(pid, info) ->
      threshold(agent, pid, fn() { activity.long_timeslice(held, pid, info) })
    ffi_events.Called(_, _, _, _)
    | ffi_events.ReturnedTo(_, _, _)
    | ffi_events.NotTrace -> tracer.Ignored
  }
}

fn threshold(agent: Pid, pid: Pid, fold: fn() -> Activity) -> Ingest(Activity) {
  case pid == agent || pid == ffi_proc.self() {
    True -> tracer.Ignored
    False -> tracer.Uncounted(fold())
  }
}

fn report(config: Config, found: tracer.Report(Activity)) -> Term {
  reply.events(
    found.id,
    found.phase,
    found.stop,
    found.meter,
    activity.build(found.body),
    config.long_gc_ms,
    config.long_schedule_ms,
  )
}

fn arm(session: Session, config: Config) -> Result(Int, Refusal) {
  use _ <- fallible.then(arm_threshold(
    session,
    ffi_trace.LongGc,
    config.long_gc_ms,
  ))
  use _ <- fallible.then(arm_threshold(
    session,
    ffi_trace.LongSchedule,
    config.long_schedule_ms,
  ))
  use _ <- fallible.then(trace_targets(session, config.targets))

  Ok(0)
}

fn arm_threshold(
  session: Session,
  threshold: ffi_trace.Threshold,
  milliseconds: Int,
) -> Result(Nil, Refusal) {
  case milliseconds {
    0 -> Ok(Nil)
    _ ->
      case ffi_trace.set_threshold(session, threshold, milliseconds) {
        Ok(Nil) -> Ok(Nil)
        Error(Nil) ->
          Error(Refusal(
            "thresholds_unavailable",
            "this node cannot set a node-wide slow collection or timeslice threshold",
          ))
      }
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
