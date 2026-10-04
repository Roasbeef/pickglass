//// The messages a trace session sends its tracer, decoded.
////
//// A process tracer receives one Erlang message per event, and any process
//// on the node can send it any other term, so the tracer classifies every
//// message before it folds anything. `decode` turns one into an `Event` or
//// into `NotTrace`; it never raises, and a message of the right tag but the
//// wrong shape is `NotTrace` too, so a malformed term is never mistaken for
//// an event.
////
//// Three shapes arrive. A process event, with the `monotonic_timestamp` flag
//// set, is `{trace_ts, Pid, Tag, Info, Timestamp}` where `Timestamp` is the
//// monotonic clock in the VM's native unit. A call traced with a match
//// specification that asks for the caller carries it in a sixth element,
//// `{trace_ts, Pid, call, {M, F, Arity}, Caller, Timestamp}`. A node-wide
//// threshold event from `trace:system/3` is `{monitor, Pid, Tag, Info}` and
//// carries no timestamp.
//// Tags are matched by name, because Gleam has no atom pattern and a chain
//// of comparisons would cost the tracer a call per candidate on every event.

import pickglass_agent/internal/ffi_term.{type Pid, type Term}

/// Which collection a garbage collection event describes. The tags
/// `gc_minor_*` and `gc_major_*` carry the same payload and differ only here.
pub type Collection {
  Minor
  Major
}

/// One decoded message.
pub type Event {
  /// `{trace_ts, Pid, call, {M, F, Arity}, Caller, Ts}`: a traced function
  /// was entered. `function` is the `{M, F, Arity}` term and `caller` the
  /// function it will return to, or the atom `undefined` when the VM cannot
  /// say, which includes a call that carried no caller at all. Neither is
  /// checked here.
  Called(pid: Pid, function: Term, caller: Term, at: Int)

  /// `{trace_ts, Pid, return_to, {M, F, Arity}, Ts}`: control returned to
  /// `function`, which need not be traced. A tail call chain sends one.
  ReturnedTo(pid: Pid, function: Term, at: Int)

  /// `{trace_ts, Pid, in, _, Ts}`: the process was scheduled in.
  ScheduledIn(pid: Pid, at: Int)

  /// `{trace_ts, Pid, out, _, Ts}`: the process was scheduled out.
  ScheduledOut(pid: Pid, at: Int)

  /// `{trace_ts, Pid, gc_*_start, _, Ts}`: a collection began.
  CollectionStarted(pid: Pid, kind: Collection, at: Int)

  /// `{trace_ts, Pid, gc_*_end, _, Ts}`: a collection ended.
  CollectionEnded(pid: Pid, kind: Collection, at: Int)

  /// `{monitor, Pid, long_gc, Info}`: a collection passed the threshold.
  /// `info` is the VM's property list, with `{timeout, Ms}` among it.
  LongCollection(pid: Pid, info: Term)

  /// `{monitor, Pid, long_schedule, Info}`: a timeslice passed the threshold.
  LongTimeslice(pid: Pid, info: Term)

  /// Anything else: another subsystem's message, an event this agent did not
  /// ask for, or a term of the wrong shape.
  NotTrace
}

// The tags the decoder reads from the second and third elements.
type Tag {
  TraceTs
  Monitor
  Call
  Undefined
}

/// Classify a message.
///
/// ## Examples
///
/// ```gleam
/// decode(coerce(#(TraceTs, pid, Call, mfa, 7)))
/// // -> Called(pid, mfa, 7)
/// decode(coerce(42))
/// // -> NotTrace
/// ```
pub fn decode(message: Term) -> Event {
  case ffi_term.is_tuple(message) {
    False -> NotTrace
    True ->
      case ffi_term.tuple_size(message) {
        5 -> decode_stamped(message)
        6 -> decode_call_with_caller(message)
        4 -> decode_threshold(message)
        _ -> NotTrace
      }
  }
}

// `{trace_ts, Pid, call, MFA, Caller, Ts}`. No other tag has six elements.
fn decode_call_with_caller(message: Term) -> Event {
  let pid = ffi_term.element(2, message)
  let stamp = ffi_term.element(6, message)

  case
    ffi_term.element(1, message) == ffi_term.coerce(TraceTs)
    && ffi_term.element(3, message) == ffi_term.coerce(Call)
    && ffi_term.is_pid(pid)
    && ffi_term.is_integer(stamp)
  {
    False -> NotTrace
    True ->
      Called(
        ffi_term.coerce(pid),
        ffi_term.element(4, message),
        ffi_term.element(5, message),
        ffi_term.coerce(stamp),
      )
  }
}

fn decode_stamped(message: Term) -> Event {
  let pid = ffi_term.element(2, message)
  let stamp = ffi_term.element(5, message)

  case
    ffi_term.element(1, message) == ffi_term.coerce(TraceTs)
    && ffi_term.is_pid(pid)
    && ffi_term.is_integer(stamp)
    && ffi_term.is_atom(ffi_term.element(3, message))
  {
    False -> NotTrace
    True ->
      stamped(
        ffi_term.atom_name(ffi_term.coerce(ffi_term.element(3, message))),
        ffi_term.coerce(pid),
        ffi_term.element(4, message),
        ffi_term.coerce(stamp),
      )
  }
}

fn stamped(tag: String, pid: Pid, info: Term, at: Int) -> Event {
  case tag {
    "call" -> Called(pid, info, ffi_term.coerce(Undefined), at)
    "return_to" -> ReturnedTo(pid, info, at)
    "in" -> ScheduledIn(pid, at)
    "out" -> ScheduledOut(pid, at)
    "gc_minor_start" -> CollectionStarted(pid, Minor, at)
    "gc_minor_end" -> CollectionEnded(pid, Minor, at)
    "gc_major_start" -> CollectionStarted(pid, Major, at)
    "gc_major_end" -> CollectionEnded(pid, Major, at)
    _ -> NotTrace
  }
}

fn decode_threshold(message: Term) -> Event {
  let pid = ffi_term.element(2, message)

  case
    ffi_term.element(1, message) == ffi_term.coerce(Monitor)
    && ffi_term.is_pid(pid)
    && ffi_term.is_atom(ffi_term.element(3, message))
  {
    False -> NotTrace
    True ->
      threshold(
        ffi_term.atom_name(ffi_term.coerce(ffi_term.element(3, message))),
        ffi_term.coerce(pid),
        ffi_term.element(4, message),
      )
  }
}

fn threshold(tag: String, pid: Pid, info: Term) -> Event {
  case tag {
    "long_gc" -> LongCollection(pid, info)
    "long_schedule" -> LongTimeslice(pid, info)
    _ -> NotTrace
  }
}
