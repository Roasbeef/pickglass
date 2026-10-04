//// Replies, and the one place their wire shape is written.
////
//// Every reply is `{<<"pg">>, 1, Ref, Body}` where `Ref` is the reference
//// the request carried and `Body` is a tuple whose first element is a
//// binary tag. Replies use binaries, integers, lists, tuples and the atoms
//// `true` and `false` only, so the viewer's decoders in `pickglass_core`
//// can read them with the standard dynamic decoders and never need an atom
//// type. The tags and field order here are the contract the decoders in
//// `pickglass_core/wire.gleam` implement; a change to either is a change to
//// both.
////
//// A failure is `{<<"error">>, Code, Detail}` with a short code the viewer
//// can branch on and a sentence for a person.

import pickglass_agent/census
import pickglass_agent/counters
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Reference, type Term}
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner, Owned, Unknown}
import pickglass_agent/request

/// A refusal: a stable code and a human sentence.
pub type Failure {
  Failure(code: String, detail: String)
}

/// Send a reply body to the process that asked.
///
/// ## Examples
///
/// ```gleam
/// send(reply_to, reference, pong(...))
/// ```
pub fn send(to: Pid, reference: Reference, body: Term) -> Nil {
  ffi_proc.send(
    to,
    ffi_term.coerce(#("pg", request.wire_version, reference, body)),
  )
}

/// A refusal.
pub fn failure(failure: Failure) -> Term {
  ffi_term.coerce(#("error", failure.code, failure.detail))
}

/// The answer to `ping`: who is answering and for how long it has been up.
pub fn pong(
  boot_id: String,
  node: String,
  otp_release: String,
  uptime_ms: Int,
  pins: Int,
  probes: Int,
) -> Term {
  ffi_term.coerce(#("pong", boot_id, node, otp_release, uptime_ms, pins, probes))
}

/// The answer to `memory`: the VM's categories in bytes plus the facts
/// needed to read them.
pub fn memory(
  categories: List(#(String, Int)),
  word_size: Int,
  process_count: Int,
  otp_release: String,
  erts_version: String,
  schedulers_online: Int,
) -> Term {
  ffi_term.coerce(#(
    "memory",
    categories,
    word_size,
    process_count,
    otp_release,
    erts_version,
    schedulers_online,
  ))
}

/// The answer to `census`.
pub fn census(report: census.Report) -> Term {
  let coverage = report.coverage

  ffi_term.coerce(#(
    "census",
    #(
      coverage.scanned,
      coverage.total,
      census.stop_name(coverage.stop),
      coverage.elapsed_ms,
    ),
    seq.map(report.rows, row),
    seq.map(report.aggregates, aggregate),
  ))
}

fn row(row: census.Row) -> Term {
  ffi_term.coerce(#(
    ffi_term.pid_text(row.pid),
    row.memory,
    row.total_heap_words,
    row.heap_words,
    row.stack_words,
    row.queue_length,
    row.reductions,
    ffi_term.atom_name(row.status),
    census.function_text(row.function),
    census.name_text(row.name),
    owner(row.owner),
  ))
}

fn aggregate(aggregate: census.Aggregate) -> Term {
  ffi_term.coerce(#(
    owner(aggregate.owner),
    aggregate.processes,
    aggregate.memory,
    aggregate.queue_length,
    aggregate.reductions,
  ))
}

fn owner(owner: Owner) -> Term {
  case owner {
    Unknown -> ffi_term.coerce(#("unknown"))
    Owned(path, role) -> ffi_term.coerce(#("owner", pairs(path), role))
  }
}

fn pairs(path: List(#(String, String))) -> List(Term) {
  seq.map(path, fn(pair) { ffi_term.coerce(pair) })
}

/// The answer to `pin`.
pub fn pinned(boot_id: String, pin_id: Int, pid_text: String) -> Term {
  ffi_term.coerce(#("pinned", boot_id, pin_id, pid_text))
}

/// The answer to `unpin`.
pub fn unpinned(pin_id: Int) -> Term {
  ffi_term.coerce(#("unpinned", pin_id))
}

/// The answer to `scheduler`: whether the agent holds the accounting flag
/// and the current readings, `{SchedulerId, Active, Total}` in the VM's
/// native time unit. The list is empty when no process has the flag on.
pub fn scheduler(collecting: String, readings: List(#(Int, Int, Int))) -> Term {
  ffi_term.coerce(#("scheduler", collecting, readings))
}

/// The answer to `start_counters`.
pub fn counters_started(
  probe_id: Int,
  matched_functions: Int,
  deadline_ms: Int,
) -> Term {
  ffi_term.coerce(#(
    "counters_started",
    probe_id,
    matched_functions,
    deadline_ms,
  ))
}

/// The answer to `read_counters` and `stop_counters`: the probe's state
/// (`running`, `finished` or `stopped`) and what it measured.
pub fn counters(
  probe_id: Int,
  state: String,
  matched_functions: Int,
  elapsed_ms: Int,
  snapshot: counters.Snapshot,
) -> Term {
  ffi_term.coerce(#(
    "counters",
    probe_id,
    state,
    matched_functions,
    elapsed_ms,
    #(snapshot.functions, snapshot.with_calls, snapshot.invalidated),
    seq.map(snapshot.rows, counter_row),
  ))
}

fn counter_row(row: counters.Row) -> Term {
  ffi_term.coerce(#(row.module, row.function, row.arity, row.calls, row.time_us))
}

/// The answer to `detach`, sent after every session is destroyed.
pub fn detached(reason: String) -> Term {
  ffi_term.coerce(#("detached", reason))
}
