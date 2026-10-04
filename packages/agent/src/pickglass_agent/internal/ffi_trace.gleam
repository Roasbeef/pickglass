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

/// The name given to every session the agent creates.
pub type SessionName {
  PickglassCounters
}

/// Process trace flags the counters probe sets. `call` makes the process
/// eligible for call tracing and `silent` stops the VM from sending a
/// trace message for every call, so counting costs no mailbox traffic.
pub type ProcessFlag {
  Call
  Silent
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

/// Create a session whose tracer is `tracer`. The caller becomes the sole
/// holder of the returned handle.
///
/// ## Examples
///
/// ```gleam
/// let session = session_create(self())
/// ```
pub fn session_create(tracer: Pid) -> Session {
  create(PickglassCounters, tracer, [])
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
