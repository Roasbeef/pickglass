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
//// A probe covers one or more `{Module, Function}` patterns at once, up to
//// eight, so that the code a question is about, which rarely sits in one
//// module, is measured in one session and one interval. The function cap
//// and the hot-module deny list apply to the whole set. With `call_memory`
//// on, the VM also counts the words allocated while each function ran, and
//// the snapshot lists the functions that allocated the most with their calls
//// and call time, beside the sum over every function it could read.
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
import pickglass_agent/internal/ffi_trace.{type CounterMode, type Session}
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

/// The words one function allocated while it ran, summed over the traced
/// processes, with the calls and call time the same read found. They travel
/// together so that a viewer ranking functions by allocation does not have to
/// find the same function in the time rows, which are ranked by time and cut
/// at a different place.
pub type MemoryRow {
  MemoryRow(
    module: String,
    function: String,
    arity: Int,
    words: Int,
    calls: Int,
    time_us: Int,
  )
}

/// What the allocation reads of one snapshot add up to, over every called
/// function and not only the rows kept. `read` functions had a `call_memory`
/// reading and `unread` called functions did not, because the VM no longer
/// answered for them. `words` sums the readings, so the rows kept can be put
/// against the whole.
pub type MemoryTotals {
  MemoryTotals(read: Int, unread: Int, words: Int)
}

/// What a probe counted for allocation. A probe without `call_memory` has no
/// reading, which is not the same as zero words.
pub type Memory {
  NotCounted
  Counted(rows: List(MemoryRow), totals: MemoryTotals)
}

/// One `{Module, Function}` pattern. A function of `_` covers every
/// function of the module.
pub type Pattern {
  Pattern(module: Atom, function: Atom)
}

/// What a probe measured at one moment. `functions` is how many functions
/// the module has, `with_calls` how many of those were called, and
/// `invalidated` how many the VM no longer traces because the module was
/// reloaded, which makes the whole snapshot suspect when it is not zero.
pub type Snapshot {
  Snapshot(
    rows: List(Row),
    memory: Memory,
    functions: Int,
    with_calls: Int,
    invalidated: Int,
  )
}

/// Where a probe is in its life.
pub type Phase {
  /// Counting. The session handle is held here, and only here.
  Running(session: Session)

  /// The deadline passed or the viewer stopped the probe, and the session is
  /// destroyed. The snapshot waits to be read. `ended_ms` is when the session
  /// was destroyed, which is the end of the window the counters cover: a
  /// reading taken later does not make the window longer.
  Finished(snapshot: Snapshot, ended_ms: Int)
}

/// One probe. `owner` is the link process of the viewer that started it; the
/// agent lets only that viewer read, stop or see it.
pub type Probe {
  Probe(
    id: Int,
    owner: Pid,
    patterns: List(Pattern),
    mode: CounterMode,
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

/// Start a probe: create the session, set every function pattern, and trace
/// the selected processes. On any failure the session is destroyed before
/// the refusal is returned, so a refused probe leaves nothing behind.
///
/// ## Examples
///
/// ```gleam
/// start(1, viewer_pid, agent_pid, [Pattern(module, function)], TimeOnly, EveryProcess, 10_000)
/// // -> Ok(Probe(id: 1, ...))
/// ```
pub fn start(
  id: Int,
  owner: Pid,
  agent: Pid,
  patterns: List(Pattern),
  mode: CounterMode,
  selection: Selection,
  deadline_ms: Int,
) -> Result(Probe, Refusal) {
  let distinct = distinct_patterns(patterns)

  use _ <- fallible.then(check_patterns(distinct))

  let session = ffi_trace.session_create(agent, ffi_trace.PickglassCounters)

  case arm(session, distinct, mode, selection, agent) {
    Ok(matched) -> {
      let now = ffi_proc.now_ms()

      Ok(Probe(
        id: id,
        owner: owner,
        patterns: distinct,
        mode: mode,
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

/// Reduce a pattern set to the patterns that cover it. A repeated pattern, or
/// a pattern a wildcard of the same module already covers, would be counted
/// twice by the VM and listed twice in the rows, so the set is reduced before
/// anything is armed. The first occurrence wins and the order is kept.
///
/// ## Examples
///
/// ```gleam
/// distinct_patterns([Pattern(m, run), Pattern(m, any), Pattern(m, run)])
/// // -> [Pattern(m, any)]
/// ```
pub fn distinct_patterns(patterns: List(Pattern)) -> List(Pattern) {
  distinct_onto(patterns, patterns, [])
}

fn distinct_onto(
  remaining: List(Pattern),
  all: List(Pattern),
  acc: List(Pattern),
) -> List(Pattern) {
  case remaining {
    [] -> seq.reverse(acc)
    [pattern, ..rest] ->
      case covered(pattern, acc) || covered_by_wildcard(pattern, all) {
        True -> distinct_onto(rest, all, acc)
        False -> distinct_onto(rest, all, [pattern, ..acc])
      }
  }
}

fn covered(pattern: Pattern, kept: List(Pattern)) -> Bool {
  seq.any(kept, fn(other) { other == pattern })
}

fn covered_by_wildcard(pattern: Pattern, all: List(Pattern)) -> Bool {
  !is_wildcard(pattern.function)
  && seq.any(all, fn(other) {
    other.module == pattern.module && is_wildcard(other.function)
  })
}

/// Refuse a pattern set that names a wildcard function on a module every
/// process calls. A probe over pinned processes uses the same list, because
/// the cost of tracing a hot module is paid in the pinned process too.
///
/// ## Examples
///
/// ```gleam
/// check_patterns([Pattern(lists, any)])
/// // -> Error(Refusal("pattern_too_broad", _))
/// ```
pub fn check_patterns(patterns: List(Pattern)) -> Result(Nil, Refusal) {
  case patterns {
    [] -> Ok(Nil)
    [pattern, ..rest] -> {
      use _ <- fallible.then(check_pattern(pattern))

      check_patterns(rest)
    }
  }
}

fn check_pattern(pattern: Pattern) -> Result(Nil, Refusal) {
  let hot =
    seq.any(hot_modules, fn(name) { name == ffi_term.atom_name(pattern.module) })

  case hot && is_wildcard(pattern.function) {
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
  patterns: List(Pattern),
  mode: CounterMode,
  selection: Selection,
  agent: Pid,
) -> Result(Int, Refusal) {
  use matched <- fallible.then(arm_patterns(session, patterns, mode, 0))

  case matched > max_functions {
    True ->
      Error(Refusal(
        "too_many_functions",
        "the patterns match more functions than a probe may trace",
      ))
    False -> {
      use _ <- fallible.then(trace_processes(session, selection, agent))

      Ok(matched)
    }
  }
}

// Each pattern is armed in turn and its match count added. A pattern that
// matches nothing refuses the whole probe, so a misspelt name among several
// is loud and not a silently empty column. The total is checked against the
// cap by the caller after every pattern is armed, which is before any
// process is traced, so a refusal costs no traffic.
fn arm_patterns(
  session: Session,
  patterns: List(Pattern),
  mode: CounterMode,
  matched: Int,
) -> Result(Int, Refusal) {
  case patterns {
    [] -> Ok(matched)
    [pattern, ..rest] -> {
      use count <- fallible.then(arm_pattern(session, pattern, mode))

      arm_patterns(session, rest, mode, matched + count)
    }
  }
}

fn arm_pattern(
  session: Session,
  pattern: Pattern,
  mode: CounterMode,
) -> Result(Int, Refusal) {
  case
    ffi_trace.trace_functions(session, pattern.module, pattern.function, mode)
  {
    Error(Nil) ->
      Error(case mode {
        ffi_trace.TimeOnly ->
          Refusal("trace_failed", "the VM refused the function pattern")
        ffi_trace.TimeAndMemory ->
          Refusal(
            "memory_unavailable",
            "the VM refused the pattern or has no call_memory counter",
          )
      })
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
/// collect(session, patterns, TimeOnly)
/// // -> Snapshot(rows: [...], functions: 12, with_calls: 3, invalidated: 0)
/// ```
pub fn collect(
  session: Session,
  patterns: List(Pattern),
  mode: CounterMode,
) -> Snapshot {
  let totals =
    seq.fold(
      patterns,
      Totals(
        topk.new(max_rows),
        topk.new(max_rows),
        MemoryTotals(read: 0, unread: 0, words: 0),
        0,
        0,
        0,
      ),
      fn(totals, pattern) { collect_pattern(totals, session, pattern, mode) },
    )

  Snapshot(
    rows: seq.map(topk.descending(totals.top), fn(entry) { entry.1 }),
    memory: case mode {
      ffi_trace.TimeOnly -> NotCounted
      ffi_trace.TimeAndMemory ->
        Counted(
          rows: seq.map(topk.descending(totals.memory), fn(entry) { entry.1 }),
          totals: totals.memory_totals,
        )
    },
    functions: totals.functions,
    with_calls: totals.with_calls,
    invalidated: totals.invalidated,
  )
}

fn collect_pattern(
  totals: Totals,
  session: Session,
  pattern: Pattern,
  mode: CounterMode,
) -> Totals {
  case ffi_trace.module_functions(pattern.module) {
    Error(Nil) -> totals
    Ok(functions) -> {
      let matching =
        seq.filter(functions, fn(entry) {
          is_wildcard(pattern.function) || entry.0 == pattern.function
        })

      seq.fold(
        matching,
        Totals(..totals, functions: totals.functions + seq.length(matching)),
        fn(totals, entry) {
          read_function(totals, session, pattern.module, entry, mode)
        },
      )
    }
  }
}

type Totals {
  Totals(
    top: topk.Top(Row),
    memory: topk.Top(MemoryRow),
    memory_totals: MemoryTotals,
    functions: Int,
    with_calls: Int,
    invalidated: Int,
  )
}

// `trace:info/3` answers `{call_time, Value}`. A list is the per-process
// counters; anything else means the VM no longer traces the function, which
// is what a module reload does.
fn read_function(
  totals: Totals,
  session: Session,
  module: Atom,
  entry: #(Atom, Int),
  mode: CounterMode,
) -> Totals {
  let #(function, arity) = entry

  case ffi_trace.call_time(session, module, function, arity) {
    Error(Nil) -> Totals(..totals, invalidated: totals.invalidated + 1)
    Ok(answer) ->
      read_answer(totals, session, module, function, arity, answer, mode)
  }
}

fn read_answer(
  totals: Totals,
  session: Session,
  module: Atom,
  function: Atom,
  arity: Int,
  answer: Term,
  mode: CounterMode,
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
            ..offer_memory(
              totals,
              session,
              #(module, function),
              MemoryRow(
                ffi_term.atom_name(module),
                ffi_term.atom_name(function),
                arity,
                0,
                calls,
                time_us,
              ),
              mode,
            ),
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

// The words a function allocated, summed over the traced processes, offered
// to the bounded memory list. `row` carries everything but the words, which
// are read here. A probe that did not ask for memory offers nothing, and a
// function whose reading cannot be taken is counted as unread and left out,
// so neither shows as zero words.
fn offer_memory(
  totals: Totals,
  session: Session,
  names: #(Atom, Atom),
  row: MemoryRow,
  mode: CounterMode,
) -> Totals {
  case mode {
    ffi_trace.TimeOnly -> totals
    ffi_trace.TimeAndMemory ->
      case ffi_trace.call_memory(session, names.0, names.1, row.arity) {
        Error(Nil) -> unread(totals)
        Ok(answer) ->
          case memory_words(answer) {
            Error(Nil) -> unread(totals)
            Ok(words) ->
              Totals(
                ..totals,
                memory: topk.offer(
                  totals.memory,
                  words,
                  MemoryRow(..row, words:),
                ),
                memory_totals: MemoryTotals(
                  ..totals.memory_totals,
                  read: totals.memory_totals.read + 1,
                  words: totals.memory_totals.words + words,
                ),
              )
          }
      }
  }
}

fn unread(totals: Totals) -> Totals {
  Totals(
    ..totals,
    memory_totals: MemoryTotals(
      ..totals.memory_totals,
      unread: totals.memory_totals.unread + 1,
    ),
  )
}

fn memory_words(answer: Term) -> Result(Int, Nil) {
  let value = ffi_term.element(2, answer)

  case
    ffi_term.is_tuple(answer)
    && ffi_term.tuple_size(answer) == 2
    && ffi_term.is_list(value)
  {
    False -> Error(Nil)
    True -> Ok(sum_words(ffi_term.coerce(value), 0))
  }
}

// `{Pid, Count, Words}` per traced process.
fn sum_words(entries: List(#(Term, Int, Int)), acc: Int) -> Int {
  case entries {
    [] -> acc
    [#(_, _, words), ..rest] -> sum_words(rest, acc + words)
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
    Finished(..) -> Nil
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
      let snapshot = collect(session, probe.patterns, probe.mode)

      destroy(probe)

      Probe(..probe, phase: Finished(snapshot, ended_ms: ffi_proc.now_ms()))
    }
    Finished(..) -> probe
  }
}
