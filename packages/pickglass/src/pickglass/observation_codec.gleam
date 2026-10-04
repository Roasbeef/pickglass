//// Observations as `pickglass.capture/1` records, and back.
////
//// A capture stores readings as columns: one `series` per thing measured
//// and one `samples` record per series holding one value per observation.
//// This module is the mapping between the hub's `Observation` and that
//// shape, so that `attach --once` and a saved live window write the same
//// records, and `pickglass view` reads them back into the observations the
//// pages already draw.
////
//// What each part of an observation becomes:
////
//// - Each memory category is a node-scope gauge in bytes. The categories
////   overlap (the total includes the others), so each is declared
////   `Overlapping` and no page may add them.
//// - Each process in a census is a `proc` record, with six process-scope
////   series (memory, total heap, heap and stack in bytes, queue length,
////   reductions) and a `census_row` event that carries the strings a series
////   cannot: status, current function, owner and role. A process missing
////   from one census because it fell outside the top K has
////   `Missing(BudgetExhausted)` for that time, never a zero.
//// - Each owner is an `owner` record per path prefix, and the owners'
////   totals are owner-scope series keyed by the leaf owner id and the role.
//// - Scheduler readings are node-scope counters, and whether the agent held
////   wall-time accounting is a `scheduler_accounting` event.
//// - Each section of each pass has a `coverage` record in the order
////   memory, census, scheduler, so a section that failed reads back as the
////   same `Error` and a truncated census reads back truncated.
////
//// The reverse mapping reads rows in memory-descending order, since a
//// capture holds no ordering of its own. Fields the wire reports but a
//// capture has no place for are not guessed on the way back: a replayed
//// census row has the status and current function the event carried.
////
//// ## Flow
////
//// - `to_records` builds the records of a list of observations.
//// - `of_records` reads them back, through `index_of`, which looks up every
////   series, process, owner and event in one pass over the records.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import pickglass/observation.{type Observation, Observation}
import pickglass/os_reader
import pickglass_core/capture.{type Record}
import pickglass_core/identity
import pickglass_core/measure.{
  type Cadence, type Measurement, type MissingReason, type Series, Additive,
  Known, Missing, NotApplicable, Overlapping,
}
import pickglass_core/owner
import pickglass_core/profile.{type Profile}
import pickglass_core/unit
import pickglass_core/wire

// The unit separator joins the parts of a census row's event argument and an
// owner series' subject. It cannot appear in a pid, a status or a function
// name, and a role is the only free text after it.
const separator = "\u{1f}"

const method_memory = "erlang:memory/0"

const method_process_count = "erlang:system_info(process_count)"

const method_scheduler_active =
  "erlang:statistics(scheduler_wall_time_all):active"

const method_scheduler_total = "erlang:statistics(scheduler_wall_time_all):total"

const method_total_heap = "process_info:total_heap_size"

const method_heap = "process_info:heap_size"

const method_stack = "process_info:stack_size"

const method_memory_bytes = "process_info:memory"

const method_queue = "process_info:message_queue_len"

const method_reductions = "process_info:reductions"

const method_os_rss = "os:rss"

const method_os_anon = "os:rss_anon"

const method_os_cpu = "os:cpu_time"

const method_owner_processes = "census:owner:processes"

const method_owner_memory = "census:owner:memory"

const method_owner_queue = "census:owner:message_queue_len"

const method_owner_reductions = "census:owner:reductions"

/// What an observation says about the OS when its capture holds no OS
/// series.
pub const no_os_readings = "the capture holds no OS readings"

const kind_pass = "pass"

const kind_row = "census_row"

const kind_census = "census"

const kind_scheduler = "scheduler_accounting"

type Spec {
  Spec(
    kind: measure.SeriesKind,
    unit: unit.Unit,
    additivity: measure.Additivity,
    method: String,
    scope: measure.Scope,
    subject: String,
    value: fn(Observation) -> Measurement,
  )
}

/// The records of the observations, oldest first, without a header, clock
/// or footer. `word_size` is the target's, from its memory report.
///
/// ## Examples
///
/// ```gleam
/// observation_codec.to_records(observations, measure.OneShot, 8)
/// ```
pub fn to_records(
  observations: List(Observation),
  cadence: Cadence,
  word_size: Int,
) -> List(Record(Profile)) {
  let rows = all_rows(observations)
  let owner_table = intern_owners(rows, observations)
  let procs = proc_table(rows, owner_table)
  let specs = specs_of(observations, procs, owner_table, word_size)
  let times = list.map(observations, fn(observation) { observation.at_ms })

  list.flatten([
    [capture.StringsRecord(capture.Strings(0, owner_table.strings))],
    list.map(owner_table.defs, capture.OwnerRecord),
    list.map(procs, fn(proc) { capture.ProcRecord(proc.record) }),
    list.index_map(specs, fn(spec, index) {
      capture.SeriesRecord(series_of(spec, index + 1, cadence))
    }),
    list.index_map(specs, fn(spec, index) {
      capture.SamplesRecord(capture.Samples(
        series: index + 1,
        timestamps_ms: times,
        intervals_ms: intervals_of(times),
        values: list.map(observations, spec.value),
      ))
    }),
    event_records(observations, procs),
    list.flat_map(observations, coverage_of),
  ])
}

fn series_of(spec: Spec, id: Int, cadence: Cadence) -> Series {
  measure.Series(
    id:,
    kind: spec.kind,
    unit: spec.unit,
    additivity: spec.additivity,
    method: spec.method,
    scope: spec.scope,
    subject: spec.subject,
    cadence:,
  )
}

fn intervals_of(times: List(Int)) -> List(Int) {
  case times {
    [] -> []
    [_, ..rest] -> [
      0,
      ..list.map2(times, rest, fn(before, after) { after - before })
    ]
  }
}

// ------------------------------------------------------------------ owners

type OwnerTable {
  OwnerTable(
    strings: List(String),
    defs: List(capture.OwnerDef),
    ids: Dict(String, Int),
  )
}

// One `owner` record per distinct path prefix, so `session:a` and
// `session:a/strand:b` share the first and the second names it as parent.
fn intern_owners(
  rows: List(wire.ProcessRow),
  observations: List(Observation),
) -> OwnerTable {
  let readings =
    list.append(
      list.map(rows, fn(row) { row.owner }),
      list.flat_map(observations, fn(observation) {
        case observation.census {
          Ok(census) -> list.map(census.owners, fn(total) { total.owner })
          Error(_) -> []
        }
      }),
    )

  list.fold(readings, OwnerTable([], [], dict.new()), fn(table, reading) {
    case reading {
      wire.Unlabelled -> table
      wire.Labelled(path:, ..) -> intern_path(table, path, [], None)
    }
  })
}

fn intern_path(
  table: OwnerTable,
  remaining: List(owner.Segment),
  prefix: List(owner.Segment),
  parent: Option(Int),
) -> OwnerTable {
  case remaining {
    [] -> table
    [segment, ..rest] -> {
      let path = list.append(prefix, [segment])
      let key = owner.path_to_string(path)

      case dict.get(table.ids, key) {
        Ok(id) -> intern_path(table, rest, path, Some(id))
        Error(Nil) -> {
          let id = dict.size(table.ids) + 1
          let display = list.length(table.strings)
          let def =
            capture.OwnerDef(
              id:,
              kind: segment.kind,
              display:,
              parent:,
              source: owner.Declared,
            )

          intern_path(
            OwnerTable(
              strings: list.append(table.strings, [segment.id]),
              defs: list.append(table.defs, [def]),
              ids: dict.insert(table.ids, key, id),
            ),
            rest,
            path,
            Some(id),
          )
        }
      }
    }
  }
}

fn leaf_id(table: OwnerTable, reading: wire.OwnerReading) -> Option(Int) {
  case reading {
    wire.Unlabelled -> None
    wire.Labelled(path:, ..) ->
      dict.get(table.ids, owner.path_to_string(path)) |> option.from_result
  }
}

// ------------------------------------------------------------------- procs

type Proc {
  Proc(pid_text: String, record: capture.Proc)
}

fn all_rows(observations: List(Observation)) -> List(wire.ProcessRow) {
  list.flat_map(observations, fn(observation) {
    case observation.census {
      Ok(census) -> census.rows
      Error(_) -> []
    }
  })
}

// One proc per distinct pid, in order of first appearance, numbered from
// one. The first census that showed the process supplies its name and owner.
fn proc_table(rows: List(wire.ProcessRow), table: OwnerTable) -> List(Proc) {
  let seen =
    list.fold(rows, #([], dict.new()), fn(state, row) {
      case dict.has_key(state.1, row.pid_text) {
        True -> state
        False -> #([row, ..state.0], dict.insert(state.1, row.pid_text, Nil))
      }
    })

  list.reverse(seen.0)
  |> list.index_map(fn(row, index) {
    Proc(
      pid_text: row.pid_text,
      record: capture.Proc(
        ref: index + 1,
        pid_text: row.pid_text,
        birth_epoch: 0,
        first_seen_ms: 0,
        owner: leaf_id(table, row.owner),
        registered_name: case row.registered_name {
          "" -> None
          name -> Some(name)
        },
        initial_call: None,
      ),
    )
  })
}

// ------------------------------------------------------------------ series

fn specs_of(
  observations: List(Observation),
  procs: List(Proc),
  table: OwnerTable,
  word_size: Int,
) -> List(Spec) {
  let categories =
    list.flat_map(observations, fn(observation) {
      case observation.memory {
        Ok(memory) -> list.map(memory.categories, fn(pair) { pair.0 })
        Error(_) -> []
      }
    })
    |> list.unique

  list.flatten([
    list.map(categories, memory_spec),
    [process_count_spec()],
    scheduler_specs(observations),
    list.flat_map(procs, fn(proc) { process_specs(proc.pid_text, word_size) }),
    owner_specs(observations, table),
    os_specs(observations),
  ])
}

fn node_spec(
  method: String,
  subject: String,
  unit: unit.Unit,
  kind: measure.SeriesKind,
  additivity: measure.Additivity,
  value: fn(Observation) -> Measurement,
) -> Spec {
  Spec(
    kind:,
    unit:,
    additivity:,
    method:,
    scope: measure.NodeScope,
    subject:,
    value:,
  )
}

fn memory_spec(category: String) -> Spec {
  node_spec(
    method_memory,
    category,
    unit.Bytes,
    measure.Gauge,
    Overlapping("memory categories overlap; the total includes the others"),
    fn(observation) {
      case observation.memory {
        Ok(memory) ->
          case list.key_find(memory.categories, category) {
            Ok(bytes) -> Known(bytes)
            Error(Nil) -> Missing(measure.UnsupportedOnRuntime)
          }
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

fn process_count_spec() -> Spec {
  node_spec(
    method_process_count,
    "process_count",
    unit.Count,
    measure.Gauge,
    Additive,
    fn(observation) {
      case observation.memory {
        Ok(memory) -> Known(memory.process_count)
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

fn scheduler_specs(observations: List(Observation)) -> List(Spec) {
  let ids =
    list.flat_map(observations, fn(observation) {
      case observation.scheduler {
        Ok(snapshot) ->
          list.map(snapshot.readings, fn(reading) { reading.scheduler })
        Error(_) -> []
      }
    })
    |> list.unique
    |> list.sort(int.compare)

  list.flat_map(ids, fn(id) {
    [
      scheduler_spec(method_scheduler_active, id, fn(reading) { reading.active }),
      scheduler_spec(method_scheduler_total, id, fn(reading) { reading.total }),
    ]
  })
}

fn scheduler_spec(
  method: String,
  id: Int,
  pick: fn(wire.SchedulerReading) -> Int,
) -> Spec {
  node_spec(
    method,
    int.to_string(id),
    unit.Count,
    measure.Counter,
    Overlapping(
      "scheduler times are in the VM's native unit and are not summed",
    ),
    fn(observation) {
      case observation.scheduler {
        Ok(snapshot) ->
          case list.find(snapshot.readings, fn(r) { r.scheduler == id }) {
            Ok(reading) -> Known(pick(reading))
            Error(Nil) -> Missing(measure.BudgetExhausted)
          }
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

fn process_specs(pid_text: String, word_size: Int) -> List(Spec) {
  [
    process_spec(
      method_memory_bytes,
      pid_text,
      unit.Bytes,
      measure.Gauge,
      Additive,
      fn(row) { row.memory },
    ),
    process_spec(
      method_total_heap,
      pid_text,
      unit.Bytes,
      measure.Gauge,
      Overlapping("the heap is part of the total heap"),
      fn(row) { row.total_heap_words * word_size },
    ),
    process_spec(
      method_heap,
      pid_text,
      unit.Bytes,
      measure.Gauge,
      Overlapping("the heap is part of the total heap"),
      fn(row) { row.heap_words * word_size },
    ),
    process_spec(
      method_stack,
      pid_text,
      unit.Bytes,
      measure.Gauge,
      Overlapping("the stack shares the process heap area"),
      fn(row) { row.stack_words * word_size },
    ),
    process_spec(
      method_queue,
      pid_text,
      unit.Count,
      measure.Gauge,
      Additive,
      fn(row) { row.queue_length },
    ),
    process_spec(
      method_reductions,
      pid_text,
      unit.Reductions,
      measure.Counter,
      Additive,
      fn(row) { row.reductions },
    ),
  ]
}

fn process_spec(
  method: String,
  pid_text: String,
  unit: unit.Unit,
  kind: measure.SeriesKind,
  additivity: measure.Additivity,
  pick: fn(wire.ProcessRow) -> Int,
) -> Spec {
  Spec(
    kind:,
    unit:,
    additivity:,
    method:,
    scope: measure.ProcessScope,
    subject: pid_text,
    value: fn(observation) {
      case observation.census {
        Ok(census) ->
          case list.find(census.rows, fn(row) { row.pid_text == pid_text }) {
            Ok(row) -> Known(pick(row))

            // The process was not among the top rows of this census.
            Error(Nil) -> Missing(measure.BudgetExhausted)
          }
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

// Owner totals are keyed by the leaf owner id and the role, so a role
// change under the same path is a different series.
fn owner_specs(
  observations: List(Observation),
  table: OwnerTable,
) -> List(Spec) {
  let readings =
    list.flat_map(observations, fn(observation) {
      case observation.census {
        Ok(census) -> list.map(census.owners, fn(total) { total.owner })
        Error(_) -> []
      }
    })
    |> list.unique

  list.flat_map(readings, fn(reading) {
    let subject = owner_subject(table, reading)

    [
      owner_spec(method_owner_processes, subject, reading, unit.Count, fn(t) {
        t.processes
      }),
      owner_spec(method_owner_memory, subject, reading, unit.Bytes, fn(t) {
        t.memory
      }),
      owner_spec(method_owner_queue, subject, reading, unit.Count, fn(t) {
        t.queue_length
      }),
      owner_spec(
        method_owner_reductions,
        subject,
        reading,
        unit.Reductions,
        fn(t) { t.reductions },
      ),
    ]
  })
}

fn owner_subject(table: OwnerTable, reading: wire.OwnerReading) -> String {
  case reading {
    wire.Unlabelled -> "unlabelled"
    wire.Labelled(role:, ..) ->
      case leaf_id(table, reading) {
        Some(id) -> "owner:" <> int.to_string(id) <> separator <> role
        None -> "unlabelled"
      }
  }
}

fn owner_spec(
  method: String,
  subject: String,
  reading: wire.OwnerReading,
  unit: unit.Unit,
  pick: fn(wire.OwnerTotal) -> Int,
) -> Spec {
  Spec(
    kind: measure.Gauge,
    unit:,
    additivity: Additive,
    method:,
    scope: measure.OwnerScope,
    subject:,
    value: fn(observation) {
      case observation.census {
        Ok(census) ->
          case list.find(census.owners, fn(total) { total.owner == reading }) {
            Ok(total) -> Known(pick(total))
            Error(Nil) -> Missing(measure.BudgetExhausted)
          }
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

// ---------------------------------------------------------------------- os

// One subject per OS process: the pid and the role the reader gave it,
// joined by the separator. A pass whose OS reading failed has nothing for
// any of them, which reads back as the same failure.
fn os_subject(reading: os_reader.Reading) -> String {
  int.to_string(reading.pid) <> separator <> reading.role
}

fn os_subjects(observations: List(Observation)) -> List(String) {
  list.flat_map(observations, fn(observation) {
    case observation.os {
      Ok(readings) -> list.map(readings, os_subject)
      Error(_) -> []
    }
  })
  |> list.unique
}

fn os_specs(observations: List(Observation)) -> List(Spec) {
  list.flat_map(os_subjects(observations), fn(subject) {
    [
      os_spec(method_os_rss, subject, unit.Bytes, measure.Gauge, fn(reading) {
        reading.rss
      }),
      os_spec(method_os_anon, subject, unit.Bytes, measure.Gauge, fn(reading) {
        reading.anon
      }),
      // CPU time is stored in nanoseconds, the one time unit the format has.
      os_spec(
        method_os_cpu,
        subject,
        unit.Nanoseconds,
        measure.Counter,
        fn(reading) {
          case reading.cpu_ms {
            Known(ms) -> Known(ms * 1_000_000)
            other -> other
          }
        },
      ),
    ]
  })
}

fn os_spec(
  method: String,
  subject: String,
  unit: unit.Unit,
  kind: measure.SeriesKind,
  pick: fn(os_reader.Reading) -> Measurement,
) -> Spec {
  Spec(
    kind:,
    unit:,
    additivity: Overlapping(
      "processes share pages, so their resident sets are not summed",
    ),
    method:,
    scope: measure.OsProcessScope,
    subject:,
    value: fn(observation) {
      case observation.os {
        Ok(readings) ->
          case list.find(readings, fn(r) { os_subject(r) == subject }) {
            Ok(reading) -> pick(reading)
            Error(Nil) -> Missing(measure.ProcessExited)
          }
        Error(reason) -> Missing(missing_for(reason))
      }
    },
  )
}

// A failed section is a missing reading for a stated reason: a deadline when
// the agent did not answer in time, otherwise a reply that was unusable.
fn missing_for(reason: String) -> MissingReason {
  case string.contains(reason, "in time") {
    True -> measure.DeadlineReached
    False -> measure.DecodeFailed
  }
}

// ------------------------------------------------------------ events, coverage

fn event_records(
  observations: List(Observation),
  procs: List(Proc),
) -> List(Record(Profile)) {
  let pass =
    capture.EventsRecord(capture.Events(
      track: 0,
      kind: kind_pass,
      timestamps_ms: list.map(observations, fn(o) { o.at_ms }),
      durations_ms: list.map(observations, fn(o) { o.elapsed_ms }),
      args: list.map(observations, fn(o) { int.to_string(o.seq) }),
    ))

  let accounting =
    observations
    |> list.filter_map(fn(observation) {
      case observation.scheduler {
        Ok(snapshot) -> Ok(#(observation.at_ms, accounting_code(snapshot)))
        Error(_) -> Error(Nil)
      }
    })

  let accounting_events = case accounting {
    [] -> []
    _ -> [
      capture.EventsRecord(capture.Events(
        track: 0,
        kind: kind_scheduler,
        timestamps_ms: list.map(accounting, fn(pair) { pair.0 }),
        durations_ms: list.map(accounting, fn(_) { 0 }),
        args: list.map(accounting, fn(pair) { pair.1 }),
      )),
    ]
  }

  let census =
    observations
    |> list.filter_map(fn(observation) {
      case observation.census {
        Ok(census) -> Ok(#(observation.at_ms, census.coverage.elapsed_ms))
        Error(_) -> Error(Nil)
      }
    })

  let census_events = case census {
    [] -> []
    _ -> [
      capture.EventsRecord(capture.Events(
        track: 0,
        kind: kind_census,
        timestamps_ms: list.map(census, fn(pair) { pair.0 }),
        durations_ms: list.map(census, fn(pair) { pair.1 }),
        args: list.map(census, fn(_) { "" }),
      )),
    ]
  }

  let rows =
    list.filter_map(procs, fn(proc) {
      let present =
        list.filter_map(observations, fn(observation) {
          case observation.census {
            Ok(census) ->
              list.find(census.rows, fn(row) { row.pid_text == proc.pid_text })
              |> result.map(fn(row) { #(observation.at_ms, row_argument(row)) })
            Error(_) -> Error(Nil)
          }
        })

      case present {
        [] -> Error(Nil)
        _ ->
          Ok(
            capture.EventsRecord(capture.Events(
              track: proc.record.ref,
              kind: kind_row,
              timestamps_ms: list.map(present, fn(pair) { pair.0 }),
              durations_ms: list.map(present, fn(_) { 0 }),
              args: list.map(present, fn(pair) { pair.1 }),
            )),
          )
      }
    })

  list.flatten([[pass], accounting_events, census_events, rows])
}

fn accounting_code(snapshot: wire.SchedulerSnapshot) -> String {
  case snapshot.accounting {
    wire.Collecting -> "collecting"
    wire.NotCollecting -> "not_collecting"
  }
}

fn row_argument(row: wire.ProcessRow) -> String {
  let role = case row.owner {
    wire.Unlabelled -> ""
    wire.Labelled(role:, ..) -> role
  }

  string.join([row.status, row.current_function, role], separator)
}

fn coverage_of(observation: Observation) -> List(Record(Profile)) {
  [
    section_coverage("memory", observation.memory, fn(_) {
      #(1, 1, measure.Complete)
    }),
    section_coverage("census", observation.census, fn(census) {
      let coverage = census.coverage

      #(coverage.total, coverage.scanned, case coverage.stop {
        wire.WalkFinished -> measure.Complete
        wire.ScanBudgetReached ->
          measure.Partial(measure.Truncated(measure.BudgetReached))
        wire.DeadlineReached ->
          measure.Partial(measure.Truncated(measure.DeadlineHit))
      })
    }),
    section_coverage("scheduler", observation.scheduler, fn(_) {
      #(1, 1, measure.Complete)
    }),
  ]
}

fn section_coverage(
  scope: String,
  section: Result(a, String),
  of: fn(a) -> #(Int, Int, measure.Outcome),
) -> Record(Profile) {
  let #(requested, achieved, outcome) = case section {
    Ok(value) -> of(value)
    Error(reason) -> #(1, 0, measure.Errored(reason))
  }

  capture.CoverageRecord(measure.Coverage(
    scope:,
    requested:,
    achieved:,
    outcome:,
    dropped_events: NotApplicable,
    in_flight_events: NotApplicable,
    unscanned_bytes: NotApplicable,
  ))
}

// ----------------------------------------------------------------- reading

/// The target facts a capture's header carries that a memory snapshot needs
/// and the series do not.
pub type Runtime {
  Runtime(
    word_size: Int,
    otp_release: String,
    erts_version: String,
    schedulers_online: Int,
  )
}

// Everything `of_capture` looks up, built in one pass over the records. The
// fold's `case` names every record kind, so a new kind in the format is a
// compile error here and not a silently ignored record.
type Index {
  Index(
    series: Dict(#(String, String), Int),
    ordered: List(Series),
    samples: Dict(Int, Dict(Int, Measurement)),
    procs: Dict(Int, capture.Proc),
    defs: Dict(Int, capture.OwnerDef),
    strings: Dict(Int, String),
    events: Dict(#(Int, String), Dict(Int, #(Int, String))),
    coverage: List(measure.Coverage),
    runtime: Runtime,
  )
}

fn index_of(records: List(Record(Profile)), runtime: Runtime) -> Index {
  let empty =
    Index(
      series: dict.new(),
      ordered: [],
      samples: dict.new(),
      procs: dict.new(),
      defs: dict.new(),
      strings: dict.new(),
      events: dict.new(),
      coverage: [],
      runtime:,
    )

  let index =
    list.fold(records, empty, fn(index, record) {
      case record {
        capture.SeriesRecord(series) ->
          Index(
            ..index,
            series: dict.insert(
              index.series,
              #(series.method, series.subject),
              series.id,
            ),
            ordered: [series, ..index.ordered],
          )
        capture.SamplesRecord(samples) ->
          Index(
            ..index,
            samples: dict.insert(
              index.samples,
              samples.series,
              samples.values
                |> list.index_map(fn(value, position) { #(position, value) })
                |> dict.from_list,
            ),
          )
        capture.ProcRecord(proc) ->
          Index(..index, procs: dict.insert(index.procs, proc.ref, proc))
        capture.OwnerRecord(def) ->
          Index(..index, defs: dict.insert(index.defs, def.id, def))
        capture.StringsRecord(strings) ->
          Index(
            ..index,
            strings: list.index_fold(
              strings.values,
              index.strings,
              fn(table, value, offset) {
                dict.insert(table, strings.base + offset, value)
              },
            ),
          )
        capture.EventsRecord(events) ->
          Index(
            ..index,
            events: dict.insert(
              index.events,
              #(events.track, events.kind),
              events_by_time(events),
            ),
          )
        capture.CoverageRecord(coverage) ->
          Index(..index, coverage: [coverage, ..index.coverage])

        capture.HeaderRecord(_)
        | capture.ClockRecord(_)
        | capture.FunctionRecord(_)
        | capture.StackRecord(_)
        | capture.ProfileRecord(_)
        | capture.CheckpointRecord(_)
        | capture.ProbeCostRecord(_)
        | capture.AuditRecord(_)
        | capture.FooterRecord(_)
        | capture.UnknownRecord(..) -> index
      }
    })

  Index(
    ..index,
    ordered: list.reverse(index.ordered),
    coverage: list.reverse(index.coverage),
  )
}

fn events_by_time(events: capture.Events) -> Dict(Int, #(Int, String)) {
  list.zip(events.timestamps_ms, list.zip(events.durations_ms, events.args))
  |> dict.from_list
}

/// The observations a capture's records hold, oldest first. `Error` names
/// the first thing that makes them unreadable as observations: no `pass`
/// record, coverage records that do not come three to a pass, or a section
/// the records claim succeeded but hold no readings for.
///
/// ## Examples
///
/// ```gleam
/// observation_codec.of_records(capture.records, runtime)
/// ```
pub fn of_records(
  records: List(Record(Profile)),
  runtime: Runtime,
) -> Result(List(Observation), String) {
  let index = index_of(records, runtime)

  use pass <- result.try(
    dict.get(index.events, #(0, kind_pass))
    |> result.replace_error("the capture has no pass record"),
  )

  let times =
    dict.to_list(pass) |> list.sort(fn(a, b) { int.compare(a.0, b.0) })

  case list.length(index.coverage) == 3 * list.length(times) {
    False -> Error("the coverage records do not come three to a pass")
    True ->
      times
      |> list.index_map(fn(entry, position) {
        let sections = list.take(list.drop(index.coverage, position * 3), 3)

        observation_at(index, entry.0, position, entry.1, sections)
      })
      |> result.all
  }
}

fn observation_at(
  index: Index,
  at_ms: Int,
  position: Int,
  pass: #(Int, String),
  sections: List(measure.Coverage),
) -> Result(Observation, String) {
  case sections {
    [memory, census, scheduler] ->
      Ok(Observation(
        seq: result.unwrap(int.parse(pass.1), position),
        at_ms:,
        elapsed_ms: pass.0,
        memory: section(memory, fn() { memory_at(index, position) }),
        census: section(census, fn() {
          census_at(index, at_ms, position, census)
        }),
        scheduler: section(scheduler, fn() {
          scheduler_at(index, at_ms, position)
        }),
        os: os_at(index, position),
      ))
    _ -> Error("a pass needs three coverage records")
  }
}

// A section whose coverage says it failed reads back as the same failure,
// without looking for readings that were never written.
fn section(
  coverage: measure.Coverage,
  read: fn() -> Result(a, String),
) -> Result(a, String) {
  case coverage.outcome {
    measure.Errored(reason) | measure.Refused(reason) -> Error(reason)
    measure.Complete | measure.Partial(_) -> read()
  }
}

fn value_at(
  index: Index,
  method: String,
  subject: String,
  position: Int,
) -> Result(Int, Nil) {
  use id <- result.try(dict.get(index.series, #(method, subject)))
  use column <- result.try(dict.get(index.samples, id))
  use value <- result.try(dict.get(column, position))

  case value {
    Known(number) -> Ok(number)
    Missing(_) | NotApplicable -> Error(Nil)
  }
}

fn memory_at(
  index: Index,
  position: Int,
) -> Result(wire.MemorySnapshot, String) {
  let categories =
    index.ordered
    |> list.filter(fn(series) { series.method == method_memory })
    |> list.filter_map(fn(series) {
      value_at(index, method_memory, series.subject, position)
      |> result.map(fn(bytes) { #(series.subject, bytes) })
    })

  use count <- result.try(
    value_at(index, method_process_count, "process_count", position)
    |> result.replace_error("the capture holds no process count"),
  )

  Ok(wire.MemorySnapshot(
    categories:,
    word_size: index.runtime.word_size,
    process_count: count,
    otp_release: index.runtime.otp_release,
    erts_version: index.runtime.erts_version,
    schedulers_online: index.runtime.schedulers_online,
  ))
}

// The OS readings of a pass, from whichever OS series the capture holds. A
// capture with none (an older one, or a viewer with no OS reader) reads back
// as a reading that says so.
fn os_at(
  index: Index,
  position: Int,
) -> Result(List(os_reader.Reading), String) {
  let readings =
    index.ordered
    |> list.filter(fn(series) { series.method == method_os_rss })
    |> list.filter_map(fn(series) {
      use #(pid_text, role) <- result.try(string.split_once(
        series.subject,
        separator,
      ))
      use pid <- result.try(int.parse(pid_text))

      Ok(os_reader.Reading(
        pid:,
        role:,
        rss: measurement_at(index, method_os_rss, series.subject, position),
        anon: measurement_at(index, method_os_anon, series.subject, position),
        cpu_ms: case
          measurement_at(index, method_os_cpu, series.subject, position)
        {
          Known(ns) -> Known(ns / 1_000_000)
          other -> other
        },
        start: identity.UnreadableStart,
      ))
    })

  case readings {
    [] -> Error(no_os_readings)
    _ -> Ok(readings)
  }
}

fn measurement_at(
  index: Index,
  method: String,
  subject: String,
  position: Int,
) -> Measurement {
  let found = {
    use id <- result.try(dict.get(index.series, #(method, subject)))
    use column <- result.try(dict.get(index.samples, id))

    dict.get(column, position)
  }

  result.unwrap(found, Missing(measure.UnsupportedOnRuntime))
}

fn scheduler_at(
  index: Index,
  at_ms: Int,
  position: Int,
) -> Result(wire.SchedulerSnapshot, String) {
  use accounting <- result.try(
    event_at(index, 0, kind_scheduler, at_ms)
    |> result.replace_error("the capture holds no scheduler accounting"),
  )

  let readings =
    index.ordered
    |> list.filter(fn(series) { series.method == method_scheduler_active })
    |> list.filter_map(fn(series) {
      use id <- result.try(int.parse(series.subject))
      use active <- result.try(value_at(
        index,
        method_scheduler_active,
        series.subject,
        position,
      ))
      use total <- result.try(value_at(
        index,
        method_scheduler_total,
        series.subject,
        position,
      ))

      Ok(wire.SchedulerReading(scheduler: id, active:, total:))
    })

  Ok(wire.SchedulerSnapshot(
    accounting: case accounting.1 {
      "collecting" -> wire.Collecting
      _ -> wire.NotCollecting
    },
    readings:,
  ))
}

fn event_at(
  index: Index,
  track: Int,
  kind: String,
  at_ms: Int,
) -> Result(#(Int, String), Nil) {
  use events <- result.try(dict.get(index.events, #(track, kind)))

  dict.get(events, at_ms)
}

fn census_at(
  index: Index,
  at_ms: Int,
  position: Int,
  coverage: measure.Coverage,
) -> Result(wire.CensusSnapshot, String) {
  use elapsed <- result.try(
    event_at(index, 0, kind_census, at_ms)
    |> result.replace_error("the capture holds no census timing"),
  )

  let rows =
    dict.values(index.procs)
    |> list.filter_map(fn(proc) { row_at(index, proc, at_ms, position) })
    |> list.sort(fn(a, b) {
      case int.compare(b.memory, a.memory) {
        order.Eq -> string.compare(a.pid_text, b.pid_text)
        other -> other
      }
    })

  let owners =
    index.ordered
    |> list.filter(fn(series) { series.method == method_owner_processes })
    |> list.filter_map(fn(series) {
      owner_total_at(index, series.subject, position)
    })
    |> list.sort(fn(a, b) {
      case int.compare(b.memory, a.memory) {
        order.Eq -> string.compare(owner_text(a.owner), owner_text(b.owner))
        other -> other
      }
    })

  Ok(wire.CensusSnapshot(
    coverage: wire.CensusCoverage(
      scanned: coverage.achieved,
      total: coverage.requested,
      stop: case coverage.outcome {
        measure.Partial(measure.Truncated(measure.BudgetReached)) ->
          wire.ScanBudgetReached
        measure.Partial(measure.Truncated(measure.DeadlineHit)) ->
          wire.DeadlineReached
        _ -> wire.WalkFinished
      },
      elapsed_ms: elapsed.0,
    ),
    rows:,
    owners:,
  ))
}

fn owner_text(reading: wire.OwnerReading) -> String {
  case reading {
    wire.Unlabelled -> ""
    wire.Labelled(path:, role:) -> owner.path_to_string(path) <> "#" <> role
  }
}

fn row_at(
  index: Index,
  proc: capture.Proc,
  at_ms: Int,
  position: Int,
) -> Result(wire.ProcessRow, Nil) {
  let pid = proc.pid_text
  use event <- result.try(event_at(index, proc.ref, kind_row, at_ms))
  use memory <- result.try(value_at(index, method_memory_bytes, pid, position))
  use total_heap <- result.try(value_at(index, method_total_heap, pid, position))
  use heap <- result.try(value_at(index, method_heap, pid, position))
  use stack <- result.try(value_at(index, method_stack, pid, position))
  use queue <- result.try(value_at(index, method_queue, pid, position))
  use reductions <- result.try(value_at(index, method_reductions, pid, position))
  use #(status, function, role) <- result.try(row_parts(event.1))

  // Heap sizes were stored in bytes; the wire reports words, and the word
  // size is the one the capture's header recorded.
  let words = fn(bytes) { bytes / int.max(1, index.runtime.word_size) }

  Ok(wire.ProcessRow(
    pid_text: pid,
    memory:,
    total_heap_words: words(total_heap),
    heap_words: words(heap),
    stack_words: words(stack),
    queue_length: queue,
    reductions:,
    status:,
    current_function: function,
    registered_name: option.unwrap(proc.registered_name, ""),
    owner: owner_reading(index, proc.owner, role),
  ))
}

fn row_parts(argument: String) -> Result(#(String, String, String), Nil) {
  case string.split(argument, separator) {
    [status, function, ..role] ->
      Ok(#(status, function, string.join(role, separator)))
    _ -> Error(Nil)
  }
}

fn owner_reading(
  index: Index,
  owner: Option(Int),
  role: String,
) -> wire.OwnerReading {
  case owner {
    None -> wire.Unlabelled
    Some(id) ->
      case path_of(index, id) {
        Ok(path) -> wire.Labelled(path:, role:)
        Error(Nil) -> wire.Unlabelled
      }
  }
}

// The path of an owner is its chain of parents from the root, each segment
// the def's kind and the interned display string.
fn path_of(index: Index, id: Int) -> Result(List(owner.Segment), Nil) {
  use def <- result.try(dict.get(index.defs, id))
  use text <- result.try(dict.get(index.strings, def.display))

  let segment = owner.Segment(kind: def.kind, id: text)

  case def.parent {
    None -> Ok([segment])
    Some(parent) ->
      path_of(index, parent)
      |> result.map(fn(path) { list.append(path, [segment]) })
  }
}

fn reading_of_subject(
  index: Index,
  subject: String,
) -> Result(wire.OwnerReading, Nil) {
  case subject {
    "unlabelled" -> Ok(wire.Unlabelled)
    "owner:" <> rest -> {
      use #(id_text, role) <- result.try(string.split_once(rest, separator))
      use id <- result.try(int.parse(id_text))
      use path <- result.try(path_of(index, id))

      Ok(wire.Labelled(path:, role:))
    }
    _ -> Error(Nil)
  }
}

fn owner_total_at(
  index: Index,
  subject: String,
  position: Int,
) -> Result(wire.OwnerTotal, Nil) {
  use reading <- result.try(reading_of_subject(index, subject))
  use processes <- result.try(value_at(
    index,
    method_owner_processes,
    subject,
    position,
  ))
  use memory <- result.try(value_at(
    index,
    method_owner_memory,
    subject,
    position,
  ))
  use queue <- result.try(value_at(index, method_owner_queue, subject, position))
  use reductions <- result.try(value_at(
    index,
    method_owner_reductions,
    subject,
    position,
  ))

  Ok(wire.OwnerTotal(
    owner: reading,
    processes:,
    memory:,
    queue_length: queue,
    reductions:,
  ))
}
