//// The counters probe: per-function call counts and call time, measured by
//// the VM in a trace session of its own.
////
//// A probe is one trace session whose strong handle lives in the agent's
//// state and nowhere else. The VM counts calls and time inside the traced
//// functions with the `call_time` flag, sends no trace messages at all
//// because the traced processes carry `silent`, and keeps its counters in
//// the function's own bookkeeping, so the cost of a probe does not grow with
//// call volume. Nothing is buffered in the agent, and a probe that is never
//// read costs the traced functions their counting overhead and nothing else.
////
//// A probe ends in one of four ways, and in each the session is destroyed
//// explicitly: its deadline passes, the viewer stops it, the agent shuts
//// down, or the agent dies, in which case the VM destroys the session
//// because the agent was its sole holder. After a deadline the result is
//// kept as a `Finished` snapshot until the viewer reads or stops the probe.
////
//// What a counters probe cannot do is stated here so no view claims it: it
//// has no call tree, time spent in untraced callees is charged to the
//// nearest traced caller, and call counts are not split by process.

import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}
import pickglass_agent/internal/ffi_trace.{type Session}
import pickglass_agent/internal/seq
import pickglass_agent/topk

/// The most functions one probe may match. A pattern that matches more is
/// refused and the session destroyed before any traffic is affected.
pub const max_functions = 5000

/// The most rows a snapshot carries.
pub const max_rows = 200

/// One traced function's totals.
pub type Row {
  Row(module: String, function: String, arity: Int, calls: Int, time_us: Int)
}

/// What a probe measured at one moment. `functions` is how many functions
/// the module has, `with_calls` how many of those were called, and
/// `invalidated` how many the VM no longer traces because the module was
/// reloaded, which makes the whole snapshot suspect when it is not zero.
pub type Snapshot {
  Snapshot(rows: List(Row), functions: Int, with_calls: Int, invalidated: Int)
}

/// Where a probe is in its life.
pub type Phase {
  /// Counting. The session handle is held here, and only here.
  Running(session: Session)

  /// The deadline passed and the session is destroyed. The snapshot waits
  /// to be read.
  Finished(snapshot: Snapshot)
}

/// One probe.
pub type Probe {
  Probe(
    id: Int,
    module: Atom,
    function: Atom,
    matched: Int,
    started_ms: Int,
    deadline_at_ms: Int,
    phase: Phase,
  )
}

/// A refusal with a stable code and a sentence.
pub type Refusal {
  Refusal(code: String, detail: String)
}

/// Which processes to trace.
pub type Selection {
  EveryProcess
  TheseProcesses(pids: List(Pid))
}

// Patterns that match a function in every process of the node are the ones
// that make a probe an outage. The list is deliberately short and by name:
// these are the modules every process calls constantly, so a wildcard
// function pattern on them turns counting overhead into a node-wide
// slowdown.
const hot_modules = [
  "erlang", "lists", "maps", "ets", "gen_server", "proc_lib", "code", "trace",
  "gleam@list", "gleam@dict", "gleam@string",
]

/// Start a probe: create the session, set the function pattern, and trace
/// the selected processes. On any failure the session is destroyed before
/// the refusal is returned, so a refused probe leaves nothing behind.
///
/// ## Examples
///
/// ```gleam
/// start(1, agent_pid, module, function, EveryProcess, now_ms(), 10_000)
/// // -> Ok(Probe(id: 1, ...))
/// ```
pub fn start(
  id: Int,
  agent: Pid,
  module: Atom,
  function: Atom,
  selection: Selection,
  deadline_ms: Int,
) -> Result(Probe, Refusal) {
  use _ <- fallible.then(check_pattern(module, function))

  let session = ffi_trace.session_create(agent)

  case arm(session, module, function, selection, agent) {
    Ok(matched) -> {
      let now = ffi_proc.now_ms()

      Ok(Probe(
        id: id,
        module: module,
        function: function,
        matched: matched,
        started_ms: now,
        deadline_at_ms: now + deadline_ms,
        phase: Running(session),
      ))
    }
    Error(refusal) -> {
      let _ = ffi_trace.session_destroy(session)

      Error(refusal)
    }
  }
}

fn check_pattern(module: Atom, function: Atom) -> Result(Nil, Refusal) {
  let hot =
    seq.any(hot_modules, fn(name) { name == ffi_term.atom_name(module) })

  case hot && is_wildcard(function) {
    True ->
      Error(Refusal(
        "pattern_too_broad",
        "a wildcard function pattern on a module every process calls is refused",
      ))
    False -> Ok(Nil)
  }
}

fn is_wildcard(function: Atom) -> Bool {
  ffi_term.atom_name(function) == "_"
}

fn arm(
  session: Session,
  module: Atom,
  function: Atom,
  selection: Selection,
  agent: Pid,
) -> Result(Int, Refusal) {
  use matched <- fallible.then(fallible.replace_error(
    ffi_trace.trace_functions(session, module, function),
    Refusal("trace_failed", "the VM refused the function pattern"),
  ))

  case matched {
    0 -> Error(Refusal("no_match", "the pattern matches no loaded function"))
    _ ->
      case matched > max_functions {
        True ->
          Error(Refusal(
            "too_many_functions",
            "the pattern matches more functions than a probe may trace",
          ))
        False -> {
          use _ <- fallible.then(trace_processes(session, selection, agent))

          Ok(matched)
        }
      }
  }
}

fn trace_processes(
  session: Session,
  selection: Selection,
  agent: Pid,
) -> Result(Nil, Refusal) {
  let flags = [ffi_trace.Call, ffi_trace.Silent]

  case selection {
    EveryProcess ->
      case
        ffi_trace.set_process_flags(
          session,
          ffi_term.coerce(ffi_trace.All),
          flags,
        )
      {
        Ok(_) -> {
          // The agent is never measured: its own calls would otherwise
          // appear in the profile of the code it is inspecting.
          let _ =
            ffi_trace.clear_process_flags(
              session,
              ffi_term.coerce(agent),
              flags,
            )

          Ok(Nil)
        }
        Error(Nil) -> Error(process_refusal())
      }
    TheseProcesses(pids) -> trace_each(session, pids, flags)
  }
}

fn trace_each(
  session: Session,
  pids: List(Pid),
  flags: List(ffi_trace.ProcessFlag),
) -> Result(Nil, Refusal) {
  case pids {
    [] -> Ok(Nil)
    [pid, ..rest] ->
      case ffi_trace.set_process_flags(session, ffi_term.coerce(pid), flags) {
        Ok(_) -> trace_each(session, rest, flags)
        Error(Nil) -> Error(process_refusal())
      }
  }
}

fn process_refusal() -> Refusal {
  Refusal("target_gone", "a target process exited before it could be traced")
}

/// Read a running probe without ending it.
///
/// ## Examples
///
/// ```gleam
/// collect(session, module, function)
/// // -> Snapshot(rows: [...], functions: 12, with_calls: 3, invalidated: 0)
/// ```
pub fn collect(session: Session, module: Atom, function: Atom) -> Snapshot {
  case ffi_trace.module_functions(module) {
    Error(Nil) -> Snapshot([], 0, 0, 0)
    Ok(functions) -> {
      let matching =
        seq.filter(functions, fn(entry) {
          is_wildcard(function) || entry.0 == function
        })
      let totals =
        seq.fold(matching, Totals(topk.new(max_rows), 0, 0), fn(totals, entry) {
          read_function(totals, session, module, entry)
        })

      Snapshot(
        rows: seq.map(topk.descending(totals.top), fn(entry) { entry.1 }),
        functions: seq.length(matching),
        with_calls: totals.with_calls,
        invalidated: totals.invalidated,
      )
    }
  }
}

type Totals {
  Totals(top: topk.Top(Row), with_calls: Int, invalidated: Int)
}

// `trace:info/3` answers `{call_time, Value}`. A list is the per-process
// counters; anything else means the VM no longer traces the function, which
// is what a module reload does.
fn read_function(
  totals: Totals,
  session: Session,
  module: Atom,
  entry: #(Atom, Int),
) -> Totals {
  let #(function, arity) = entry

  case ffi_trace.call_time(session, module, function, arity) {
    Error(Nil) -> Totals(..totals, invalidated: totals.invalidated + 1)
    Ok(answer) -> read_answer(totals, module, function, arity, answer)
  }
}

fn read_answer(
  totals: Totals,
  module: Atom,
  function: Atom,
  arity: Int,
  answer: Term,
) -> Totals {
  let value = ffi_term.element(2, answer)

  case
    ffi_term.is_tuple(answer)
    && ffi_term.tuple_size(answer) == 2
    && ffi_term.is_list(value)
  {
    False -> Totals(..totals, invalidated: totals.invalidated + 1)
    True -> {
      let per_process: List(#(Term, Int, Int, Int)) = ffi_term.coerce(value)
      let #(calls, time_us) = sum(per_process, 0, 0)

      case calls {
        0 -> totals
        _ ->
          Totals(
            ..totals,
            top: topk.offer(
              totals.top,
              time_us,
              Row(
                ffi_term.atom_name(module),
                ffi_term.atom_name(function),
                arity,
                calls,
                time_us,
              ),
            ),
            with_calls: totals.with_calls + 1,
          )
      }
    }
  }
}

// Times arrive as seconds and microseconds per traced process.
fn sum(
  entries: List(#(Term, Int, Int, Int)),
  calls: Int,
  time_us: Int,
) -> #(Int, Int) {
  case entries {
    [] -> #(calls, time_us)
    [#(_, count, seconds, microseconds), ..rest] ->
      sum(rest, calls + count, time_us + seconds * 1_000_000 + microseconds)
  }
}

/// End a running probe's session. Calling it on a finished probe does
/// nothing, so teardown can be applied to every probe without asking which
/// phase it is in.
///
/// ## Examples
///
/// ```gleam
/// destroy(probe)
/// ```
pub fn destroy(probe: Probe) -> Nil {
  case probe.phase {
    Running(session) -> {
      let _ = ffi_trace.session_destroy(session)

      Nil
    }
    Finished(_) -> Nil
  }
}

/// Collect a running probe's result and destroy its session, returning the
/// probe in its `Finished` phase. A probe already finished is returned
/// unchanged.
///
/// ## Examples
///
/// ```gleam
/// finish(probe).phase
/// // -> Finished(Snapshot(...))
/// ```
pub fn finish(probe: Probe) -> Probe {
  case probe.phase {
    Running(session) -> {
      let snapshot = collect(session, probe.module, probe.function)

      destroy(probe)

      Probe(..probe, phase: Finished(snapshot))
    }
    Finished(_) -> probe
  }
}
