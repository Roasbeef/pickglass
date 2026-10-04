//// What a capture was collected from, how, and whether two captures may be
//// compared.
////
//// A baseline and a candidate that differ in anything but the change under
//// test cannot support a statement that the change helped. A different
//// collection method, runtime, budget, cadence, workload or warmup moves
//// the numbers by itself. This module records those facts in the capture
//// header and compares two sets of them field by field. A field is `Same`,
//// `DiffersExpected` (the build under test, the node's incarnation), or
//// `DiffersBlocking`. Any blocking field withholds the direction of change
//// entirely: the answer is "not comparable", never "improved" or
//// "regressed".
////
//// Withholding is per column where the evidence allows. A cadence mismatch
//// makes rates and deltas incomparable but not gauges, so
//// `compare_measurements` takes the series kind into account.
////
//// ## Flow
////
//// - `comparability` compares two `Provenance` values field by field.
//// - `verdict_for` asks whether a direction may be stated for one kind of
////   series.
//// - `compare_measurements` applies that to two readings.

import gleam/int
import gleam/list
import gleam/order
import gleam/string
import pickglass_core/identity.{type NodeIncarnation, type OsProcess}
import pickglass_core/measure.{
  type Cadence, type Measurement, type SeriesKind, EveryMs, Known, OneShot,
}

// ------------------------------------------------------------ the header

/// Which programs produced the capture.
pub type Producer {
  Producer(
    /// The viewer's version.
    pickglass: String,
    /// The pushed agent's version.
    agent: String,
    /// The capture schema, such as `pickglass.capture/1`.
    schema: String,
  )
}

/// The node and OS process the capture describes.
pub type Target {
  Target(
    incarnation: NodeIncarnation,
    os: OsProcess,
    /// The host's name for the node's role, such as `loomd`.
    role: String,
  )
}

/// The runtime the target ran on.
pub type Runtime {
  Runtime(
    otp_release: String,
    erts_version: String,
    emulator_flavor: String,
    wordsize: Int,
    schedulers: Int,
    dirty_cpu_schedulers: Int,
    /// Emulator flags that change measurement, such as `+Muatags` and
    /// `+JPperf`, as the target reported them.
    flags: List(String),
  )
}

/// The build of the host application that ran.
pub type Build {
  Build(
    application: String,
    version: String,
    revision: String,
    /// The Gleam compiler version, which changes generated code.
    compiler: String,
  )
}

/// What the target was doing.
pub type Workload {
  Workload(
    /// The operator's label for the workload, such as `idle-12`.
    label: String,
    /// Counts the host's provider reported, such as `("sessions", 12)`.
    sessions: List(#(String, Int)),
    /// Milliseconds the target ran before collection started.
    warmup_ms: Int,
    /// Free-form notes. Never compared.
    notes: String,
  )
}

/// The limits a collection ran under.
pub type Budgets {
  Budgets(
    /// Rows kept by a census.
    top_k: Int,
    /// Events a probe may collect before it stops.
    max_events: Int,
    /// Milliseconds a collection may run.
    deadline_ms: Int,
  )
}

/// How the capture was collected.
pub type Collection {
  Collection(
    /// The collector and its parameters as a stable identifier.
    method: String,
    cadence: Cadence,
    budgets: Budgets,
  )
}

/// Everything the header of a capture records about its origin.
pub type Provenance {
  Provenance(
    producer: Producer,
    target: Target,
    runtime: Runtime,
    build: Build,
    workload: Workload,
    collection: Collection,
  )
}

// ---------------------------------------------------------- comparability

/// A part of the provenance that is compared.
pub type Field {
  /// The collection method.
  Method

  /// The runtime facts.
  RuntimeField

  /// The collection budgets.
  Budget

  /// The workload label and counts.
  WorkloadField

  /// The warmup before collection.
  Warmup

  /// The collection cadence.
  CadenceField

  /// The node's role.
  Role

  /// The build under test.
  BuildField
}

/// How one field compares.
pub type FieldResult {
  /// The two captures agree.
  Same

  /// The fields differ and that is what the comparison is for.
  DiffersExpected

  /// The fields differ in a way that invalidates the comparison. The
  /// string says how.
  DiffersBlocking(detail: String)
}

/// The per-field comparison of two captures.
pub type Comparability {
  Comparability(fields: List(#(Field, FieldResult)))
}

/// The stable name of a field.
pub fn field_name(field: Field) -> String {
  case field {
    Method -> "method"
    RuntimeField -> "runtime"
    Budget -> "budget"
    WorkloadField -> "workload"
    Warmup -> "warmup"
    CadenceField -> "cadence"
    Role -> "role"
    BuildField -> "build"
  }
}

/// Compare a baseline and a candidate field by field.
///
/// Build differences are expected. Differences in method, runtime, budget,
/// cadence, workload, warmup or role are blocking. The node incarnation and
/// OS process always differ between captures and are not compared.
///
/// ## Examples
///
/// ```gleam
/// let result = provenance.comparability(baseline, candidate)
/// provenance.verdict_for(result, measure.Gauge)
/// ```
pub fn comparability(
  baseline: Provenance,
  candidate: Provenance,
) -> Comparability {
  Comparability(fields: [
    #(Method, blocking(baseline.collection.method, candidate.collection.method)),
    #(
      RuntimeField,
      blocking(
        normalize_runtime(baseline.runtime),
        normalize_runtime(candidate.runtime),
      ),
    ),
    #(
      Budget,
      blocking(
        budgets_text(baseline.collection.budgets),
        budgets_text(candidate.collection.budgets),
      ),
    ),
    #(
      WorkloadField,
      blocking(
        workload_text(baseline.workload),
        workload_text(candidate.workload),
      ),
    ),
    #(
      Warmup,
      blocking(
        int.to_string(baseline.workload.warmup_ms),
        int.to_string(candidate.workload.warmup_ms),
      ),
    ),
    #(
      CadenceField,
      blocking(
        cadence_text(baseline.collection.cadence),
        cadence_text(candidate.collection.cadence),
      ),
    ),
    #(Role, blocking(baseline.target.role, candidate.target.role)),
    #(BuildField, expected(baseline.build, candidate.build)),
  ])
}

fn blocking(baseline: a, candidate: a) -> FieldResult {
  case baseline == candidate {
    True -> Same
    False ->
      DiffersBlocking(
        detail: "baseline "
        <> string.inspect(baseline)
        <> " versus candidate "
        <> string.inspect(candidate),
      )
  }
}

fn expected(baseline: a, candidate: a) -> FieldResult {
  case baseline == candidate {
    True -> Same
    False -> DiffersExpected
  }
}

// Flags are a set: the order the target listed them in carries no meaning.
fn normalize_runtime(runtime: Runtime) -> Runtime {
  Runtime(..runtime, flags: list.sort(runtime.flags, string.compare))
}

fn budgets_text(budgets: Budgets) -> String {
  "top_k="
  <> int.to_string(budgets.top_k)
  <> " max_events="
  <> int.to_string(budgets.max_events)
  <> " deadline_ms="
  <> int.to_string(budgets.deadline_ms)
}

fn cadence_text(cadence: Cadence) -> String {
  case cadence {
    OneShot -> "one_shot"
    EveryMs(interval_ms:) -> "every " <> int.to_string(interval_ms) <> " ms"
  }
}

// The label and the sorted counts identify a workload; notes do not.
fn workload_text(workload: Workload) -> String {
  let counts =
    workload.sessions
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(pair) { pair.0 <> "=" <> int.to_string(pair.1) })

  workload.label <> " [" <> string.join(counts, ", ") <> "]"
}

/// The fields that block a comparison.
///
/// ## Examples
///
/// ```gleam
/// provenance.blocking_fields(result)
/// // -> [Method] when only the method differs
/// ```
pub fn blocking_fields(comparability: Comparability) -> List(Field) {
  list.filter_map(comparability.fields, fn(entry) {
    case entry.1 {
      DiffersBlocking(_) -> Ok(entry.0)
      Same | DiffersExpected -> Error(Nil)
    }
  })
}

// ---------------------------------------------------------------- verdict

/// Whether a direction of change may be stated.
pub type Verdict {
  /// Every field that matters for this series agrees closely enough that
  /// "increased" and "decreased" are statements about the target.
  DirectionAllowed

  /// A direction may not be stated. The fields are why.
  DirectionWithheld(blocking: List(Field))
}

/// Whether a direction may be stated for a series of this kind. A cadence
/// mismatch withholds the direction of counters and deltas only, since a
/// level read at a different interval is still the same level.
///
/// ## Examples
///
/// ```gleam
/// provenance.verdict_for(result, measure.Gauge)
/// ```
pub fn verdict_for(comparability: Comparability, kind: SeriesKind) -> Verdict {
  let relevant =
    list.filter(blocking_fields(comparability), fn(field) {
      field != CadenceField || rate_like(kind)
    })

  case relevant {
    [] -> DirectionAllowed
    fields -> DirectionWithheld(blocking: fields)
  }
}

fn rate_like(kind: SeriesKind) -> Bool {
  case kind {
    measure.Gauge -> False
    measure.Counter | measure.DeltaOverInterval -> True
  }
}

/// The direction a value moved. It says nothing about whether the change
/// is good.
pub type Direction {
  Increased
  Decreased
  Unchanged
}

/// What a comparison of two readings may say.
pub type Judgement {
  /// The readings are comparable and moved this way.
  Moved(direction: Direction)

  /// The captures are not comparable for this series; the fields say why.
  Withheld(blocking: List(Field))

  /// At least one reading is absent, so there is nothing to compare.
  NoReading
}

/// Compare two readings of one kind of series under a comparability
/// result. A blocking field withholds the direction; an absent reading
/// gives no direction either, and is never compared as zero.
///
/// ## Examples
///
/// ```gleam
/// provenance.compare_measurements(result, measure.Gauge, Known(10), Known(12))
/// // -> Moved(Increased) when the captures are comparable
/// ```
pub fn compare_measurements(
  comparability: Comparability,
  kind: SeriesKind,
  baseline: Measurement,
  candidate: Measurement,
) -> Judgement {
  case verdict_for(comparability, kind), baseline, candidate {
    DirectionWithheld(blocking:), _, _ -> Withheld(blocking:)
    DirectionAllowed, Known(a), Known(b) -> Moved(direction_of(a, b))
    DirectionAllowed, _, _ -> NoReading
  }
}

fn direction_of(baseline: Int, candidate: Int) -> Direction {
  case int.compare(baseline, candidate) {
    order.Lt -> Increased
    order.Gt -> Decreased
    order.Eq -> Unchanged
  }
}
