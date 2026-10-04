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

import pickglass_agent/activity
import pickglass_agent/calltree
import pickglass_agent/census
import pickglass_agent/counters
import pickglass_agent/detail
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Reference, type Term}
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner, Owned, Unknown}
import pickglass_agent/request
import pickglass_agent/stacks
import pickglass_agent/supervision
import pickglass_agent/system
import pickglass_agent/tracing

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

/// The answer to `census`. The shape is the first wire release's and does
/// not change: an owner aggregate has five fields and there are no totals.
pub fn census(report: census.Report) -> Term {
  ffi_term.coerce(#(
    "census",
    coverage(report.coverage),
    seq.map(report.rows, row),
    seq.map(report.aggregates, aggregate),
  ))
}

/// The answer to `owners`: the census with each owner's heap capacity and the
/// totals over every scanned process, which is what lets a view say how much
/// the listed owners leave out.
pub fn owners(report: census.Report) -> Term {
  ffi_term.coerce(#(
    "owners",
    coverage(report.coverage),
    seq.map(report.rows, row),
    seq.map(report.aggregates, detailed_aggregate),
    totals(report.totals),
  ))
}

fn coverage(coverage: census.Coverage) -> Term {
  ffi_term.coerce(#(
    coverage.scanned,
    coverage.total,
    census.stop_name(coverage.stop),
    coverage.elapsed_ms,
  ))
}

fn totals(totals: census.Totals) -> Term {
  ffi_term.coerce(#(
    totals.processes,
    totals.memory,
    totals.queue_length,
    totals.reductions,
    totals.total_heap_words,
    totals.owners_tracked,
    totals.owners_listed,
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

fn detailed_aggregate(aggregate: census.Aggregate) -> Term {
  ffi_term.coerce(#(
    owner(aggregate.owner),
    aggregate.processes,
    aggregate.memory,
    aggregate.queue_length,
    aggregate.reductions,
    aggregate.total_heap_words,
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

/// The answer to `read_counter_memory`: the probe's state and, for a probe
/// that counted allocation, the words each function allocated. A probe that
/// did not is `{<<"none">>}`, which is not a list of zeros.
pub fn counter_memory(
  probe_id: Int,
  state: String,
  snapshot: counters.Snapshot,
) -> Term {
  ffi_term.coerce(
    #("counter_memory", probe_id, state, case snapshot.memory {
      counters.NotCounted -> ffi_term.coerce(#("none"))
      counters.Counted(rows) ->
        ffi_term.coerce(#("words", seq.map(rows, memory_row)))
    }),
  )
}

fn memory_row(row: counters.MemoryRow) -> Term {
  ffi_term.coerce(#(row.module, row.function, row.arity, row.words))
}

/// The answer to `detach`, sent after every session is destroyed.
pub fn detached(reason: String) -> Term {
  ffi_term.coerce(#("detached", reason))
}

/// The answer to `process_detail`: sizes, activity, collection settings,
/// relations and owner. Sizes are bytes; the function texts are
/// `module:function/arity` or empty.
pub fn process_detail(found: detail.Detail) -> Term {
  let heap = found.heap
  let gc = found.gc
  let relations = found.relations

  ffi_term.coerce(#(
    "process_detail",
    ffi_term.pid_text(found.pid),
    #(
      heap.memory_bytes,
      heap.total_heap_bytes,
      heap.heap_bytes,
      heap.stack_bytes,
    ),
    #(
      found.queue_length,
      found.reductions,
      ffi_term.atom_name(found.status),
      census.function_text(found.current_function),
      census.function_text(found.initial_call),
      census.name_text(found.registered_name),
    ),
    #(
      gc.minor_gcs,
      gc.fullsweep_after,
      gc.min_heap_bytes,
      gc.max_heap_bytes,
      heap.heap_block_bytes,
      heap.old_heap_bytes,
      heap.old_heap_block_bytes,
      heap.mbuf_bytes,
      heap.bin_vheap_bytes,
    ),
    #(
      relations.links,
      relations.monitors,
      relations.monitored_by,
      relations.parent,
    ),
    owner(found.owner),
    found.capabilities,
  ))
}

/// The answer to `supervision`: the coverage and one `{Child, Parent, Name,
/// InitialCall, Owner}` edge per process the walk reached.
pub fn supervision(report: supervision.Report) -> Term {
  let coverage = report.coverage

  ffi_term.coerce(#(
    "supervision",
    #(
      coverage.scanned,
      coverage.total,
      supervision.stop_name(coverage.stop),
      coverage.elapsed_ms,
    ),
    seq.map(report.edges, edge),
  ))
}

fn edge(edge: supervision.Edge) -> Term {
  ffi_term.coerce(#(
    ffi_term.pid_text(edge.pid),
    edge.parent,
    census.name_text(edge.registered_name),
    census.function_text(edge.initial_call),
    owner(edge.owner),
  ))
}

/// The answer to `system`: the node's facts, and its allocator carriers or
/// the reason they are unavailable.
pub fn system(report: system.Report) -> Term {
  let facts = report.facts

  ffi_term.coerce(#(
    "system",
    #(
      facts.uptime_ms,
      facts.creation,
      facts.emulator_flavor,
      facts.emulator_type,
      facts.erts_version,
      facts.otp_release,
      facts.schedulers,
      facts.schedulers_online,
      facts.dirty_cpu,
      facts.dirty_cpu_online,
      facts.dirty_io,
      facts.word_size,
    ),
    carriers(report.carriers),
  ))
}

fn carriers(carriers: system.Carriers) -> Term {
  case carriers {
    system.Unavailable(reason) -> ffi_term.coerce(#("unavailable", reason))
    system.Available(rows) ->
      ffi_term.coerce(#("carriers", seq.map(rows, carrier_row)))
  }
}

fn carrier_row(row: system.CarrierRow) -> Term {
  ffi_term.coerce(#(
    row.allocator,
    case row.pool {
      system.InPool -> True
      system.NotInPool -> False
    },
    row.carriers,
    row.total_bytes,
    row.used_bytes,
    row.unscanned_bytes,
  ))
}

/// The answer to `measure`: the target, how long it took to answer and its
/// readings, already validated by `measure.valid_readings`.
pub fn measured(pid_text: String, elapsed_ms: Int, readings: Term) -> Term {
  ffi_term.coerce(#("measure", pid_text, elapsed_ms, readings))
}

/// The answer to `gc`: whether the collection finished, how long it took and
/// the process's heap before and after. A reading is `Error(Nil)` when the
/// process could not be read, which is how a process that exited during the
/// collection shows. The class is always `intrusive`: the target stops while
/// it collects.
pub fn collection(
  pid_text: String,
  outcome: String,
  elapsed_ms: Int,
  before: Result(detail.Heap, Nil),
  after: Result(detail.Heap, Nil),
) -> Term {
  ffi_term.coerce(#(
    "gc",
    "intrusive",
    pid_text,
    outcome,
    elapsed_ms,
    heap_reading(before),
    heap_reading(after),
  ))
}

fn heap_reading(reading: Result(detail.Heap, Nil)) -> Term {
  case reading {
    Error(Nil) -> ffi_term.coerce(#("gone"))
    Ok(heap) ->
      ffi_term.coerce(#(
        "heap",
        heap.memory_bytes,
        heap.total_heap_bytes,
        heap.heap_bytes,
        heap.heap_block_bytes,
        heap.old_heap_bytes,
        heap.old_heap_block_bytes,
        heap.mbuf_bytes,
        heap.stack_bytes,
        heap.bin_vheap_bytes,
      ))
  }
}

/// The answer to `start_stacks`, with the rate, duration and budget the
/// agent settled on after clamping.
pub fn stacks_started(
  probe_id: Int,
  targets: Int,
  rate_hz: Int,
  duration_ms: Int,
  max_samples: Int,
) -> Term {
  ffi_term.coerce(#(
    "stacks_started",
    probe_id,
    targets,
    rate_hz,
    duration_ms,
    max_samples,
  ))
}

/// How a stack probe sampled, as the sampler measured it.
pub type Meter {
  Meter(
    requested_hz: Int,
    achieved_millihz: Int,
    rounds: Int,
    samples: Int,
    elapsed_ms: Int,
    depth_limit: Int,
    at_depth_limit: Int,
    targets_gone: Int,
    dropped_samples: Int,
    distinct_stacks: Int,
  )
}

/// The answer to `read_stacks` and `stop_stacks`. `phase` is `running`,
/// `finished` or `stopped`, and `why` the reason sampling ended.
pub fn stacks(
  probe_id: Int,
  phase: String,
  why: stacks.Stop,
  meter: Meter,
  built: stacks.Built,
) -> Term {
  ffi_term.coerce(#(
    "stacks",
    probe_id,
    phase,
    stacks.stop_name(why),
    #(
      "polled_current_stacktrace",
      meter.requested_hz,
      meter.achieved_millihz,
      meter.rounds,
      meter.samples,
      meter.elapsed_ms,
      meter.depth_limit,
      meter.at_depth_limit,
      meter.targets_gone,
      meter.dropped_samples,
      meter.distinct_stacks,
      built.truncated_samples,
    ),
    seq.map(built.frames, frame),
    seq.map(built.stacks, fn(entry) {
      ffi_term.coerce(#(entry.count, entry.status, entry.frames))
    }),
  ))
}

fn frame(frame: stacks.Frame) -> Term {
  ffi_term.coerce(
    #(frame.module, frame.function, frame.arity, case frame.location {
      stacks.NoLocation -> ffi_term.coerce(#("none"))
      stacks.FileOnly(file) -> ffi_term.coerce(#("file", file))
      stacks.At(file, line) -> ffi_term.coerce(#("at", file, line))
    }),
  )
}

/// The answer to `start_calltrace`, with the values the agent settled on
/// after clamping. `matched_functions` is how many functions the patterns
/// armed.
pub fn calltrace_started(
  probe_id: Int,
  targets: Int,
  matched_functions: Int,
  duration_ms: Int,
  max_events: Int,
  timeline_limit: Int,
) -> Term {
  ffi_term.coerce(#(
    "calltrace_started",
    probe_id,
    targets,
    matched_functions,
    duration_ms,
    max_events,
    timeline_limit,
  ))
}

/// The answer to `read_calltrace` and `stop_calltrace`. `phase` is `running`,
/// `finished` or `stopped`, and `why` the reason tracing ended. Frames have
/// the shape of the stack probe's, with no location, so a viewer reads both
/// with one decoder; a path is `{Calls, InclusiveNs, ExclusiveNs, [Frame]}`
/// with its frames leaf first; the timeline is the targets' pid texts and
/// then `{Process, Frame, StartNs, DurationNs, Depth}` slices.
pub fn calltrace(
  probe_id: Int,
  phase: String,
  why: tracing.Stop,
  meter: tracing.Meter,
  built: calltree.Built,
) -> Term {
  ffi_term.coerce(#(
    "calltrace",
    probe_id,
    phase,
    tracing.stop_name(why),
    #(
      "traced_call_return_to",
      meter.elapsed_ms,
      meter.events,
      meter.max_events,
      meter.dropped_events,
      meter.in_flight_at_stop,
      meter.peak_queue,
      meter.queue_limit,
      meter.targets_gone,
      built.forced_closes,
      built.distinct_paths,
      built.dropped_calls,
      built.elided_calls,
      built.strays,
      calltree.max_depth,
    ),
    seq.map(built.frames, frame),
    seq.map(built.paths, fn(path) {
      ffi_term.coerce(#(
        path.calls,
        path.inclusive_ns,
        path.exclusive_ns,
        path.frames,
      ))
    }),
    #(
      built.processes,
      seq.map(built.timeline, fn(moment) {
        ffi_term.coerce(#(
          moment.process,
          moment.frame,
          moment.start_ns,
          moment.duration_ns,
          moment.depth,
        ))
      }),
    ),
  ))
}

/// The answer to `start_events`, with the values the agent settled on after
/// clamping. A threshold of zero is off.
pub fn events_started(
  probe_id: Int,
  targets: Int,
  duration_ms: Int,
  max_events: Int,
  slice_limit: Int,
  long_gc_ms: Int,
  long_schedule_ms: Int,
) -> Term {
  ffi_term.coerce(#(
    "events_started",
    probe_id,
    targets,
    duration_ms,
    max_events,
    slice_limit,
    long_gc_ms,
    long_schedule_ms,
  ))
}

/// The answer to `read_events` and `stop_events`: per-target totals
/// `{Pid, Runs, RunNs, MinorGcs, MajorGcs, GcNs}`, slices `{Process, Kind,
/// StartNs, DurationNs}` with `Kind` one of `run`, `gc_minor` and `gc_major`,
/// and the node-wide threshold events, `{<<"long_gc">>, Pid, Ms, HeapWords}`
/// or `{<<"long_schedule">>, Pid, Ms, Function}`.
pub fn events(
  probe_id: Int,
  phase: String,
  why: tracing.Stop,
  meter: tracing.Meter,
  built: activity.Built,
  long_gc_ms: Int,
  long_schedule_ms: Int,
) -> Term {
  ffi_term.coerce(#(
    "events",
    probe_id,
    phase,
    tracing.stop_name(why),
    #(
      "traced_running_gc",
      meter.elapsed_ms,
      meter.events,
      meter.max_events,
      meter.dropped_events,
      meter.in_flight_at_stop,
      meter.peak_queue,
      meter.queue_limit,
      meter.targets_gone,
      built.unpaired,
      built.slices_dropped,
      built.long_seen,
      built.strays,
      long_gc_ms,
      long_schedule_ms,
    ),
    seq.map(built.totals, fn(totals) {
      ffi_term.coerce(#(
        totals.pid,
        totals.runs,
        totals.run_ns,
        totals.minor_gcs,
        totals.major_gcs,
        totals.gc_ns,
      ))
    }),
    seq.map(built.timeline, fn(moment) {
      ffi_term.coerce(#(
        moment.process,
        slice_kind(moment.kind),
        moment.start_ns,
        moment.duration_ns,
      ))
    }),
    seq.map(built.long, long_event),
  ))
}

fn slice_kind(kind: activity.SliceKind) -> String {
  case kind {
    activity.Run -> "run"
    activity.MinorGc -> "gc_minor"
    activity.MajorGc -> "gc_major"
  }
}

fn long_event(event: activity.Long) -> Term {
  case event {
    activity.SlowCollection(pid, duration_ms, heap_words) ->
      ffi_term.coerce(#("long_gc", pid, duration_ms, heap_words))
    activity.SlowTimeslice(pid, duration_ms, function) ->
      ffi_term.coerce(#("long_schedule", pid, duration_ms, function))
  }
}
