//// Trace sessions: isolated, owned tracing state.
////
//// A trace session is the VM's way to trace without touching the legacy
//// global tracer that `dbg`, `fprof` and other tools share, so the agent can
//// run a counters probe next to someone else's trace without either
//// clobbering the other. The session is owned by the process that holds the
//// strong handle `session_create` returns, and the VM destroys the session
//// when that process dies. The agent therefore keeps the handle in its own
//// state only. It is never sent, returned or logged, because any copy in
//// another process delays destruction until that process exits or
//// collects garbage.
////
//// `session_create` and `session_destroy` are called directly, since both
//// take arguments the agent controls. Calls that name a process or a
//// function a request chose go through `ffi_safe.call`, so a target that
//// died a moment ago produces `Error(Nil)` instead of an exception.

import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}

/// The strong handle to a trace session. Whoever holds the last strong
/// handle owns the session.
pub type Session

/// The weak handle to a trace session, `{Name, Id}`. It identifies a session
/// without keeping it alive, so a tracer that holds one cannot delay the
/// session's destruction, and it is enough to disable flags on the session's
/// processes and to destroy it.
pub type Weak

/// The name given to each kind of session the agent creates. The name is only
/// a label in `trace:session_info`.
pub type SessionName {
  PickglassCounters
  PickglassCalltrace
  PickglassEvents
}

/// Process trace flags a probe sets. `call` makes the process eligible for
/// call tracing and `silent` stops the VM from sending a trace message for
/// every call, so counting costs no mailbox traffic. The call tree probe
/// asks for the messages instead: `return_to` reports each return to the
/// caller without changing tail calls, `arity` sends `{M, F, Arity}` and not
/// a copy of the arguments, and `monotonic_timestamp` stamps each message
/// with the monotonic clock. `running` and `garbage_collection` are the
/// scheduling and collection events of the events probe.
pub type ProcessFlag {
  Call
  Silent
  ReturnTo
  Arity
  MonotonicTimestamp
  Running
  GarbageCollection
}

/// The node-wide thresholds `trace:system/3` can set on a session. A message
/// arrives for any process whose collection or timeslice took longer than
/// the threshold, in milliseconds.
pub type Threshold {
  LongGc
  LongSchedule
}

/// Function trace flags. `local` covers calls that stay inside a module and
/// `call_time` is the VM's per-function time counter. `call_memory` counts
/// the words each call allocates, on the releases that have it.
pub type FunctionFlag {
  Local
  CallTime
  CallMemory
}

/// Which counters a probe turns on in the traced functions.
pub type CounterMode {
  TimeOnly
  TimeAndMemory
}

/// The functions the agent applies through `ffi_safe.call`.
pub type Callee {
  Process
  Function
  Info
  ModuleInfo
  SessionDestroy
  System
}

/// Which processes a trace flag applies to. `all` is every process on the
/// node.
pub type Everyone {
  All
}

/// The `get_module_info`-style item naming a module's function list.
pub type ModuleItem {
  Functions
}

/// Atom `trace` as a module name for `ffi_safe.call`.
pub type TraceModule {
  Trace
}

@external(erlang, "trace", "session_create")
fn create(name: SessionName, tracer: Pid, options: List(Term)) -> Session

/// Create a session named `name` whose tracer is `tracer`. The caller becomes
/// the sole holder of the returned handle.
///
/// ## Examples
///
/// ```gleam
/// let session = session_create(self(), PickglassCounters)
/// ```
pub fn session_create(tracer: Pid, name: SessionName) -> Session {
  create(name, tracer, [])
}

/// The weak handle of a session. It is a copy of the `{Name, Id}` pair inside
/// the strong handle, and holding it does not own the session.
///
/// ## Examples
///
/// ```gleam
/// let weak = weak(session)
/// ```
pub fn weak(session: Session) -> Weak {
  ffi_term.coerce(ffi_term.element(2, ffi_term.coerce(session)))
}

/// Destroy a session through its weak handle. The VM raises for a session
/// that is already gone, so the call goes through the catching wrapper and
/// the answer is the same either way: afterwards the session does not exist.
///
/// ## Examples
///
/// ```gleam
/// destroy_weak(weak(session))
/// ```
pub fn destroy_weak(session: Weak) -> Nil {
  let _ = ffi_safe.call(Trace, SessionDestroy, [ffi_term.coerce(session)])

  Nil
}

/// Clear flags on one process through a weak handle, which is what a tracer
/// does to stop its own event stream before it destroys the session.
/// `Error` when the session or the process is gone.
pub fn clear_process_flags_weak(
  session: Weak,
  target: Pid,
  flags: List(ProcessFlag),
) -> Result(Int, Nil) {
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(target),
    ffi_term.coerce(False),
    ffi_term.coerce(flags),
  ]

  case ffi_safe.call(Trace, Process, args) {
    Ok(count) -> Ok(ffi_term.coerce(count))
    Error(Nil) -> Error(Nil)
  }
}

/// Turn on call tracing with messages for the functions matching
/// `{module, function, '_'}`, local calls included, and return how many
/// functions matched. The match specification matches every call and adds the
/// caller to the trace message with `{message, {caller}}`: the function the
/// call will return to, which for a tail call is the caller of the chain, so
/// the tracer can tell a tail call from a nested call and a callback from an
/// untraced framework from a call inside a traced function. No argument or
/// return value is copied. A pattern that matches nothing returns zero.
pub fn trace_call_messages(
  session: Session,
  module: Atom,
  function: Atom,
) -> Result(Int, Nil) {
  let pattern = #(module, function, ffi_term.atom("_"))
  let caller = #(ffi_term.atom("message"), #(ffi_term.atom("caller")))
  let clause = #(ffi_term.atom("_"), [], [caller])
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(pattern),
    ffi_term.coerce([clause]),
    ffi_term.coerce([Local]),
  ]

  case ffi_safe.call(Trace, Function, args) {
    Ok(count) -> Ok(ffi_term.coerce(count))
    Error(Nil) -> Error(Nil)
  }
}

/// Ask the session for a node-wide message when a collection or a timeslice
/// of any process takes longer than `milliseconds`. `Error` on a release
/// without `trace:system/3`, which is before OTP 28.
pub fn set_threshold(
  session: Session,
  threshold: Threshold,
  milliseconds: Int,
) -> Result(Nil, Nil) {
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(threshold),
    ffi_term.coerce(milliseconds),
  ]

  case ffi_safe.call(Trace, System, args) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> Error(Nil)
  }
}

/// Destroy a session and remove every flag and pattern it set. Returns
/// `False` for a session that is already gone, which is not an error.
@external(erlang, "trace", "session_destroy")
pub fn session_destroy(session: Session) -> Bool

/// Set or clear flags on one process, or on every process. Returns `Error`
/// when the VM refuses, which is what a process that just exited does.
///
/// ## Examples
///
/// ```gleam
/// set_process_flags(session, ffi_term.coerce(pid), [Call, Silent])
/// ```
pub fn set_process_flags(
  session: Session,
  target: Term,
  flags: List(ProcessFlag),
) -> Result(Int, Nil) {
  let args = [
    ffi_term.coerce(session),
    target,
    ffi_term.coerce(True),
    ffi_term.coerce(flags),
  ]

  case ffi_safe.call(Trace, Process, args) {
    Ok(count) -> Ok(ffi_term.coerce(count))
    Error(Nil) -> Error(Nil)
  }
}

/// Stop a session's call tracing on one process.
pub fn clear_process_flags(
  session: Session,
  target: Term,
  flags: List(ProcessFlag),
) -> Result(Int, Nil) {
  let args = [
    ffi_term.coerce(session),
    target,
    ffi_term.coerce(False),
    ffi_term.coerce(flags),
  ]

  case ffi_safe.call(Trace, Process, args) {
    Ok(count) -> Ok(ffi_term.coerce(count))
    Error(Nil) -> Error(Nil)
  }
}

/// Turn on `call_time` counting, and `call_memory` counting when `mode`
/// asks for it, for the functions matching `{module, function, '_'}` and
/// return how many functions matched. A pattern that matches nothing returns
/// zero, and a release without `call_memory` returns `Error`.
pub fn trace_functions(
  session: Session,
  module: Atom,
  function: Atom,
  mode: CounterMode,
) -> Result(Int, Nil) {
  let pattern = #(module, function, ffi_term.atom("_"))
  let flags = case mode {
    TimeOnly -> [Local, CallTime]
    TimeAndMemory -> [Local, CallTime, CallMemory]
  }
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(pattern),
    ffi_term.coerce(True),
    ffi_term.coerce(flags),
  ]

  case ffi_safe.call(Trace, Function, args) {
    Ok(count) -> Ok(ffi_term.coerce(count))
    Error(Nil) -> Error(Nil)
  }
}

/// The `{call_time, Value}` answer for one function. `Value` is a list of
/// `{Pid, Count, Seconds, Microseconds}` per traced process, or the atom
/// `false` when the function is no longer traced (its module was
/// reloaded).
pub fn call_time(
  session: Session,
  module: Atom,
  function: Atom,
  arity: Int,
) -> Result(Term, Nil) {
  let pattern = #(module, function, arity)
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(pattern),
    ffi_term.coerce(CallTime),
  ]

  ffi_safe.call(Trace, Info, args)
}

/// The `{call_memory, Value}` answer for one function. `Value` is a list of
/// `{Pid, Count, Words}` per traced process, or `false` when the function is
/// no longer traced.
pub fn call_memory(
  session: Session,
  module: Atom,
  function: Atom,
  arity: Int,
) -> Result(Term, Nil) {
  let pattern = #(module, function, arity)
  let args = [
    ffi_term.coerce(session),
    ffi_term.coerce(pattern),
    ffi_term.coerce(CallMemory),
  ]

  ffi_safe.call(Trace, Info, args)
}

/// The functions a loaded module exports and defines locally, as a list of
/// `{Name, Arity}`. `Error(Nil)` for a module that is not loaded.
pub fn module_functions(module: Atom) -> Result(List(#(Atom, Int)), Nil) {
  case ffi_safe.call(module, ModuleInfo, [ffi_term.coerce(Functions)]) {
    Ok(functions) -> Ok(ffi_term.coerce(functions))
    Error(Nil) -> Error(Nil)
  }
}
