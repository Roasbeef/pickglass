//// Generators for the core data model, shared by its property tests.
////
//// Each generator produces only values the domain accepts (a segment with a
//// valid kind, a digest with 64 hex characters), so a round-trip property
//// is about the codec and not about rejected input. Inputs that must be
//// rejected are written out by hand in the tests that need them.

import gleam/list
import gleam/option.{None, Some}
import pickglass_core/capture.{type Record}
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/provenance
import pickglass_core/readings
import pickglass_core/unit
import pickglass_core/wire
import qcheck.{type Generator}

/// Run a property over 200 generated cases. Records are large, so this is
/// fewer than the library default.
pub fn check(generator: Generator(a), property: fn(a) -> Nil) -> Nil {
  qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(200),
    generator,
    property,
  )
}

/// A generator choosing uniformly from a non-empty list.
pub fn one_of(first: a, rest: List(a)) -> Generator(a) {
  qcheck.from_generators(
    qcheck.constant(first),
    list.map(rest, qcheck.constant),
  )
}

/// Any string, including unusual unicode.
pub fn text() -> Generator(String) {
  qcheck.string()
}

/// A short non-empty alphanumeric identifier.
pub fn ident() -> Generator(String) {
  qcheck.non_empty_string_from(qcheck.alphanumeric_ascii_codepoint())
}

pub fn non_negative() -> Generator(Int) {
  qcheck.small_non_negative_int()
}

pub fn positive() -> Generator(Int) {
  qcheck.small_strictly_positive_int()
}

pub fn tuple2(a: Generator(a), b: Generator(b)) -> Generator(#(a, b)) {
  qcheck.tuple2(a, b)
}

pub fn tuple3(
  a: Generator(a),
  b: Generator(b),
  c: Generator(c),
) -> Generator(#(a, b, c)) {
  qcheck.tuple3(a, b, c)
}

pub fn small_list(of generator: Generator(a)) -> Generator(List(a)) {
  qcheck.generic_list(generator, qcheck.bounded_int(0, 4))
}

pub fn unit() -> Generator(unit.Unit) {
  qcheck.from_generators(
    one_of(unit.Bytes, [unit.Count, unit.Reductions, unit.Nanoseconds]),
    [qcheck.map(positive(), fn(per) { unit.Ratio(per:) })],
  )
}

pub fn missing_reason() -> Generator(measure.MissingReason) {
  case measure.all_missing_reasons {
    [first, ..rest] -> one_of(first, rest)
    [] -> qcheck.constant(measure.DecodeFailed)
  }
}

pub fn measurement() -> Generator(measure.Measurement) {
  qcheck.from_generators(
    qcheck.map(qcheck.uniform_int(), fn(value) { measure.Known(value:) }),
    [
      qcheck.map(missing_reason(), fn(reason) { measure.Missing(reason:) }),
      qcheck.constant(measure.NotApplicable),
    ],
  )
}

pub fn additivity() -> Generator(measure.Additivity) {
  qcheck.from_generators(qcheck.constant(measure.Additive), [
    qcheck.map(text(), fn(why) { measure.Overlapping(why:) }),
  ])
}

pub fn cadence() -> Generator(measure.Cadence) {
  qcheck.from_generators(qcheck.constant(measure.OneShot), [
    qcheck.map(positive(), fn(interval_ms) { measure.EveryMs(interval_ms:) }),
  ])
}

pub fn series() -> Generator(measure.Series) {
  use id <- qcheck.bind(non_negative())
  use kind <- qcheck.bind(
    one_of(measure.Gauge, [measure.Counter, measure.DeltaOverInterval]),
  )
  use u <- qcheck.bind(unit())
  use additivity <- qcheck.bind(additivity())
  use method <- qcheck.bind(text())
  use scope <- qcheck.bind(
    one_of(measure.NodeScope, [
      measure.ProcessScope,
      measure.OwnerScope,
      measure.OsProcessScope,
    ]),
  )
  use subject <- qcheck.bind(text())
  use cadence <- qcheck.map(cadence())

  measure.Series(
    id:,
    kind:,
    unit: u,
    additivity:,
    method:,
    scope:,
    subject:,
    cadence:,
  )
}

pub fn truncation() -> Generator(measure.TruncationReason) {
  one_of(measure.TopKLimit, [
    measure.BudgetReached,
    measure.DeadlineHit,
    measure.RingOverflow,
    measure.ScanLimit,
    measure.CollectorOverrun,
  ])
}

pub fn outcome() -> Generator(measure.Outcome) {
  qcheck.from_generators(qcheck.constant(measure.Complete), [
    qcheck.map(
      qcheck.from_generators(
        one_of(measure.NoFooter, [measure.FooterCountMismatch]),
        [qcheck.map(truncation(), fn(reason) { measure.Truncated(reason:) })],
      ),
      fn(reason) { measure.Partial(reason:) },
    ),
    qcheck.map(text(), fn(reason) { measure.Refused(reason:) }),
    qcheck.map(text(), fn(reason) { measure.Errored(reason:) }),
    qcheck.constant(measure.Unrecorded),
  ])
}

pub fn coverage() -> Generator(measure.Coverage) {
  use scope <- qcheck.bind(text())
  use requested <- qcheck.bind(non_negative())
  use achieved <- qcheck.bind(non_negative())
  use outcome <- qcheck.bind(outcome())
  use dropped_events <- qcheck.bind(measurement())
  use in_flight_events <- qcheck.bind(measurement())
  use unscanned_bytes <- qcheck.map(measurement())

  measure.Coverage(
    scope:,
    requested:,
    achieved:,
    outcome:,
    dropped_events:,
    in_flight_events:,
    unscanned_bytes:,
  )
}

pub fn boot_id() -> Generator(identity.BootId) {
  qcheck.map(ident(), fn(text) {
    case identity.boot_id(text) {
      Ok(boot) -> boot
      Error(Nil) -> identity.unknown_boot
    }
  })
}

pub fn pin(boot: identity.BootId) -> Generator(identity.PinToken) {
  qcheck.map(non_negative(), fn(serial) {
    case identity.pin(boot, serial) {
      Ok(token) -> token
      Error(Nil) -> panic as "a non-negative serial is always accepted"
    }
  })
}

pub fn incarnation() -> Generator(identity.NodeIncarnation) {
  use node_digest <- qcheck.bind(text())
  use creation <- qcheck.bind(non_negative())
  use boot <- qcheck.map(boot_id())

  identity.NodeIncarnation(node_digest:, creation:, boot:)
}

pub fn start_identity() -> Generator(identity.StartIdentity) {
  qcheck.from_generators(qcheck.constant(identity.UnreadableStart), [
    qcheck.map(text(), fn(token) { identity.PreciseStart(token:) }),
    qcheck.map(text(), fn(token) { identity.CoarseStart(token:) }),
  ])
}

pub fn os_process() -> Generator(identity.OsProcess) {
  qcheck.map2(non_negative(), start_identity(), fn(pid, start) {
    identity.OsProcess(pid:, start:)
  })
}

pub fn segment() -> Generator(owner.Segment) {
  qcheck.map2(ident(), ident(), fn(kind, id) { owner.Segment(kind:, id:) })
}

pub fn source() -> Generator(owner.Source) {
  one_of(owner.Declared, [owner.Provider, owner.Registry, owner.Supervision])
}

pub fn confidence() -> Generator(owner.Confidence) {
  one_of(owner.Low, [owner.Medium, owner.High])
}

pub fn claim() -> Generator(owner.Claim) {
  use path <- qcheck.bind(small_list(segment()))
  use role <- qcheck.bind(text())
  use source <- qcheck.bind(source())
  use confidence <- qcheck.map(confidence())

  owner.Claim(path:, role:, source:, confidence:)
}

pub fn provenance() -> Generator(provenance.Provenance) {
  use producer <- qcheck.bind(
    qcheck.map3(text(), text(), text(), fn(pickglass, agent, schema) {
      provenance.Producer(pickglass:, agent:, schema:)
    }),
  )
  use target <- qcheck.bind(
    qcheck.map3(incarnation(), os_process(), text(), fn(incarnation, os, role) {
      provenance.Target(incarnation:, os:, role:)
    }),
  )
  use runtime <- qcheck.bind(runtime())
  use build <- qcheck.bind(
    qcheck.map4(text(), text(), text(), text(), fn(a, b, c, d) {
      provenance.Build(application: a, version: b, revision: c, compiler: d)
    }),
  )
  use workload <- qcheck.bind(workload())
  use collection <- qcheck.map(collection())

  provenance.Provenance(
    producer:,
    target:,
    runtime:,
    build:,
    workload:,
    collection:,
  )
}

pub fn runtime() -> Generator(provenance.Runtime) {
  use otp_release <- qcheck.bind(text())
  use erts_version <- qcheck.bind(text())
  use emulator_flavor <- qcheck.bind(text())
  use wordsize <- qcheck.bind(positive())
  use schedulers <- qcheck.bind(positive())
  use dirty_cpu_schedulers <- qcheck.bind(maybe(non_negative()))
  use flags <- qcheck.map(small_list(text()))

  provenance.Runtime(
    otp_release:,
    erts_version:,
    emulator_flavor:,
    wordsize:,
    schedulers:,
    dirty_cpu_schedulers:,
    flags:,
  )
}

pub fn workload() -> Generator(provenance.Workload) {
  use label <- qcheck.bind(text())
  use sessions <- qcheck.bind(small_list(qcheck.tuple2(text(), non_negative())))
  use warmup_ms <- qcheck.bind(maybe(non_negative()))
  use notes <- qcheck.map(text())

  provenance.Workload(label:, sessions:, warmup_ms:, notes:)
}

pub fn collection() -> Generator(provenance.Collection) {
  use method <- qcheck.bind(text())
  use cadence <- qcheck.bind(cadence())
  use top_k <- qcheck.bind(non_negative())
  use max_events <- qcheck.bind(maybe(non_negative()))
  use deadline_ms <- qcheck.map(non_negative())

  provenance.Collection(
    method:,
    cadence:,
    budgets: provenance.Budgets(top_k:, max_events:, deadline_ms:),
  )
}

pub fn audit_entry() -> Generator(policy.AuditEntry) {
  use at_ms <- qcheck.bind(non_negative())
  use stage <- qcheck.bind(
    one_of(policy.AuthorizeStage, [policy.PlanStage, policy.ConfirmStage]),
  )
  use principal <- qcheck.bind(text())
  use command <- qcheck.bind(text())
  use decision <- qcheck.map(
    qcheck.from_generators(qcheck.constant(policy.Allowed), [
      qcheck.map(text(), fn(reason) { policy.Denied(reason:) }),
    ]),
  )

  policy.AuditEntry(at_ms:, stage:, principal:, command:, decision:)
}

pub fn digest() -> Generator(capture.Digest) {
  qcheck.map(
    qcheck.fixed_length_string_from(
      qcheck.codepoint_from_strings("0", [
        "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e",
        "f",
      ]),
      64,
    ),
    fn(hex) {
      case capture.digest(hex) {
        Ok(digest) -> digest
        Error(Nil) -> panic as "64 hex characters are always a digest"
      }
    },
  )
}

fn maybe(generator: Generator(a)) -> Generator(option.Option(a)) {
  qcheck.option_from(generator)
}

pub fn header() -> Generator(capture.Header) {
  use capture_id <- qcheck.bind(text())
  use provenance <- qcheck.bind(provenance())
  use redaction <- qcheck.map(text())

  capture.Header(capture_id:, provenance:, redaction:)
}

/// A generator of records of every kind but the header and footer, with a
/// string profile payload.
pub fn record() -> Generator(Record(String)) {
  qcheck.from_generators(clock_record(), [
    qcheck.map(
      qcheck.map2(non_negative(), small_list(text()), fn(base, values) {
        capture.Strings(base:, values:)
      }),
      capture.StringsRecord,
    ),
    owner_record(),
    proc_record(),
    function_record(),
    qcheck.map(
      qcheck.map2(non_negative(), small_list(non_negative()), fn(id, frames) {
        capture.Stack(id:, frames:)
      }),
      capture.StackRecord,
    ),
    qcheck.map(series(), capture.SeriesRecord),
    samples_record(),
    qcheck.map(
      qcheck.map3(
        non_negative(),
        one_of(capture.SampledStacks, [
          capture.TracedCalls,
          capture.TracedCounters,
          capture.AllocationCounts,
        ]),
        text(),
        fn(id, source, payload) { capture.Profile(id:, source:, payload:) },
      ),
      capture.ProfileRecord,
    ),
    events_record(),
    qcheck.map(coverage(), capture.CoverageRecord),
    qcheck.map(
      qcheck.map3(text(), non_negative(), non_negative(), fn(name, a, b) {
        capture.Checkpoint(name:, agent_monotonic_ns: a, system_ms: b)
      }),
      capture.CheckpointRecord,
    ),
    cost_record(),
    qcheck.map(audit_entry(), capture.AuditRecord),
    owners_detail_record(),
    ets_record(),
    binaries_record(),
  ])
}

fn owner_reading() -> Generator(wire.OwnerReading) {
  qcheck.from_generators(qcheck.constant(wire.Unlabelled), [
    qcheck.map2(small_list(segment()), ident(), fn(path, role) {
      wire.Labelled(path:, role:)
    }),
  ])
}

fn ets_stop() -> Generator(wire.EtsStop) {
  one_of(wire.EtsFinished, [wire.EtsDeadline])
}

fn owners_detail_record() -> Generator(Record(String)) {
  use at_ms <- qcheck.bind(non_negative())
  use initial_calls <- qcheck.bind(
    small_list(qcheck.map2(text(), text(), fn(pid, call) { #(pid, call) })),
  )
  use owners <- qcheck.bind(
    small_list(
      qcheck.map3(
        owner_reading(),
        non_negative(),
        non_negative(),
        fn(owner, tables, bytes) { readings.OwnerEts(owner:, tables:, bytes:) },
      ),
    ),
  )
  use tables <- qcheck.bind(non_negative())
  use memory_bytes <- qcheck.bind(non_negative())
  use skipped <- qcheck.bind(non_negative())
  use stop <- qcheck.map(ets_stop())

  capture.OwnersDetailRecord(readings.OwnersDetail(
    at_ms:,
    initial_calls:,
    owners:,
    ets: wire.EtsPass(tables:, memory_bytes:, skipped:, stop:),
  ))
}

fn ets_table() -> Generator(wire.EtsTable) {
  use id_text <- qcheck.bind(text())
  use name <- qcheck.bind(text())
  use owner_pid_text <- qcheck.bind(text())
  use owner <- qcheck.bind(owner_reading())
  use kind <- qcheck.bind(ident())
  use objects <- qcheck.bind(non_negative())
  use memory_bytes <- qcheck.bind(non_negative())
  use protection <- qcheck.bind(ident())
  use heir_pid_text <- qcheck.bind(text())
  use owner_name <- qcheck.map(text())

  wire.EtsTable(
    id_text:,
    name:,
    owner_pid_text:,
    owner:,
    owner_name:,
    kind:,
    objects:,
    memory_bytes:,
    protection:,
    heir_pid_text:,
  )
}

fn ets_record() -> Generator(Record(String)) {
  use at_ms <- qcheck.bind(non_negative())
  use total <- qcheck.bind(non_negative())
  use counted <- qcheck.bind(non_negative())
  use skipped <- qcheck.bind(non_negative())
  use stop <- qcheck.bind(ets_stop())
  use elapsed_ms <- qcheck.bind(non_negative())
  use tables <- qcheck.bind(small_list(ets_table()))
  use objects <- qcheck.bind(non_negative())
  use memory_bytes <- qcheck.map(non_negative())

  capture.EtsRecord(readings.EtsListing(
    at_ms:,
    snapshot: wire.EtsSnapshot(
      coverage: wire.EtsCoverage(total:, counted:, skipped:, stop:, elapsed_ms:),
      tables:,
      totals: wire.EtsTotals(
        tables: list.length(tables),
        objects:,
        memory_bytes:,
      ),
    ),
  ))
}

fn binaries_record() -> Generator(Record(String)) {
  use at_ms <- qcheck.bind(non_negative())
  use pid_text <- qcheck.bind(text())
  use distinct <- qcheck.bind(non_negative())
  use bytes <- qcheck.bind(non_negative())
  use references <- qcheck.bind(non_negative())
  use binaries <- qcheck.map(
    small_list(
      qcheck.map3(
        text(),
        non_negative(),
        non_negative(),
        fn(address_text, bytes, refc) {
          wire.BinaryRef(address_text:, bytes:, refc:)
        },
      ),
    ),
  )

  capture.BinariesRecord(readings.BinariesReading(
    at_ms:,
    snapshot: wire.BinariesSnapshot(
      pid_text:,
      distinct:,
      bytes:,
      references:,
      binaries:,
    ),
  ))
}

fn clock_record() -> Generator(Record(String)) {
  qcheck.map(
    qcheck.map4(
      non_negative(),
      non_negative(),
      non_negative(),
      non_negative(),
      fn(a, b, c, d) {
        capture.Clock(
          agent_monotonic_ns: a,
          agent_system_ms: b,
          viewer_system_ms: c,
          round_trip_ns: d,
        )
      },
    ),
    capture.ClockRecord,
  )
}

fn owner_record() -> Generator(Record(String)) {
  use id <- qcheck.bind(non_negative())
  use kind <- qcheck.bind(text())
  use display <- qcheck.bind(non_negative())
  use parent <- qcheck.bind(maybe(non_negative()))
  use source <- qcheck.map(source())

  capture.OwnerRecord(capture.OwnerDef(id:, kind:, display:, parent:, source:))
}

fn proc_record() -> Generator(Record(String)) {
  use ref <- qcheck.bind(non_negative())
  use pid_text <- qcheck.bind(text())
  use birth_epoch <- qcheck.bind(non_negative())
  use first_seen_ms <- qcheck.bind(non_negative())
  use owner <- qcheck.bind(maybe(non_negative()))
  use registered_name <- qcheck.bind(maybe(text()))
  use initial_call <- qcheck.map(maybe(non_negative()))

  capture.ProcRecord(capture.Proc(
    ref:,
    pid_text:,
    birth_epoch:,
    first_seen_ms:,
    owner:,
    registered_name:,
    initial_call:,
  ))
}

fn function_record() -> Generator(Record(String)) {
  use id <- qcheck.bind(non_negative())
  use module <- qcheck.bind(text())
  use function <- qcheck.bind(text())
  use arity <- qcheck.bind(non_negative())
  use file <- qcheck.bind(maybe(text()))
  use line <- qcheck.bind(maybe(non_negative()))
  use precision <- qcheck.map(
    one_of(capture.ExactLine, [capture.FunctionLevel, capture.NoLine]),
  )

  capture.FunctionRecord(capture.FunctionDef(
    id:,
    module:,
    function:,
    arity:,
    file:,
    line:,
    precision:,
  ))
}

fn samples_record() -> Generator(Record(String)) {
  use series <- qcheck.bind(non_negative())
  use rows <- qcheck.map(
    small_list(qcheck.tuple3(non_negative(), non_negative(), measurement())),
  )

  capture.SamplesRecord(capture.Samples(
    series:,
    timestamps_ms: list.map(rows, fn(row) { row.0 }),
    intervals_ms: list.map(rows, fn(row) { row.1 }),
    values: list.map(rows, fn(row) { row.2 }),
  ))
}

fn events_record() -> Generator(Record(String)) {
  use track <- qcheck.bind(non_negative())
  use kind <- qcheck.bind(text())
  use timestamps_ms <- qcheck.bind(small_list(non_negative()))
  use durations_ms <- qcheck.bind(small_list(non_negative()))
  use args <- qcheck.bind(small_list(text()))
  use traced <- qcheck.map(
    qcheck.from_generators(qcheck.constant(None), [
      qcheck.map(events_snapshot(), fn(snapshot) {
        Some(capture.SchedulingTraced(snapshot:))
      }),
      qcheck.map(calltrace_snapshot(), fn(snapshot) {
        Some(capture.CallTreeTraced(snapshot:))
      }),
    ]),
  )

  capture.EventsRecord(capture.Events(
    track:,
    kind:,
    timestamps_ms:,
    durations_ms:,
    args:,
    traced:,
  ))
}

fn probe_state() -> Generator(wire.ProbeState) {
  one_of(wire.ProbeRunning, [wire.ProbeFinished, wire.ProbeStopped])
}

fn trace_stop() -> Generator(wire.TraceStop) {
  one_of(wire.TraceRunning, [
    wire.TraceDeadline,
    wire.TraceBudget,
    wire.TraceOverrun,
    wire.TraceTargetsGone,
    wire.TraceStopped,
  ])
}

fn trace_meter() -> Generator(wire.TraceMeter) {
  use elapsed_ms <- qcheck.bind(non_negative())
  use events <- qcheck.bind(non_negative())
  use max_events <- qcheck.bind(non_negative())
  use dropped_events <- qcheck.bind(non_negative())
  use in_flight_at_stop <- qcheck.bind(non_negative())
  use peak_queue <- qcheck.bind(non_negative())
  use queue_limit <- qcheck.bind(non_negative())
  use targets_gone <- qcheck.map(non_negative())

  wire.TraceMeter(
    elapsed_ms:,
    events:,
    max_events:,
    dropped_events:,
    in_flight_at_stop:,
    peak_queue:,
    queue_limit:,
    targets_gone:,
  )
}

/// A scheduling and garbage collection probe's result.
pub fn events_snapshot() -> Generator(wire.EventsSnapshot) {
  use probe_id <- qcheck.bind(non_negative())
  use state <- qcheck.bind(probe_state())
  use stop <- qcheck.bind(trace_stop())
  use trace <- qcheck.bind(trace_meter())
  use processes <- qcheck.bind(
    small_list(qcheck.tuple3(
      text(),
      qcheck.tuple3(non_negative(), non_negative(), non_negative()),
      non_negative(),
    )),
  )
  use slices <- qcheck.bind(
    small_list(tuple3(
      one_of(wire.RunSlice, [wire.MinorGcSlice, wire.MajorGcSlice]),
      tuple2(non_negative(), non_negative()),
      non_negative(),
    )),
  )
  use long <- qcheck.map(
    small_list(
      qcheck.from_generators(
        qcheck.map(tuple3(text(), non_negative(), non_negative()), fn(t) {
          wire.LongGc(pid_text: t.0, duration_ms: t.1, heap_words: t.2)
        }),
        [
          qcheck.map(tuple3(text(), non_negative(), text()), fn(t) {
            wire.LongSchedule(pid_text: t.0, duration_ms: t.1, function: t.2)
          }),
        ],
      ),
    ),
  )
  wire.EventsSnapshot(
    probe_id:,
    state:,
    stop:,
    meter: wire.EventsMeter(
      trace:,
      unpaired_events: 1,
      dropped_slices: 2,
      long_events_seen: 3,
      strays: 4,
      long_gc_ms: 50,
      long_schedule_ms: 100,
    ),
    processes: list.map(processes, fn(p) {
      wire.TracedProcess(
        pid_text: p.0,
        runs: p.1.0,
        run_ns: p.1.1,
        minor_gcs: p.1.2,
        major_gcs: p.2,
        gc_ns: p.2 + 1,
      )
    }),
    slices: list.map(slices, fn(s) {
      wire.ActivitySlice(
        process: s.1.0 % 3,
        kind: s.0,
        start_ns: s.1.1,
        duration_ns: s.2,
      )
    }),
    long:,
  )
}

/// A call tree probe's result.
pub fn calltrace_snapshot() -> Generator(wire.CalltraceSnapshot) {
  use probe_id <- qcheck.bind(non_negative())
  use state <- qcheck.bind(probe_state())
  use stop <- qcheck.bind(trace_stop())
  use trace <- qcheck.bind(trace_meter())
  use frames <- qcheck.bind(small_list(tuple3(text(), text(), non_negative())))
  use paths <- qcheck.bind(
    small_list(tuple3(
      tuple3(non_negative(), non_negative(), non_negative()),
      small_list(non_negative()),
      non_negative(),
    )),
  )
  use processes <- qcheck.bind(small_list(text()))
  use slices <- qcheck.map(
    small_list(tuple3(
      tuple3(non_negative(), non_negative(), non_negative()),
      non_negative(),
      non_negative(),
    )),
  )

  wire.CalltraceSnapshot(
    probe_id:,
    state:,
    stop:,
    meter: wire.CalltraceMeter(
      trace:,
      forced_closes: 1,
      distinct_paths: 2,
      dropped_calls: 3,
      elided_calls: 4,
      strays: 5,
      depth_limit: 64,
    ),
    frames: list.map(frames, fn(f) {
      wire.StackFrame(
        module: f.0,
        function: f.1,
        arity: f.2,
        location: wire.NoLocation,
      )
    }),
    paths: list.map(paths, fn(p) {
      wire.CallPath(
        calls: p.0.0,
        inclusive_ns: p.0.1,
        exclusive_ns: p.0.2,
        frames: p.1,
      )
    }),
    processes:,
    slices: list.map(slices, fn(s) {
      wire.CallSlice(
        process: s.0.0,
        frame: s.0.1,
        start_ns: s.0.2,
        duration_ns: s.1,
        depth: s.2,
      )
    }),
  )
}

fn counter_facts() -> Generator(capture.CounterFacts) {
  use requested_ms <- qcheck.bind(non_negative())
  use processes <- qcheck.bind(maybe(non_negative()))
  use called <- qcheck.bind(non_negative())
  use read <- qcheck.bind(non_negative())
  use unread <- qcheck.bind(non_negative())
  use invalidated <- qcheck.bind(non_negative())
  use total_words <- qcheck.map(non_negative())

  capture.CounterFacts(
    requested_ms:,
    processes:,
    called:,
    read:,
    unread:,
    invalidated:,
    total_words:,
  )
}

fn cost_record() -> Generator(Record(String)) {
  use probe <- qcheck.bind(text())
  use enabled <- qcheck.bind(small_list(text()))
  use events <- qcheck.bind(measurement())
  use collector_reductions <- qcheck.bind(measurement())
  use bytes <- qcheck.bind(measurement())
  use wall_ms <- qcheck.bind(measurement())
  use outcome <- qcheck.bind(outcome())
  use matched <- qcheck.bind(maybe(non_negative()))
  use counters <- qcheck.map(maybe(counter_facts()))

  capture.ProbeCostRecord(capture.ProbeCost(
    probe:,
    enabled:,
    events:,
    collector_reductions:,
    bytes:,
    wall_ms:,
    outcome:,
    matched:,
    counters:,
  ))
}

/// A fixed, plausible provenance for tests that need one value.
pub fn sample_provenance() -> provenance.Provenance {
  let assert Ok(boot) = identity.boot_id("aaaa") as "valid boot id"

  provenance.Provenance(
    producer: provenance.Producer("0.1.0", "0.1.0", "pickglass.capture/1"),
    target: provenance.Target(
      incarnation: identity.NodeIncarnation("digest", 1, boot),
      os: identity.OsProcess(100, identity.PreciseStart("t")),
      role: "loomd",
    ),
    runtime: provenance.Runtime(
      otp_release: "29",
      erts_version: "17.0",
      emulator_flavor: "jit",
      wordsize: 8,
      schedulers: 8,
      dirty_cpu_schedulers: Some(8),
      flags: ["+Muatags true", "+JPperf true"],
    ),
    build: provenance.Build("loom", "1.0", "abc123", "1.18"),
    workload: provenance.Workload(
      "idle-12",
      [#("sessions", 12)],
      Some(300_000),
      "",
    ),
    collection: provenance.Collection(
      method: "census/processes_iterator",
      cadence: measure.EveryMs(10_000),
      budgets: provenance.Budgets(
        top_k: 100,
        max_events: Some(1000),
        deadline_ms: 5000,
      ),
    ),
  )
}
