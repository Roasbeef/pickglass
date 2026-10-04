//// JSON encoders and total decoders for the leaf types the capture format
//// shares: units, measurements, series, coverage, identity, ownership,
//// provenance and audit entries.
////
//// Every decoder here is total in the sense the capture format needs: any
//// input, however malformed, yields `Ok` of a domain value or `Error` of a
//// decode error list, and never a default. A missing reading is encoded as
//// a reason or a marker, never as `0`; a code this build does not know is an
//// error, never a fallback variant. The records that use these codecs live
//// in `pickglass_core/capture`.
////
//// ## Flow
////
//// - `parsed` is the combinator that turns a closed code into a decoder.
//// - `measurement_json` and `column_json` write readings; `column_decoder`
////   reads them back and refuses a position with no value and no reason.
//// - `series_fields`, `coverage_fields` and `audit_fields` write the bodies
////   of those records; `provenance_json` writes the header's provenance.

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pickglass_core/identity.{
  type NodeIncarnation, type OsProcess, type StartIdentity, CoarseStart,
  NodeIncarnation, OsProcess, PreciseStart, UnreadableStart,
}
import pickglass_core/measure.{
  type Additivity, type Cadence, type Coverage, type Measurement, type Outcome,
  type Series, Additive, Coverage, EveryMs, Known, Missing, NotApplicable,
  OneShot, Overlapping, Series,
}
import pickglass_core/owner.{type Claim, type Segment, Claim, Segment}
import pickglass_core/policy.{
  type AuditDecision, type AuditEntry, type Stage, Allowed, AuditEntry,
  AuthorizeStage, ConfirmStage, Denied, PlanStage,
}
import pickglass_core/provenance.{
  type Budgets, type Build, type Collection, type Producer, type Provenance,
  type Runtime, type Target, type Workload, Budgets, Build, Collection, Producer,
  Provenance, Runtime, Target, Workload,
}
import pickglass_core/unit.{type Unit}

// ----------------------------------------------------------- combinators

/// A decoder for a string that must parse as a closed code. `placeholder`
/// is the value gleam's decoder protocol requires on failure; it is never
/// returned as a success.
///
/// ## Examples
///
/// ```gleam
/// codec.parsed("a unit", unit.Count, unit.parse)
/// ```
pub fn parsed(
  expected: String,
  placeholder: a,
  parse: fn(String) -> Result(a, Nil),
) -> Decoder(a) {
  use text <- decode.then(decode.string)

  case parse(text) {
    Ok(value) -> decode.success(value)
    Error(Nil) -> decode.failure(placeholder, expected)
  }
}

fn nullable_string(value: Option(String)) -> Json {
  json.nullable(value, json.string)
}

fn nullable_int(value: Option(Int)) -> Json {
  json.nullable(value, json.int)
}

// ----------------------------------------------------------------- units

/// Encode a unit as its stable name.
pub fn unit_json(u: Unit) -> Json {
  json.string(unit.to_string(u))
}

/// Decode a unit name; an unknown name is an error.
pub fn unit_decoder() -> Decoder(Unit) {
  parsed("a unit", unit.Count, unit.parse)
}

// ---------------------------------------------------------- measurements

/// Encode one measurement as an object: `{"v":N}`, `{"missing":"code"}` or
/// `{"not_applicable":true}`. A missing reading carries no number.
pub fn measurement_json(measurement: Measurement) -> Json {
  case measurement {
    Known(value:) -> json.object([#("v", json.int(value))])
    Missing(reason:) ->
      json.object([
        #("missing", json.string(measure.missing_reason_code(reason))),
      ])
    NotApplicable -> json.object([#("not_applicable", json.bool(True))])
  }
}

/// Decode one measurement written by `measurement_json`.
pub fn measurement_decoder() -> Decoder(Measurement) {
  decode.one_of(
    {
      use value <- decode.field("v", decode.int)
      decode.success(Known(value:))
    },
    or: [
      {
        use reason <- decode.field(
          "missing",
          parsed(
            "a missing reason",
            measure.ProcessExited,
            measure.parse_missing_reason,
          ),
        )
        decode.success(Missing(reason:))
      },
      {
        use _ <- decode.field("not_applicable", decode.bool)
        decode.success(NotApplicable)
      },
    ],
  )
}

/// Encode a column of measurements as two parallel arrays: `values`, with
/// `null` where there is no reading, and `reasons`, with `null` where there
/// is one and a code (a missing reason, or `not_applicable`) where there is
/// not.
pub fn column_json(rows: List(Measurement)) -> List(#(String, Json)) {
  [
    #(
      "values",
      json.array(rows, fn(row) { nullable_int(measure.to_option(row)) }),
    ),
    #(
      "reasons",
      json.array(rows, fn(row) { nullable_string(reason_code(row)) }),
    ),
  ]
}

fn reason_code(row: Measurement) -> Option(String) {
  case row {
    Known(_) -> None
    Missing(reason:) -> Some(measure.missing_reason_code(reason))
    NotApplicable -> Some("not_applicable")
  }
}

/// Decode a column written by `column_json`. The arrays must have the same
/// length, and each position must have exactly one of a value or a reason:
/// a position with neither would be a silent zero and is refused.
pub fn column_decoder() -> Decoder(List(Measurement)) {
  use values <- decode.field("values", decode.list(decode.optional(decode.int)))
  use reasons <- decode.field(
    "reasons",
    decode.list(decode.optional(decode.string)),
  )

  case zip_column(values, reasons) {
    Ok(rows) -> decode.success(rows)
    Error(Nil) ->
      decode.failure([], "a column with one value or reason per row")
  }
}

fn zip_column(
  values: List(Option(Int)),
  reasons: List(Option(String)),
) -> Result(List(Measurement), Nil) {
  case values, reasons {
    [], [] -> Ok([])
    [value, ..values], [reason, ..reasons] -> {
      use row <- result.try(row_of(value, reason))
      use rest <- result.try(zip_column(values, reasons))
      Ok([row, ..rest])
    }
    [], [_, ..] | [_, ..], [] -> Error(Nil)
  }
}

fn row_of(
  value: Option(Int),
  reason: Option(String),
) -> Result(Measurement, Nil) {
  case value, reason {
    Some(value), None -> Ok(Known(value:))
    None, Some("not_applicable") -> Ok(NotApplicable)
    None, Some(code) ->
      measure.parse_missing_reason(code) |> result.map(Missing)
    Some(_), Some(_) | None, None -> Error(Nil)
  }
}

// ---------------------------------------------------------------- series

fn additivity_fields(additivity: Additivity) -> List(#(String, Json)) {
  case additivity {
    Additive -> [#("additivity", json.string("additive"))]
    Overlapping(why:) -> [
      #("additivity", json.string("overlapping")),
      #("why", json.string(why)),
    ]
  }
}

fn additivity_decoder() -> Decoder(Additivity) {
  use code <- decode.field("additivity", decode.string)

  case code {
    "additive" -> decode.success(Additive)
    "overlapping" -> {
      use why <- decode.field("why", decode.string)
      decode.success(Overlapping(why:))
    }
    _ -> decode.failure(Additive, "additive or overlapping")
  }
}

/// Encode a cadence: `"one_shot"` or the interval in milliseconds.
pub fn cadence_json(cadence: Cadence) -> Json {
  case cadence {
    OneShot -> json.string("one_shot")
    EveryMs(interval_ms:) -> json.int(interval_ms)
  }
}

/// Decode a cadence. A non-positive interval is an error.
pub fn cadence_decoder() -> Decoder(Cadence) {
  decode.one_of(
    {
      use ms <- decode.then(decode.int)

      case ms > 0 {
        True -> decode.success(EveryMs(interval_ms: ms))
        False -> decode.failure(OneShot, "a positive interval")
      }
    },
    or: [
      {
        use text <- decode.then(decode.string)

        case text {
          "one_shot" -> decode.success(OneShot)
          _ -> decode.failure(OneShot, "one_shot")
        }
      },
    ],
  )
}

/// The fields of a series record, without the record tag.
pub fn series_fields(series: Series) -> List(#(String, Json)) {
  list.flatten([
    [
      #("id", json.int(series.id)),
      #("kind", json.string(measure.kind_code(series.kind))),
      #("unit", unit_json(series.unit)),
    ],
    additivity_fields(series.additivity),
    [
      #("method", json.string(series.method)),
      #("scope", json.string(measure.scope_code(series.scope))),
      #("subject", json.string(series.subject)),
      #("cadence", cadence_json(series.cadence)),
    ],
  ])
}

/// Decode the fields written by `series_fields`.
pub fn series_decoder() -> Decoder(Series) {
  use id <- decode.field("id", decode.int)
  use kind <- decode.field(
    "kind",
    parsed("a series kind", measure.Gauge, measure.parse_kind),
  )
  use u <- decode.field("unit", unit_decoder())
  use additivity <- decode.then(additivity_decoder())
  use method <- decode.field("method", decode.string)
  use scope <- decode.field(
    "scope",
    parsed("a scope", measure.NodeScope, measure.parse_scope),
  )
  use subject <- decode.field("subject", decode.string)
  use cadence <- decode.field("cadence", cadence_decoder())

  decode.success(Series(
    id:,
    kind:,
    unit: u,
    additivity:,
    method:,
    scope:,
    subject:,
    cadence:,
  ))
}

// -------------------------------------------------------------- coverage

fn outcome_fields(outcome: Outcome) -> List(#(String, Json)) {
  case outcome {
    measure.Complete -> [#("outcome", json.string("complete"))]
    measure.Partial(reason:) -> [
      #("outcome", json.string("partial")),
      #("reason", json.string(measure.partial_code(reason))),
    ]
    measure.Refused(reason:) -> [
      #("outcome", json.string("refused")),
      #("reason", json.string(reason)),
    ]
    measure.Errored(reason:) -> [
      #("outcome", json.string("errored")),
      #("reason", json.string(reason)),
    ]
  }
}

fn outcome_decoder() -> Decoder(Outcome) {
  use code <- decode.field("outcome", decode.string)

  case code {
    "complete" -> decode.success(measure.Complete)
    "partial" -> {
      use reason <- decode.field(
        "reason",
        parsed("a partial reason", measure.NoFooter, measure.parse_partial),
      )
      decode.success(measure.Partial(reason:))
    }
    "refused" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(measure.Refused(reason:))
    }
    "errored" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(measure.Errored(reason:))
    }
    _ -> decode.failure(measure.Complete, "a coverage outcome")
  }
}

/// The fields of a coverage record, without the record tag.
pub fn coverage_fields(coverage: Coverage) -> List(#(String, Json)) {
  list.flatten([
    [
      #("scope", json.string(coverage.scope)),
      #("requested", json.int(coverage.requested)),
      #("achieved", json.int(coverage.achieved)),
    ],
    outcome_fields(coverage.outcome),
    [
      #("dropped_events", measurement_json(coverage.dropped_events)),
      #("in_flight_events", measurement_json(coverage.in_flight_events)),
      #("unscanned_bytes", measurement_json(coverage.unscanned_bytes)),
    ],
  ])
}

/// Decode the fields written by `coverage_fields`.
pub fn coverage_decoder() -> Decoder(Coverage) {
  use scope <- decode.field("scope", decode.string)
  use requested <- decode.field("requested", decode.int)
  use achieved <- decode.field("achieved", decode.int)
  use outcome <- decode.then(outcome_decoder())
  use dropped_events <- decode.field("dropped_events", measurement_decoder())
  use in_flight_events <- decode.field(
    "in_flight_events",
    measurement_decoder(),
  )
  use unscanned_bytes <- decode.field("unscanned_bytes", measurement_decoder())

  decode.success(Coverage(
    scope:,
    requested:,
    achieved:,
    outcome:,
    dropped_events:,
    in_flight_events:,
    unscanned_bytes:,
  ))
}

// -------------------------------------------------------------- identity

/// Encode a node incarnation.
pub fn incarnation_json(incarnation: NodeIncarnation) -> Json {
  json.object([
    #("node", json.string(incarnation.node_digest)),
    #("creation", json.int(incarnation.creation)),
    #("boot", json.string(identity.boot_id_text(incarnation.boot))),
  ])
}

/// Decode a node incarnation; an invalid boot id is an error.
pub fn incarnation_decoder() -> Decoder(NodeIncarnation) {
  use node_digest <- decode.field("node", decode.string)
  use creation <- decode.field("creation", decode.int)
  use boot <- decode.field("boot", boot_decoder())

  decode.success(NodeIncarnation(node_digest:, creation:, boot:))
}

fn boot_decoder() -> Decoder(identity.BootId) {
  use text <- decode.then(decode.string)

  case identity.boot_id(text) {
    Ok(boot) -> decode.success(boot)
    Error(Nil) -> decode.failure(identity.unknown_boot, "a boot id")
  }
}

fn start_json(start: StartIdentity) -> Json {
  case start {
    PreciseStart(token:) ->
      json.object([
        #("precision", json.string("precise")),
        #("token", json.string(token)),
      ])
    CoarseStart(token:) ->
      json.object([
        #("precision", json.string("coarse")),
        #("token", json.string(token)),
      ])
    UnreadableStart -> json.object([#("precision", json.string("unreadable"))])
  }
}

fn start_decoder() -> Decoder(StartIdentity) {
  use precision <- decode.field("precision", decode.string)

  case precision {
    "precise" -> {
      use token <- decode.field("token", decode.string)
      decode.success(PreciseStart(token:))
    }
    "coarse" -> {
      use token <- decode.field("token", decode.string)
      decode.success(CoarseStart(token:))
    }
    "unreadable" -> decode.success(UnreadableStart)
    _ -> decode.failure(UnreadableStart, "a start precision")
  }
}

/// Encode an OS process identity.
pub fn os_process_json(process: OsProcess) -> Json {
  json.object([
    #("pid", json.int(process.pid)),
    #("start", start_json(process.start)),
  ])
}

/// Decode an OS process identity.
pub fn os_process_decoder() -> Decoder(OsProcess) {
  use pid <- decode.field("pid", decode.int)
  use start <- decode.field("start", start_decoder())

  decode.success(OsProcess(pid:, start:))
}

// ------------------------------------------------------------- ownership

/// Encode an owner path segment.
pub fn segment_json(segment: Segment) -> Json {
  json.object([
    #("kind", json.string(segment.kind)),
    #("id", json.string(segment.id)),
  ])
}

/// Decode an owner path segment through `owner.segment`, so a segment the
/// vocabulary would refuse is refused here too.
pub fn segment_decoder() -> Decoder(Segment) {
  use kind <- decode.field("kind", decode.string)
  use id <- decode.field("id", decode.string)

  case owner.segment(kind, id) {
    Ok(segment) -> decode.success(segment)
    Error(Nil) ->
      decode.failure(Segment(kind: "invalid", id: "invalid"), "a segment")
  }
}

/// Encode an ownership claim.
pub fn claim_json(claim: Claim) -> Json {
  json.object([
    #("path", json.array(claim.path, segment_json)),
    #("role", json.string(claim.role)),
    #("source", json.string(owner.source_code(claim.source))),
    #("confidence", json.string(owner.confidence_code(claim.confidence))),
  ])
}

/// Decode an ownership claim.
pub fn claim_decoder() -> Decoder(Claim) {
  use path <- decode.field("path", decode.list(segment_decoder()))
  use role <- decode.field("role", decode.string)
  use source <- decode.field(
    "source",
    parsed("a source", owner.Declared, owner.parse_source),
  )
  use confidence <- decode.field(
    "confidence",
    parsed("a confidence", owner.Low, owner.parse_confidence),
  )

  decode.success(Claim(path:, role:, source:, confidence:))
}

// ------------------------------------------------------------ provenance

fn producer_json(producer: Producer) -> Json {
  json.object([
    #("pickglass", json.string(producer.pickglass)),
    #("agent", json.string(producer.agent)),
    #("schema", json.string(producer.schema)),
  ])
}

fn producer_decoder() -> Decoder(Producer) {
  use pickglass <- decode.field("pickglass", decode.string)
  use agent <- decode.field("agent", decode.string)
  use schema <- decode.field("schema", decode.string)

  decode.success(Producer(pickglass:, agent:, schema:))
}

fn target_json(target: Target) -> Json {
  json.object([
    #("incarnation", incarnation_json(target.incarnation)),
    #("os", os_process_json(target.os)),
    #("role", json.string(target.role)),
  ])
}

fn target_decoder() -> Decoder(Target) {
  use incarnation <- decode.field("incarnation", incarnation_decoder())
  use os <- decode.field("os", os_process_decoder())
  use role <- decode.field("role", decode.string)

  decode.success(Target(incarnation:, os:, role:))
}

fn runtime_json(runtime: Runtime) -> Json {
  json.object([
    #("otp_release", json.string(runtime.otp_release)),
    #("erts_version", json.string(runtime.erts_version)),
    #("emulator_flavor", json.string(runtime.emulator_flavor)),
    #("wordsize", json.int(runtime.wordsize)),
    #("schedulers", json.int(runtime.schedulers)),
    #("dirty_cpu_schedulers", json.int(runtime.dirty_cpu_schedulers)),
    #("flags", json.array(runtime.flags, json.string)),
  ])
}

fn runtime_decoder() -> Decoder(Runtime) {
  use otp_release <- decode.field("otp_release", decode.string)
  use erts_version <- decode.field("erts_version", decode.string)
  use emulator_flavor <- decode.field("emulator_flavor", decode.string)
  use wordsize <- decode.field("wordsize", decode.int)
  use schedulers <- decode.field("schedulers", decode.int)
  use dirty_cpu_schedulers <- decode.field("dirty_cpu_schedulers", decode.int)
  use flags <- decode.field("flags", decode.list(decode.string))

  decode.success(Runtime(
    otp_release:,
    erts_version:,
    emulator_flavor:,
    wordsize:,
    schedulers:,
    dirty_cpu_schedulers:,
    flags:,
  ))
}

fn build_json(build: Build) -> Json {
  json.object([
    #("application", json.string(build.application)),
    #("version", json.string(build.version)),
    #("revision", json.string(build.revision)),
    #("compiler", json.string(build.compiler)),
  ])
}

fn build_decoder() -> Decoder(Build) {
  use application <- decode.field("application", decode.string)
  use version <- decode.field("version", decode.string)
  use revision <- decode.field("revision", decode.string)
  use compiler <- decode.field("compiler", decode.string)

  decode.success(Build(application:, version:, revision:, compiler:))
}

fn workload_json(workload: Workload) -> Json {
  json.object([
    #("label", json.string(workload.label)),
    #(
      "sessions",
      json.array(workload.sessions, fn(pair) {
        json.object([
          #("name", json.string(pair.0)),
          #("count", json.int(pair.1)),
        ])
      }),
    ),
    #("warmup_ms", json.int(workload.warmup_ms)),
    #("notes", json.string(workload.notes)),
  ])
}

fn workload_decoder() -> Decoder(Workload) {
  use label <- decode.field("label", decode.string)
  use sessions <- decode.field("sessions", decode.list(count_decoder()))
  use warmup_ms <- decode.field("warmup_ms", decode.int)
  use notes <- decode.field("notes", decode.string)

  decode.success(Workload(label:, sessions:, warmup_ms:, notes:))
}

fn count_decoder() -> Decoder(#(String, Int)) {
  use name <- decode.field("name", decode.string)
  use count <- decode.field("count", decode.int)

  decode.success(#(name, count))
}

fn budgets_json(budgets: Budgets) -> Json {
  json.object([
    #("top_k", json.int(budgets.top_k)),
    #("max_events", json.int(budgets.max_events)),
    #("deadline_ms", json.int(budgets.deadline_ms)),
  ])
}

fn budgets_decoder() -> Decoder(Budgets) {
  use top_k <- decode.field("top_k", decode.int)
  use max_events <- decode.field("max_events", decode.int)
  use deadline_ms <- decode.field("deadline_ms", decode.int)

  decode.success(Budgets(top_k:, max_events:, deadline_ms:))
}

fn collection_json(collection: Collection) -> Json {
  json.object([
    #("method", json.string(collection.method)),
    #("cadence", cadence_json(collection.cadence)),
    #("budgets", budgets_json(collection.budgets)),
  ])
}

fn collection_decoder() -> Decoder(Collection) {
  use method <- decode.field("method", decode.string)
  use cadence <- decode.field("cadence", cadence_decoder())
  use budgets <- decode.field("budgets", budgets_decoder())

  decode.success(Collection(method:, cadence:, budgets:))
}

/// Encode the provenance block of a capture header.
pub fn provenance_json(provenance: Provenance) -> Json {
  json.object([
    #("producer", producer_json(provenance.producer)),
    #("target", target_json(provenance.target)),
    #("runtime", runtime_json(provenance.runtime)),
    #("build", build_json(provenance.build)),
    #("workload", workload_json(provenance.workload)),
    #("collection", collection_json(provenance.collection)),
  ])
}

/// Decode the provenance block of a capture header.
pub fn provenance_decoder() -> Decoder(Provenance) {
  use producer <- decode.field("producer", producer_decoder())
  use target <- decode.field("target", target_decoder())
  use runtime <- decode.field("runtime", runtime_decoder())
  use build <- decode.field("build", build_decoder())
  use workload <- decode.field("workload", workload_decoder())
  use collection <- decode.field("collection", collection_decoder())

  decode.success(Provenance(
    producer:,
    target:,
    runtime:,
    build:,
    workload:,
    collection:,
  ))
}

// ----------------------------------------------------------------- audit

fn stage_decoder() -> Decoder(Stage) {
  parsed("an audit stage", AuthorizeStage, fn(code) {
    list.find([AuthorizeStage, PlanStage, ConfirmStage], fn(stage) {
      policy.stage_code(stage) == code
    })
  })
}

/// The fields of an audit record, without the record tag.
pub fn audit_fields(entry: AuditEntry) -> List(#(String, Json)) {
  let decision = case entry.decision {
    Allowed -> [#("decision", json.string("allowed"))]
    Denied(reason:) -> [
      #("decision", json.string("denied")),
      #("reason", json.string(reason)),
    ]
  }

  list.flatten([
    [
      #("at_ms", json.int(entry.at_ms)),
      #("stage", json.string(policy.stage_code(entry.stage))),
      #("principal", json.string(entry.principal)),
      #("command", json.string(entry.command)),
    ],
    decision,
  ])
}

fn decision_decoder() -> Decoder(AuditDecision) {
  use code <- decode.field("decision", decode.string)

  case code {
    "allowed" -> decode.success(Allowed)
    "denied" -> {
      use reason <- decode.field("reason", decode.string)
      decode.success(Denied(reason:))
    }
    _ -> decode.failure(Allowed, "allowed or denied")
  }
}

/// Decode the fields written by `audit_fields`.
pub fn audit_decoder() -> Decoder(AuditEntry) {
  use at_ms <- decode.field("at_ms", decode.int)
  use stage <- decode.field("stage", stage_decoder())
  use principal <- decode.field("principal", decode.string)
  use command <- decode.field("command", decode.string)
  use decision <- decode.then(decision_decoder())

  decode.success(AuditEntry(at_ms:, stage:, principal:, command:, decision:))
}
