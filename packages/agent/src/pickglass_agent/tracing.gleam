//// What the two event probes share: why one stopped, what it measured about
//// itself, and the bounds that keep it from becoming an outage.
////
//// The call tree probe and the scheduling and garbage collection probe both
//// work by sending a tracer process one message per event, and a process
//// tracer has no backpressure: the VM enqueues each message whatever the
//// tracer's mailbox holds, and destroying the session does not recall the
//// ones already queued. Everything here follows from that. A probe is bounded
//// three ways, by a window of time, by a budget of events it folds, and by a
//// limit on its own mailbox, and the reason it stopped is always one of the
//// `Stop` values below, never a silent truncation.
////
//// This module holds types and constants only, so that `reply` can describe a
//// probe's result and `tracer` can run one without either importing the other.

/// Why a probe stopped, or that it has not.
pub type Stop {
  /// Still tracing.
  Tracing

  /// The window passed.
  DeadlineReached

  /// The event budget was spent. The tracer stopped the stream itself.
  EventBudget

  /// The tracer's mailbox grew past its limit: the traced processes produce
  /// events faster than the tracer folds them, and the probe stopped before
  /// the backlog could grow without bound.
  Overrun

  /// Every target exited.
  TargetsGone

  /// The viewer stopped the probe.
  Stopped
}

/// What a probe measured about its own run. `events` counts the events folded
/// into the result. `dropped_events` counts the events that arrived after the
/// probe stopped and were discarded unread, and `in_flight_at_stop` is how
/// many were already queued at the moment it stopped, so the two normally
/// agree. `peak_queue` is the longest mailbox seen between checks.
pub type Meter {
  Meter(
    elapsed_ms: Int,
    events: Int,
    max_events: Int,
    dropped_events: Int,
    in_flight_at_stop: Int,
    peak_queue: Int,
    queue_limit: Int,
    targets_gone: Int,
  )
}

/// The most events a probe may fold, whatever a request asks for.
pub const max_events = 200_000

/// The longest mailbox a tracer tolerates, in messages. At a few hundred
/// bytes a message this is a few megabytes, and the tracer drains it in tens
/// of milliseconds once the stream has stopped.
pub const queue_limit = 50_000

/// How many events a tracer folds between looks at its own mailbox. A
/// producer that outruns the tracer adds hundreds of messages in that many
/// events, so the check is cheap and the overshoot small.
pub const check_every = 64

/// The most targets a call tree probe may trace.
pub const max_calltrace_targets = 4

/// The most targets an events probe may trace.
pub const max_events_targets = 8

/// The shortest window of either probe, in milliseconds.
pub const min_window_ms = 100

/// The longest call tree window, in milliseconds. Call events are the
/// expensive kind, a few hundred nanoseconds each before the tracer's own
/// cost, so the window is short.
pub const max_calltrace_ms = 10_000

/// The longest events window, in milliseconds.
pub const max_events_ms = 60_000

/// The most raw call slices a call tree probe returns for a timeline.
pub const max_timeline = 2000

/// The most scheduling and collection slices an events probe returns.
pub const max_slices = 5000

/// The longest node-wide threshold a request may set, in milliseconds.
pub const max_threshold_ms = 10_000

/// The wire name of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// stop_name(EventBudget)
/// // -> "event_budget"
/// ```
pub fn stop_name(stop: Stop) -> String {
  case stop {
    Tracing -> "running"
    DeadlineReached -> "deadline"
    EventBudget -> "event_budget"
    Overrun -> "overrun"
    TargetsGone -> "targets_gone"
    Stopped -> "stopped"
  }
}
