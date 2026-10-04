//// The tracer process of an event probe: one gen_server per probe that
//// receives the trace session's messages, folds each into an aggregate as it
//// arrives, and stops the stream itself when a bound is reached.
////
//// ## Why the tracer is a process of its own
////
//// A process tracer has no backpressure. The VM enqueues every trace message
//// whatever the tracer's mailbox holds, so a traced process in a tight loop
//// can add a million messages to a slow tracer, and destroying the session
//// does not recall the ones already queued. The probe therefore folds events
//// into counts and times instead of storing them, which makes its memory a
//// function of the bounds and not of the traffic, and the tracer is a
//// separate process from the agent, so a flooded mailbox delays only the
//// probe and never the agent's own deadline, stop or teardown handling.
////
//// ## Who owns the session
////
//// The agent holds the only strong handle to the session, as it does for a
//// counters probe, and sends the tracer the weak handle `{Name, Id}`. The
//// weak handle cannot delay the session's destruction, and it is enough to
//// clear the target's flags and to destroy the session, which is how the
//// tracer cuts the stream the moment a bound is reached and before it
//// messages the agent. The agent destroys the session as well when it hears
//// so, and destroying a destroyed session is harmless.
////
//// ## Bounds
////
//// A probe stops for one of the reasons in `tracing.Stop`. Its window ends
//// with a timer; its event budget ends it at exactly the budgeted event; and
//// every `tracing.check_every` events the tracer reads its own mailbox
//// length and stops with `Overrun` when it is past the probe's limit. Events
//// that arrive after the stop are counted as dropped and discarded unread, and
//// the number that was queued at the stop is reported with them.
////
//// ## Flow
////
//// `launch` starts the tracer, creates the session with the tracer as its
//// owner of events, sends the weak handle, and arms the session through a
//// function the caller supplies. `init` monitors the agent and every target
//// and arms the window timer. `handle_info` takes every message: a trace
//// event is folded, a control message from the agent is answered, and a
//// monitor `DOWN` ends a target or the tracer. `finish` is the one place a
//// probe stops. The result is kept in the tracer until the agent reads or
//// stops it.

import pickglass_agent/counters.{type Refusal, Refusal}
import pickglass_agent/internal/ffi_events.{type Event}
import pickglass_agent/internal/ffi_gen_server.{
  type Next, Noreply, Normal, SpawnOpt, Stop,
}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{
  type Atom, type Pid, type Reference, type Term,
}
import pickglass_agent/internal/ffi_trace.{
  type Session, type SessionName, type Weak,
}
import pickglass_agent/internal/seq
import pickglass_agent/owner
import pickglass_agent/reply
import pickglass_agent/tracing.{type Meter, type Stop as Why, Meter}

/// What folding one event did to the aggregate.
pub type Ingest(body) {
  /// The event was folded and counts toward the event budget.
  Counted(body: body)

  /// The event was folded and does not count toward the budget. Node-wide
  /// threshold messages are these: they are rare and kept to a small list.
  /// They still count toward the next look at the mailbox.
  Uncounted(body: body)

  /// The event is not one this probe folds.
  Ignored
}

/// What a probe reports at one moment: its identity, whether it is still
/// running, why it stopped, how it ran, and its aggregate.
pub type Report(body) {
  Report(id: Int, phase: String, stop: Why, meter: Meter, body: body)
}

/// Everything a tracer needs, supplied by the probe's own module. The three
/// functions are the probe's behaviour: `ingest` folds one event, `close`
/// finishes frames or runs still open, and `report` writes the reply.
pub type Config(body) {
  Config(
    /// The agent, told when the probe stops and whose death ends the tracer.
    agent: Pid,
    /// The probe's id, quoted in the notice to the agent.
    id: Int,
    /// The processes traced. The tracer monitors them to learn when none is
    /// left, and clears their flags when it stops.
    targets: List(Pid),
    /// The window, in milliseconds from the tracer's start.
    duration_ms: Int,
    /// The most events folded before the tracer stops the stream.
    max_events: Int,
    /// The longest mailbox tolerated, in messages.
    queue_limit: Int,
    /// The flags the session set on each target, which the tracer clears.
    flags: List(ffi_trace.ProcessFlag),
    /// The aggregate as it starts.
    body: body,
    ingest: fn(body, Event) -> Ingest(body),
    close: fn(body) -> body,
    report: fn(Report(body)) -> Term,
  )
}

/// A probe that is running: the strong session handle, which the caller must
/// keep and never send, the tracer and how many functions its patterns
/// matched.
pub type Launched {
  Launched(session: Session, tracer: Pid, matched: Int)
}

/// Whether the tracer has been handed the session's weak handle.
pub type Handle {
  Unarmed
  Armed(weak: Weak)
}

/// The tracer's state.
pub type State(body) {
  State(
    config: Config(body),
    agent_monitor: Reference,
    target_monitors: List(Reference),
    alive: Int,
    handle: Handle,
    started_ms: Int,
    ended_ms: Int,
    body: body,
    events: Int,
    dropped: Int,
    in_flight: Int,
    peak_queue: Int,
    until_check: Int,
    targets_gone: Int,
    stop: Why,
  )
}

// The tags of the messages the agent and the tracer exchange.
type Tag {
  PickglassTraceSession
  PickglassTraceRead
  PickglassTraceStop
  PickglassTraceFinished
}

type Notice {
  Deadline
}

type Control {
  Handed(weak: Term)
  ReadAsked(reply_to: Pid, request: Reference)
  StopAsked(reply_to: Pid, request: Reference)
  WindowEnded
  Down(monitor: Reference)
  Other
}

/// Start a tracer, create the session it owns the events of, and arm the
/// session with `arm`, which sets the function patterns and the process
/// flags and returns how many functions matched. The caller becomes the sole
/// holder of the strong handle. On any failure the session is destroyed and
/// the tracer killed before the refusal is returned, so a refused probe
/// leaves nothing behind.
///
/// The weak handle is sent before `arm` runs, so it is in the tracer's mailbox
/// before the first event can be.
///
/// ## Examples
///
/// ```gleam
/// launch(config, PickglassCalltrace, 4_000_000, fn(session) { Ok(0) })
/// ```
pub fn launch(
  config: Config(body),
  name: SessionName,
  heap_words: Int,
  arm: fn(Session) -> Result(Int, Refusal),
) -> Result(Launched, Refusal) {
  let started =
    ffi_gen_server.start_unlinked(
      ffi_term.atom("pickglass_agent@tracer"),
      ffi_term.coerce(config),
      [
        SpawnOpt([
          ffi_proc.heap_limit(heap_words),
          ffi_proc.Priority(ffi_proc.High),
          ffi_proc.MessageQueueData(ffi_proc.OffHeap),
        ]),
      ],
    )

  case tracer_of(started) {
    Error(Nil) ->
      Error(Refusal("start_failed", "the agent could not start a tracer"))
    Ok(tracer) -> arm_session(tracer, name, arm)
  }
}

fn arm_session(
  tracer: Pid,
  name: SessionName,
  arm: fn(Session) -> Result(Int, Refusal),
) -> Result(Launched, Refusal) {
  let session = ffi_trace.session_create(tracer, name)

  ffi_proc.send(
    tracer,
    ffi_term.coerce(#(PickglassTraceSession, ffi_trace.weak(session))),
  )

  case arm(session) {
    Ok(matched) -> Ok(Launched(session, tracer, matched))
    Error(refusal) -> {
      let _ = ffi_trace.session_destroy(session)
      let _ = ffi_proc.exit_with(tracer, ffi_proc.Kill)

      Error(refusal)
    }
  }
}

fn tracer_of(started: Term) -> Result(Pid, Nil) {
  case
    ffi_term.is_tuple(started)
    && ffi_term.tuple_size(started) == 2
    && ffi_term.element(1, started) == ffi_term.coerce(ffi_term.atom("ok"))
  {
    True -> Ok(ffi_term.coerce(ffi_term.element(2, started)))
    False -> Error(Nil)
  }
}

/// Ask a tracer for its result so far. The tracer replies to `reply_to`
/// itself.
///
/// ## Examples
///
/// ```gleam
/// read(tracer, viewer, request)
/// ```
pub fn read(tracer: Pid, reply_to: Pid, request: Reference) -> Nil {
  ffi_proc.send(
    tracer,
    ffi_term.coerce(#(PickglassTraceRead, reply_to, request)),
  )
}

/// Ask a tracer to stop, reply with its final result and exit.
///
/// ## Examples
///
/// ```gleam
/// stop(tracer, viewer, request)
/// ```
pub fn stop(tracer: Pid, reply_to: Pid, request: Reference) -> Nil {
  ffi_proc.send(
    tracer,
    ffi_term.coerce(#(PickglassTraceStop, reply_to, request)),
  )
}

/// The tag of the message a tracer sends the agent when its probe stops, as
/// `{Tag, ProbeId}`. The agent matches on it in `server.classify`.
pub fn finished_tag() -> Atom {
  ffi_term.coerce(PickglassTraceFinished)
}

/// The `gen_server` init callback. Monitors the agent and every target and
/// arms the window.
pub fn init(config: Config(body)) -> Result(State(body), Nil) {
  owner.claim_self()

  let _ =
    ffi_proc.send_after(
      config.duration_ms,
      ffi_proc.self(),
      ffi_term.coerce(Deadline),
    )

  Ok(State(
    config: config,
    agent_monitor: ffi_proc.monitor(ffi_proc.Process, config.agent),
    target_monitors: seq.map(config.targets, fn(pid) {
      ffi_proc.monitor(ffi_proc.Process, pid)
    }),
    alive: seq.length(config.targets),
    handle: Unarmed,
    started_ms: ffi_proc.now_ms(),
    ended_ms: 0,
    body: config.body,
    events: 0,
    dropped: 0,
    in_flight: 0,
    peak_queue: 0,
    until_check: tracing.check_every,
    targets_gone: 0,
    stop: tracing.Tracing,
  ))
}

/// The `gen_server` callback for every message. A trace event is the hot
/// path and is classified first; anything else is a control message or noise.
pub fn handle_info(message: Term, state: State(body)) -> Next(State(body)) {
  case ffi_events.decode(message) {
    ffi_events.NotTrace -> on_control(classify(message), state)
    ffi_events.Called(_, _, _, _) as event
    | ffi_events.ReturnedTo(_, _, _) as event
    | ffi_events.ScheduledIn(_, _) as event
    | ffi_events.ScheduledOut(_, _) as event
    | ffi_events.CollectionStarted(_, _, _) as event
    | ffi_events.CollectionEnded(_, _, _) as event
    | ffi_events.LongCollection(_, _) as event
    | ffi_events.LongTimeslice(_, _) as event -> Noreply(on_event(event, state))
  }
}

// An event that arrives while the probe is tracing is folded. One that
// arrives after it stopped was in flight when the stream was cut, and is
// counted and thrown away.
fn on_event(event: Event, state: State(body)) -> State(body) {
  case state.stop {
    tracing.Tracing -> fold(event, state)
    tracing.DeadlineReached
    | tracing.EventBudget
    | tracing.Overrun
    | tracing.TargetsGone
    | tracing.Stopped -> State(..state, dropped: state.dropped + 1)
  }
}

fn fold(event: Event, state: State(body)) -> State(body) {
  case state.config.ingest(state.body, event) {
    Ignored -> state
    Uncounted(body) ->
      check_queue_when_due(
        State(..state, body: body, until_check: state.until_check - 1),
      )
    Counted(body) ->
      counted(
        State(
          ..state,
          body: body,
          events: state.events + 1,
          until_check: state.until_check - 1,
        ),
      )
  }
}

// The event budget is exact: the tracer stops at the event that spends it.
fn counted(state: State(body)) -> State(body) {
  case state.events >= state.config.max_events {
    True -> finish(state, tracing.EventBudget)
    False -> check_queue_when_due(state)
  }
}

fn check_queue_when_due(state: State(body)) -> State(body) {
  case state.until_check <= 0 {
    False -> state
    True -> check_queue(state)
  }
}

// A producer that outruns the tracer leaves its backlog in the mailbox, and
// the mailbox is the one thing nothing else bounds. Reading its length is
// one cheap call, made every `check_every` events.
fn check_queue(state: State(body)) -> State(body) {
  let queued = queue_length()
  let checked =
    State(
      ..state,
      peak_queue: larger(state.peak_queue, queued),
      until_check: tracing.check_every,
    )

  case queued > state.config.queue_limit {
    True -> finish(checked, tracing.Overrun)
    False -> checked
  }
}

fn larger(first: Int, second: Int) -> Int {
  case second > first {
    True -> second
    False -> first
  }
}

fn queue_length() -> Int {
  let answer: List(#(Term, Int)) =
    ffi_term.coerce(
      ffi_proc.process_info(ffi_proc.self(), [ffi_proc.MessageQueueLen]),
    )

  case answer {
    [#(_, length)] -> length
    _ -> 0
  }
}

// The one place a probe stops. The stream is cut first, at its source: the
// targets' flags are cleared and the session destroyed through the weak
// handle, so nothing more is queued. Then the aggregate is closed, the stop
// reason and the backlog recorded, and the agent told. A probe that already
// stopped keeps its first reason.
fn finish(state: State(body), why: Why) -> State(body) {
  case state.stop {
    tracing.Tracing -> {
      let queued = queue_length()

      release(state)

      ffi_proc.send(
        state.config.agent,
        ffi_term.coerce(#(PickglassTraceFinished, state.config.id)),
      )

      State(
        ..state,
        body: state.config.close(state.body),
        stop: why,
        ended_ms: ffi_proc.now_ms(),
        in_flight: queued,
        peak_queue: larger(state.peak_queue, queued),
      )
    }
    tracing.DeadlineReached
    | tracing.EventBudget
    | tracing.Overrun
    | tracing.TargetsGone
    | tracing.Stopped -> state
  }
}

fn release(state: State(body)) -> Nil {
  case state.handle {
    Unarmed -> Nil
    Armed(weak) -> {
      seq.each(state.config.targets, fn(pid) {
        ffi_trace.clear_process_flags_weak(weak, pid, state.config.flags)
      })

      ffi_trace.destroy_weak(weak)
    }
  }
}

fn classify(message: Term) -> Control {
  case message == ffi_term.coerce(Deadline) {
    True -> WindowEnded
    False ->
      case ffi_term.is_tuple(message) {
        False -> Other
        True -> classify_tuple(message, ffi_term.tuple_size(message))
      }
  }
}

fn classify_tuple(message: Term, size: Int) -> Control {
  case size {
    // `{pickglass_trace_session, Weak}`.
    2 ->
      case
        ffi_term.element(1, message) == ffi_term.coerce(PickglassTraceSession)
      {
        True -> Handed(ffi_term.element(2, message))
        False -> Other
      }

    // `{pickglass_trace_read | pickglass_trace_stop, ReplyTo, Ref}`.
    3 -> classify_request(message)

    // `{'DOWN', Ref, process, Pid, Reason}`.
    5 ->
      case
        ffi_term.element(1, message) == ffi_term.coerce(ffi_term.atom("DOWN"))
        && ffi_term.is_reference(ffi_term.element(2, message))
      {
        True -> Down(ffi_term.coerce(ffi_term.element(2, message)))
        False -> Other
      }
    _ -> Other
  }
}

fn classify_request(message: Term) -> Control {
  case
    ffi_term.is_pid(ffi_term.element(2, message))
    && ffi_term.is_reference(ffi_term.element(3, message))
  {
    False -> Other
    True -> {
      let reply_to: Pid = ffi_term.coerce(ffi_term.element(2, message))
      let request: Reference = ffi_term.coerce(ffi_term.element(3, message))
      let tag = ffi_term.element(1, message)

      case
        tag == ffi_term.coerce(PickglassTraceRead),
        tag == ffi_term.coerce(PickglassTraceStop)
      {
        True, _ -> ReadAsked(reply_to, request)
        _, True -> StopAsked(reply_to, request)
        False, False -> Other
      }
    }
  }
}

fn on_control(control: Control, state: State(body)) -> Next(State(body)) {
  case control {
    Handed(weak) ->
      Noreply(State(..state, handle: Armed(ffi_term.coerce(weak))))
    WindowEnded -> Noreply(finish(state, tracing.DeadlineReached))
    ReadAsked(reply_to, request) -> {
      snapshot(state, reply_to, request)

      Noreply(state)
    }
    StopAsked(reply_to, request) -> {
      let halted = finish(state, tracing.Stopped)

      snapshot(halted, reply_to, request)

      Stop(Normal, halted)
    }
    Down(monitor) -> on_down(monitor, state)
    Other -> Noreply(state)
  }
}

// The agent's death ends the tracer. A target's death is counted, and the
// last one ends the probe, not the tracer, which keeps its result.
fn on_down(monitor: Reference, state: State(body)) -> Next(State(body)) {
  case monitor == state.agent_monitor {
    True -> Stop(Normal, state)
    False -> Noreply(target_down(monitor, state))
  }
}

fn target_down(monitor: Reference, state: State(body)) -> State(body) {
  case seq.any(state.target_monitors, fn(held) { held == monitor }) {
    False -> state
    True -> {
      let remaining =
        State(
          ..state,
          target_monitors: seq.filter(state.target_monitors, fn(held) {
            held != monitor
          }),
          alive: state.alive - 1,
          targets_gone: state.targets_gone + 1,
        )

      case remaining.alive {
        0 -> finish(remaining, tracing.TargetsGone)
        _ -> remaining
      }
    }
  }
}

// A read of a running probe closes a copy of the aggregate and leaves the
// probe running; a probe that stopped already holds its closed aggregate.
// A probe stopped by this very request reads as `stopped`.
fn snapshot(state: State(body), reply_to: Pid, request: Reference) -> Nil {
  let #(phase, body) = case state.stop {
    tracing.Tracing -> #("running", state.config.close(state.body))
    tracing.Stopped -> #("stopped", state.body)
    tracing.DeadlineReached
    | tracing.EventBudget
    | tracing.Overrun
    | tracing.TargetsGone -> #("finished", state.body)
  }

  reply.send(
    reply_to,
    request,
    state.config.report(Report(
      state.config.id,
      phase,
      state.stop,
      meter(state),
      body,
    )),
  )
}

fn meter(state: State(body)) -> Meter {
  let end = case state.stop {
    tracing.Tracing -> ffi_proc.now_ms()
    tracing.DeadlineReached
    | tracing.EventBudget
    | tracing.Overrun
    | tracing.TargetsGone
    | tracing.Stopped -> state.ended_ms
  }

  Meter(
    elapsed_ms: end - state.started_ms,
    events: state.events,
    max_events: state.config.max_events,
    dropped_events: state.dropped,
    in_flight_at_stop: state.in_flight,
    peak_queue: state.peak_queue,
    queue_limit: state.config.queue_limit,
    targets_gone: state.targets_gone,
  )
}
