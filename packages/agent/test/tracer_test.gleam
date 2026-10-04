import pickglass_agent/internal/ffi_events
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{
  type Pid, type Reference, type Term, coerce,
}
import pickglass_agent/internal/ffi_trace
import pickglass_agent/tracer
import pickglass_agent/tracing

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

@external(erlang, "pg_test_ffi", "await")
fn await(reference: Reference, timeout_ms: Int) -> Term

@external(erlang, "pg_test_ffi", "await_notice")
fn await_notice(tag: ffi_term.Atom, id: Int, timeout_ms: Int) -> Term

@external(erlang, "sys", "suspend")
fn suspend(pid: Pid) -> a

@external(erlang, "sys", "resume")
fn resume(pid: Pid) -> a

type Report =
  #(String, Int, String, String, Int, Int, Int, Int, Int)

fn blocked() -> Pid {
  let #(pid, _) = ffi_proc.spawn_opt(fn() { sleep(60_000) }, [ffi_proc.Monitor])

  pid
}

// A tracer whose aggregate is the number of call events it folded, and whose
// report is a flat tuple the tests read.
fn config(
  id: Int,
  agent: Pid,
  targets: List(Pid),
  duration_ms: Int,
  max_events: Int,
  queue_limit: Int,
) -> tracer.Config(Int) {
  tracer.Config(
    agent: agent,
    id: id,
    targets: targets,
    duration_ms: duration_ms,
    max_events: max_events,
    queue_limit: queue_limit,
    flags: [],
    body: 0,
    ingest: fn(count, event) {
      case event {
        ffi_events.Called(_, _, _, _) -> tracer.Counted(count + 1)
        ffi_events.ReturnedTo(_, _, _)
        | ffi_events.ScheduledIn(_, _)
        | ffi_events.ScheduledOut(_, _)
        | ffi_events.CollectionStarted(_, _, _)
        | ffi_events.CollectionEnded(_, _, _)
        | ffi_events.LongCollection(_, _)
        | ffi_events.LongTimeslice(_, _)
        | ffi_events.NotTrace -> tracer.Ignored
      }
    },
    close: fn(count) { count },
    report: fn(found) {
      coerce(#(
        "report",
        found.id,
        found.phase,
        tracing.stop_name(found.stop),
        found.body,
        found.meter.events,
        found.meter.dropped_events,
        found.meter.in_flight_at_stop,
        found.meter.targets_gone,
      ))
    },
  )
}

fn launch(config: tracer.Config(Int)) -> tracer.Launched {
  let assert Ok(launched) =
    tracer.launch(config, ffi_trace.PickglassCalltrace, 4_000_000, fn(_) {
      Ok(0)
    })
    as "a tracer launches"

  launched
}

fn call_event(count: Int) -> Term {
  coerce(#(
    ffi_term.atom("trace_ts"),
    ffi_proc.self(),
    ffi_term.atom("call"),
    #(ffi_term.atom("m"), ffi_term.atom("f"), 1),
    count,
  ))
}

fn send_calls(tracer: Pid, count: Int) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      ffi_proc.send(tracer, call_event(count))

      send_calls(tracer, count - 1)
    }
  }
}

fn report(tracer: Pid) -> Report {
  let reference = ffi_proc.make_ref()

  tracer.read(tracer, ffi_proc.self(), reference)

  coerce(await(reference, 3000))
}

fn finished(id: Int) -> Bool {
  await_notice(tracer.finished_tag(), id, 3000)
  == coerce(ffi_term.atom("found"))
}

// A running tracer folds the events it is sent and reports them without
// stopping.
pub fn a_tracer_folds_events_and_reads_without_stopping_test() {
  let launched = launch(config(11, ffi_proc.self(), [], 60_000, 1000, 1000))

  send_calls(launched.tracer, 5)

  assert report(launched.tracer)
    == #("report", 11, "running", "running", 5, 5, 0, 0, 0)
  assert report(launched.tracer).4 == 5
}

// The budget is exact: the tracer stops at the event that spends it, destroys
// the session through its weak handle before telling the agent, and counts
// the events that arrive afterwards as dropped.
pub fn the_event_budget_is_exact_and_the_session_is_destroyed_test() {
  let launched = launch(config(12, ffi_proc.self(), [], 60_000, 10, 1000))

  send_calls(launched.tracer, 25)

  assert finished(12)
  // The strong handle's session is already gone, which only the tracer's
  // weak handle can have done.
  assert ffi_trace.session_destroy(launched.session) == False

  let #(_, _, phase, stop, folded, events, dropped, _, _) =
    report(launched.tracer)

  assert phase == "finished"
  assert stop == "event_budget"
  assert folded == 10
  assert events == 10
  assert dropped == 15
}

// A mailbox past its limit stops the probe with `overrun`. The tracer is
// suspended while 600 events queue, so the first look at the mailbox, after
// 64 events, finds 536 waiting.
pub fn a_flooded_mailbox_stops_the_probe_with_overrun_test() {
  let launched = launch(config(13, ffi_proc.self(), [], 60_000, 100_000, 100))

  suspend(launched.tracer)
  send_calls(launched.tracer, 600)
  resume(launched.tracer)

  assert finished(13)

  let #(_, _, _, stop, folded, _, dropped, in_flight, _) =
    report(launched.tracer)

  assert stop == "overrun"
  assert folded == 64
  assert in_flight == 536
  assert dropped == 536
}

pub fn the_window_ends_the_probe_test() {
  let launched = launch(config(14, ffi_proc.self(), [], 100, 1000, 1000))

  send_calls(launched.tracer, 3)

  assert finished(14)

  let #(_, _, phase, stop, folded, _, _, _, _) = report(launched.tracer)

  assert phase == "finished"
  assert stop == "deadline"
  assert folded == 3
  assert ffi_trace.session_destroy(launched.session) == False
}

// A probe keeps the reason it stopped for first, whatever ends the window
// after it.
pub fn the_first_stop_reason_is_kept_test() {
  let launched = launch(config(15, ffi_proc.self(), [], 150, 2, 1000))

  send_calls(launched.tracer, 2)

  assert finished(15)

  sleep(300)

  let #(_, _, _, stop, _, _, _, _, _) = report(launched.tracer)

  assert stop == "event_budget"
}

// A stop request halts a running probe, replies with its final result and
// ends the tracer.
pub fn a_stop_request_replies_and_ends_the_tracer_test() {
  let launched = launch(config(16, ffi_proc.self(), [], 60_000, 1000, 1000))
  let reference = ffi_proc.make_ref()

  send_calls(launched.tracer, 4)
  tracer.stop(launched.tracer, ffi_proc.self(), reference)

  let #(_, _, phase, stop, folded, _, _, _, _): Report =
    coerce(await(reference, 3000))

  assert phase == "stopped"
  assert stop == "stopped"
  assert folded == 4

  sleep(100)

  assert ffi_proc.is_alive(launched.tracer) == False
  assert ffi_trace.session_destroy(launched.session) == False
}

// The last target to exit ends the probe, not the tracer.
pub fn the_last_target_exiting_ends_the_probe_test() {
  let target = blocked()
  let launched =
    launch(config(17, ffi_proc.self(), [target], 60_000, 1000, 1000))

  let _ = ffi_proc.exit_with(target, ffi_proc.Kill)

  assert finished(17)

  let #(_, _, phase, stop, _, _, _, _, gone) = report(launched.tracer)

  assert phase == "finished"
  assert stop == "targets_gone"
  assert gone == 1
  assert ffi_proc.is_alive(launched.tracer)
}

// The agent's death ends the tracer, so a killed agent leaves none behind.
pub fn the_agent_exiting_ends_the_tracer_test() {
  let agent = blocked()
  let launched = launch(config(18, agent, [], 60_000, 1000, 1000))

  assert ffi_proc.is_alive(launched.tracer)

  let _ = ffi_proc.exit_with(agent, ffi_proc.Kill)

  sleep(100)

  assert ffi_proc.is_alive(launched.tracer) == False
}

// Terms that are not trace events are ignored, not folded and not fatal.
pub fn noise_is_ignored_test() {
  let launched = launch(config(19, ffi_proc.self(), [], 60_000, 1000, 1000))

  ffi_proc.send(launched.tracer, coerce("noise"))
  ffi_proc.send(launched.tracer, coerce(#(1, 2, 3, 4, 5)))
  ffi_proc.send(
    launched.tracer,
    coerce(#(ffi_term.atom("trace_ts"), 1, 2, 3, 4)),
  )
  send_calls(launched.tracer, 1)

  assert report(launched.tracer).4 == 1
  assert ffi_proc.is_alive(launched.tracer)
}
