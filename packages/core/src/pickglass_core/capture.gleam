//// The `pickglass.capture/1` format: records, their JSON codecs, and a
//// reader that is honest about what it was given.
////
//// A capture is a stream of newline-delimited JSON records, each with a
//// `t` field naming its kind. The format is append-only so a live recorder
//// and a long soak write the same records, and a reader can tell a file
//// that ended cleanly from one that was cut short: only a `footer` record
//// whose counts match what was read makes a capture `Complete`. A file with
//// no footer reads as `Partial(NoFooter)`.
////
//// The reader is strict where strictness protects a conclusion and lenient
//// where leniency keeps data. It refuses a header whose schema major it
//// does not know. It keeps a record of an unknown kind as an
//// `UnknownRecord`, counted and reported, so a newer producer's extra
//// records are neither dropped silently nor allowed to break the reader.
//// A malformed final line is treated as a torn write and set aside; a
//// malformed line followed by anything else is an error, because the file
//// is then corrupt rather than cut short.
////
//// This module does no I/O and computes no digest. The footer carries a
//// typed `Digest` slot: the side that owns the bytes hashes `body_text`
//// (every line before the footer, each ending in a newline) with SHA-256
//// and passes the result to `footer_for`; a reader hands the claimed digest
//// back through `Capture.footer` for the I/O side to verify with
//// `verify_digest`.
////
//// The `profile` record's payload is a type parameter, `p`. The analysis
//// modules own what a profile is; the codec takes an encoder and a decoder
//// for it, so this module never needs to know. Tests here use a plain
//// string payload.
////
//// ## Flow
////
//// - Reading: `new_reader`, then `feed` per line, then `finish`; `read`
////   does all three over a whole text.
//// - Writing: `encode_record` per record, `body_text` for the digest,
////   `footer_for` and `encode_record` for the footer.
//// - `decode_line` is the single-record decoder both paths share.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass_core/codec
import pickglass_core/measure.{
  type Coverage, type Measurement, type Outcome, type Series,
}
import pickglass_core/owner.{type Source}
import pickglass_core/policy.{type AuditEntry}
import pickglass_core/provenance.{type Provenance}
import pickglass_core/readings
import pickglass_core/trace_codec
import pickglass_core/wire

// ----------------------------------------------------------------- schema

/// The schema string a header of this format carries.
pub const schema = "pickglass.capture/1"

/// The schema major this module reads and writes.
pub const supported_major = 1

/// The longest line the reader accepts, in bytes.
pub const max_line_bytes = 4_194_304

/// The major version in a schema string such as `pickglass.capture/1` or
/// `pickglass.capture/1.2`, or an error if the string is not of that form.
///
/// ## Examples
///
/// ```gleam
/// capture.schema_major("pickglass.capture/1.2")
/// // -> Ok(1)
///
/// capture.schema_major("other/1")
/// // -> Error(Nil)
/// ```
pub fn schema_major(text: String) -> Result(Int, Nil) {
  case text {
    "pickglass.capture/" <> version ->
      case string.split(version, ".") {
        [major] | [major, _] -> int.parse(major)
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

// ---------------------------------------------------------------- records

/// What the file says about its own origin.
pub type Header {
  Header(
    /// An identifier for this capture, unique per capture.
    capture_id: String,
    /// What was measured, on what, how.
    provenance: Provenance,
    /// The redaction policy applied when the capture was written.
    redaction: String,
  )
}

/// A reading of the clocks involved, so timestamps from the agent and the
/// viewer can be put on one axis with a stated uncertainty.
pub type Clock {
  Clock(
    agent_monotonic_ns: Int,
    agent_system_ms: Int,
    viewer_system_ms: Int,
    round_trip_ns: Int,
  )
}

/// A block of interned strings. Value `i` of the block has index
/// `base + i`.
pub type Strings {
  Strings(base: Int, values: List(String))
}

/// An owner instance.
pub type OwnerDef {
  OwnerDef(
    id: Int,
    kind: String,
    /// The index of the display string in the strings table.
    display: Int,
    parent: Option(Int),
    source: Source,
  )
}

/// A BEAM process the capture mentions.
pub type Proc {
  Proc(
    /// The reference other records use for this process.
    ref: Int,
    pid_text: String,
    /// The census epoch the agent first saw it in.
    birth_epoch: Int,
    first_seen_ms: Int,
    owner: Option(Int),
    registered_name: Option(String),
    /// The id of the function it started in.
    initial_call: Option(Int),
  )
}

/// How exact a function's source line is.
pub type LinePrecision {
  /// The line is the line of the call or definition.
  ExactLine

  /// The line is the function's first line only.
  FunctionLevel

  /// There is no source mapping.
  NoLine
}

/// A function and where it is defined.
pub type FunctionDef {
  FunctionDef(
    id: Int,
    module: String,
    function: String,
    arity: Int,
    file: Option(String),
    line: Option(Int),
    precision: LinePrecision,
  )
}

/// A stack of function ids, leaf first.
pub type Stack {
  Stack(id: Int, frames: List(Int))
}

/// A block of readings for one series: parallel lists of one entry per
/// reading.
pub type Samples {
  Samples(
    series: Int,
    timestamps_ms: List(Int),
    intervals_ms: List(Int),
    values: List(Measurement),
  )
}

/// What a profile's values came from.
pub type ProfileSource {
  SampledStacks
  TracedCalls
  TracedCounters
  AllocationCounts
}

/// A profile. `payload` is the analysis modules' own representation of its
/// value types and rows.
pub type Profile(p) {
  Profile(id: Int, source: ProfileSource, payload: p)
}

/// A block of timeline events on one track.
///
/// The first five fields are the format's own and are all a generic reader
/// needs. A tracing probe's record also carries what the probe returned
/// whole in `traced`, because slices of microseconds do not survive a
/// millisecond timestamp, and the stop reason and the per-process totals
/// have no place in the other fields. A reader that does not know `traced`
/// still sees the slices, rounded to milliseconds.
pub type Events {
  Events(
    track: Int,
    kind: String,
    timestamps_ms: List(Int),
    durations_ms: List(Int),
    args: List(String),
    /// A tracing probe's result, when this record holds one.
    traced: Option(Traced),
  )
}

/// What a tracing probe returned, kept in an `events` record.
pub type Traced {
  /// A scheduling and garbage collection probe: per-process totals, the run
  /// and collection slices, and the node-wide threshold events.
  SchedulingTraced(snapshot: wire.EventsSnapshot)

  /// A call tree probe's result. The viewer keeps the call paths in the
  /// probe's `profile` record, so its snapshot here carries none.
  CallTreeTraced(snapshot: wire.CalltraceSnapshot)
}

/// The `events` record of a scheduling and garbage collection probe. The
/// generic fields hold each slice rounded to milliseconds, the process it
/// belongs to and its kind, so a reader that does not know the probe's own
/// field still has the timeline.
///
/// ## Examples
///
/// ```gleam
/// capture.scheduling_events(snapshot)
/// ```
pub fn scheduling_events(snapshot: wire.EventsSnapshot) -> Events {
  Events(
    track: 0,
    kind: scheduling_kind,
    timestamps_ms: list.map(snapshot.slices, fn(slice) {
      slice.start_ns / 1_000_000
    }),
    durations_ms: list.map(snapshot.slices, fn(slice) {
      slice.duration_ns / 1_000_000
    }),
    args: list.map(snapshot.slices, fn(slice) {
      process_text(snapshot.processes, slice.process)
      <> " "
      <> trace_codec.kind_code(slice.kind)
    }),
    traced: Some(SchedulingTraced(snapshot)),
  )
}

/// The `events` record of a call tree probe's slices, without the paths.
///
/// ## Examples
///
/// ```gleam
/// capture.call_tree_events(snapshot)
/// ```
pub fn call_tree_events(snapshot: wire.CalltraceSnapshot) -> Events {
  Events(
    track: 0,
    kind: call_tree_kind,
    timestamps_ms: list.map(snapshot.slices, fn(slice) {
      slice.start_ns / 1_000_000
    }),
    durations_ms: list.map(snapshot.slices, fn(slice) {
      slice.duration_ns / 1_000_000
    }),
    args: list.map(snapshot.slices, fn(slice) {
      case list.drop(snapshot.processes, slice.process) {
        [pid, ..] -> pid
        [] -> "?"
      }
      <> " "
      <> case list.drop(snapshot.frames, slice.frame) {
        [frame, ..] ->
          frame.module
          <> ":"
          <> frame.function
          <> "/"
          <> int.to_string(frame.arity)
        [] -> "?"
      }
    }),
    traced: Some(CallTreeTraced(wire.CalltraceSnapshot(..snapshot, paths: []))),
  )
}

/// The `kind` of the `events` record of a scheduling and garbage collection
/// probe.
pub const scheduling_kind = "scheduling_gc"

/// The `kind` of the `events` record of a call tree probe.
pub const call_tree_kind = "call_tree"

fn process_text(processes: List(wire.TracedProcess), index: Int) -> String {
  case list.drop(processes, index) {
    [process, ..] -> process.pid_text
    [] -> "?"
  }
}

/// A named point in time: a window start, a session close, a restart.
pub type Checkpoint {
  Checkpoint(name: String, agent_monotonic_ns: Int, system_ms: Int)
}

/// What a probe cost the target, the observer effect.
pub type ProbeCost {
  ProbeCost(
    probe: String,
    /// What the probe enabled, such as trace flags.
    enabled: List(String),
    events: Measurement,
    collector_reductions: Measurement,
    bytes: Measurement,
    wall_ms: Measurement,
    /// How the probe ended. `Unrecorded` for a capture that did not keep it.
    outcome: Outcome,
    /// How many functions or processes the agent matched, when it said.
    matched: Option(Int),
  )
}

/// A SHA-256 digest of the capture body, as lowercase hex. Core never
/// computes one; it is a slot the I/O side fills and checks.
pub opaque type Digest {
  Digest(hex: String)
}

/// Build a digest from 64 lowercase hex characters.
///
/// ## Examples
///
/// ```gleam
/// capture.digest("0000000000000000000000000000000000000000000000000000000000000000")
/// // -> Ok(_)
///
/// capture.digest("abc")
/// // -> Error(Nil)
/// ```
pub fn digest(hex: String) -> Result(Digest, Nil) {
  let valid =
    string.byte_size(hex) == 64
    && list.all(string.to_graphemes(hex), fn(c) {
      string.contains("0123456789abcdef", c)
    })

  case valid {
    True -> Ok(Digest(hex:))
    False -> Error(Nil)
  }
}

/// The hex text of a digest.
pub fn digest_hex(digest: Digest) -> String {
  digest.hex
}

/// The end of a capture: how many records of each kind precede it and the
/// digest of the body.
pub type Footer {
  Footer(
    /// Records of each kind before the footer, the header included,
    /// ordered by kind.
    counts: List(#(String, Int)),
    digest: Digest,
  )
}

/// One line of a capture.
pub type Record(p) {
  HeaderRecord(Header)
  ClockRecord(Clock)
  StringsRecord(Strings)
  OwnerRecord(OwnerDef)
  ProcRecord(Proc)
  FunctionRecord(FunctionDef)
  StackRecord(Stack)
  SeriesRecord(Series)
  SamplesRecord(Samples)
  ProfileRecord(Profile(p))
  EventsRecord(Events)
  CoverageRecord(Coverage)
  CheckpointRecord(Checkpoint)
  ProbeCostRecord(ProbeCost)
  AuditRecord(AuditEntry)

  /// What an `owners_detail` pass adds to a census: initial calls and ETS
  /// per owner. Absent from captures written before it existed.
  OwnersDetailRecord(readings.OwnersDetail)

  /// An ETS table listing: the largest tables by memory, never contents.
  EtsRecord(readings.EtsListing)

  /// The binaries one process held when the operator read them.
  BinariesRecord(readings.BinariesReading)
  FooterRecord(Footer)

  /// A record of a kind this build does not know, kept whole so it can be
  /// counted, reported and passed through.
  UnknownRecord(kind: String, line: String)
}

/// The `t` value of a record.
///
/// ## Examples
///
/// ```gleam
/// capture.kind_of(StackRecord(Stack(1, [])))
/// // -> "stack"
/// ```
pub fn kind_of(record: Record(p)) -> String {
  case record {
    HeaderRecord(_) -> "header"
    ClockRecord(_) -> "clock"
    StringsRecord(_) -> "strings"
    OwnerRecord(_) -> "owner"
    ProcRecord(_) -> "proc"
    FunctionRecord(_) -> "fn"
    StackRecord(_) -> "stack"
    SeriesRecord(_) -> "series"
    SamplesRecord(_) -> "samples"
    ProfileRecord(_) -> "profile"
    EventsRecord(_) -> "events"
    CoverageRecord(_) -> "coverage"
    CheckpointRecord(_) -> "checkpoint"
    ProbeCostRecord(_) -> "perturbation"
    AuditRecord(_) -> "audit"
    OwnersDetailRecord(_) -> "owners_detail"
    EtsRecord(_) -> "ets_tables"
    BinariesRecord(_) -> "binaries"
    FooterRecord(_) -> "footer"
    UnknownRecord(kind:, ..) -> kind
  }
}

// -------------------------------------------------------------- encoding

/// Encode one record as one line, without the trailing newline.
/// `encode_profile` encodes a profile payload; an unknown record is written
/// back exactly as it was read.
///
/// ## Examples
///
/// ```gleam
/// capture.encode_record(StackRecord(Stack(id: 1, frames: [2, 3])), json.string)
/// // -> "{\"t\":\"stack\",\"id\":1,\"frames\":[2,3]}"
/// ```
pub fn encode_record(
  record: Record(p),
  encode_profile: fn(p) -> Json,
) -> String {
  case record {
    UnknownRecord(line:, ..) -> line
    HeaderRecord(_)
    | ClockRecord(_)
    | StringsRecord(_)
    | OwnerRecord(_)
    | ProcRecord(_)
    | FunctionRecord(_)
    | StackRecord(_)
    | SeriesRecord(_)
    | SamplesRecord(_)
    | ProfileRecord(_)
    | EventsRecord(_)
    | CoverageRecord(_)
    | CheckpointRecord(_)
    | ProbeCostRecord(_)
    | AuditRecord(_)
    | OwnersDetailRecord(_)
    | EtsRecord(_)
    | BinariesRecord(_)
    | FooterRecord(_) ->
      json.to_string(
        json.object([
          #("t", json.string(kind_of(record))),
          ..fields_of(record, encode_profile)
        ]),
      )
  }
}

fn fields_of(
  record: Record(p),
  encode_profile: fn(p) -> Json,
) -> List(#(String, Json)) {
  case record {
    HeaderRecord(header) -> [
      #("schema", json.string(schema)),
      #("capture_id", json.string(header.capture_id)),
      #("provenance", codec.provenance_json(header.provenance)),
      #("redaction", json.string(header.redaction)),
    ]
    ClockRecord(clock) -> [
      #("agent_monotonic_ns", json.int(clock.agent_monotonic_ns)),
      #("agent_system_ms", json.int(clock.agent_system_ms)),
      #("viewer_system_ms", json.int(clock.viewer_system_ms)),
      #("round_trip_ns", json.int(clock.round_trip_ns)),
    ]
    StringsRecord(strings) -> [
      #("base", json.int(strings.base)),
      #("values", json.array(strings.values, json.string)),
    ]
    OwnerRecord(def) -> [
      #("id", json.int(def.id)),
      #("kind", json.string(def.kind)),
      #("display", json.int(def.display)),
      #("parent", json.nullable(def.parent, json.int)),
      #("source", json.string(owner.source_code(def.source))),
    ]
    ProcRecord(proc) -> [
      #("ref", json.int(proc.ref)),
      #("pid", json.string(proc.pid_text)),
      #("birth_epoch", json.int(proc.birth_epoch)),
      #("first_seen_ms", json.int(proc.first_seen_ms)),
      #("owner", json.nullable(proc.owner, json.int)),
      #("name", json.nullable(proc.registered_name, json.string)),
      #("initial_call", json.nullable(proc.initial_call, json.int)),
    ]
    FunctionRecord(function) -> [
      #("id", json.int(function.id)),
      #("module", json.string(function.module)),
      #("function", json.string(function.function)),
      #("arity", json.int(function.arity)),
      #("file", json.nullable(function.file, json.string)),
      #("line", json.nullable(function.line, json.int)),
      #("precision", json.string(precision_code(function.precision))),
    ]
    StackRecord(stack) -> [
      #("id", json.int(stack.id)),
      #("frames", json.array(stack.frames, json.int)),
    ]
    SeriesRecord(series) -> codec.series_fields(series)
    SamplesRecord(samples) ->
      list.append(
        [
          #("series", json.int(samples.series)),
          #("timestamps_ms", json.array(samples.timestamps_ms, json.int)),
          #("intervals_ms", json.array(samples.intervals_ms, json.int)),
        ],
        codec.column_json(samples.values),
      )
    ProfileRecord(profile) -> [
      #("id", json.int(profile.id)),
      #("source", json.string(profile_source_code(profile.source))),
      #("payload", encode_profile(profile.payload)),
    ]
    EventsRecord(events) ->
      list.append(
        [
          #("track", json.int(events.track)),
          #("kind", json.string(events.kind)),
          #("timestamps_ms", json.array(events.timestamps_ms, json.int)),
          #("durations_ms", json.array(events.durations_ms, json.int)),
          #("args", json.array(events.args, json.string)),
        ],
        case events.traced {
          None -> []
          Some(traced) -> [#("traced", traced_json(traced))]
        },
      )
    CoverageRecord(coverage) -> codec.coverage_fields(coverage)
    CheckpointRecord(checkpoint) -> [
      #("name", json.string(checkpoint.name)),
      #("agent_monotonic_ns", json.int(checkpoint.agent_monotonic_ns)),
      #("system_ms", json.int(checkpoint.system_ms)),
    ]
    ProbeCostRecord(cost) -> [
      #("probe", json.string(cost.probe)),
      #("enabled", json.array(cost.enabled, json.string)),
      #("events", codec.measurement_json(cost.events)),
      #(
        "collector_reductions",
        codec.measurement_json(cost.collector_reductions),
      ),
      #("bytes", codec.measurement_json(cost.bytes)),
      #("wall_ms", codec.measurement_json(cost.wall_ms)),
      #("matched", json.nullable(cost.matched, json.int)),
      ..codec.outcome_fields(cost.outcome)
    ]
    AuditRecord(entry) -> codec.audit_fields(entry)
    OwnersDetailRecord(detail) -> readings.owners_detail_fields(detail)
    EtsRecord(listing) -> readings.ets_listing_fields(listing)
    BinariesRecord(reading) -> readings.binaries_fields(reading)
    FooterRecord(footer) -> [
      #(
        "counts",
        json.object(
          list.map(footer.counts, fn(pair) { #(pair.0, json.int(pair.1)) }),
        ),
      ),
      #("digest", json.string("sha256:" <> footer.digest.hex)),
    ]
    UnknownRecord(..) -> []
  }
}

fn precision_code(precision: LinePrecision) -> String {
  case precision {
    ExactLine -> "exact"
    FunctionLevel -> "function_level"
    NoLine -> "none"
  }
}

fn profile_source_code(source: ProfileSource) -> String {
  case source {
    SampledStacks -> "sampled_stacks"
    TracedCalls -> "traced_calls"
    TracedCounters -> "traced_counters"
    AllocationCounts -> "allocation_counts"
  }
}

// -------------------------------------------------------------- decoding

/// Why one line did not decode to a record.
pub type LineError {
  /// The line is not valid JSON.
  NotJson(detail: String)

  /// The line is JSON but has no string `t` field.
  NoKind

  /// The header names a schema major this build does not read.
  UnsupportedSchema(found: String)

  /// The record has a known kind and does not decode as that kind.
  BadRecord(kind: String, detail: String)
}

/// Decode one line. A line of an unknown kind decodes to an
/// `UnknownRecord`; a line of a known kind that does not fit its shape is a
/// `BadRecord`. `profile` decodes the payload of a profile record.
///
/// This function is total: every string, however malformed, gives `Ok` or
/// `Error`.
///
/// ## Examples
///
/// ```gleam
/// capture.decode_line("{\"t\":\"future\"}", decode.string)
/// // -> Ok(UnknownRecord("future", "{\"t\":\"future\"}"))
///
/// capture.decode_line("not json", decode.string)
/// // -> Error(NotJson(_))
/// ```
pub fn decode_line(
  line: String,
  profile: Decoder(p),
) -> Result(Record(p), LineError) {
  use value <- result.try(
    json.parse(line, decode.dynamic)
    |> result.map_error(fn(error) { NotJson(detail: string.inspect(error)) }),
  )
  use kind <- result.try(
    decode.run(value, decode.field("t", decode.string, decode.success))
    |> result.replace_error(NoKind),
  )
  use _ <- result.try(check_schema(kind, value))

  case record_decoder(kind, profile) {
    Ok(decoder) ->
      decode.run(value, decoder)
      |> result.map_error(fn(errors) {
        BadRecord(kind:, detail: describe_errors(errors))
      })
    Error(Nil) -> Ok(UnknownRecord(kind:, line:))
  }
}

// A header of another major is refused before its body is looked at: a
// newer producer may have changed any field of it.
fn check_schema(kind: String, value: decode.Dynamic) -> Result(Nil, LineError) {
  case kind {
    "header" ->
      case
        decode.run(value, decode.field("schema", decode.string, decode.success))
      {
        Ok(found) ->
          case schema_major(found) {
            Ok(major) if major == supported_major -> Ok(Nil)
            Ok(_) | Error(Nil) -> Error(UnsupportedSchema(found:))
          }
        Error(errors) ->
          Error(BadRecord(kind:, detail: describe_errors(errors)))
      }
    _ -> Ok(Nil)
  }
}

fn describe_errors(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "unknown decode error"
    [decode.DecodeError(expected:, found:, path:), ..] ->
      "expected "
      <> expected
      <> ", found "
      <> found
      <> " at "
      <> string.join(path, "/")
  }
}

fn record_decoder(
  kind: String,
  profile: Decoder(p),
) -> Result(Decoder(Record(p)), Nil) {
  case kind {
    "header" -> Ok(decode.map(header_decoder(), HeaderRecord))
    "clock" -> Ok(decode.map(clock_decoder(), ClockRecord))
    "strings" -> Ok(decode.map(strings_decoder(), StringsRecord))
    "owner" -> Ok(decode.map(owner_decoder(), OwnerRecord))
    "proc" -> Ok(decode.map(proc_decoder(), ProcRecord))
    "fn" -> Ok(decode.map(function_decoder(), FunctionRecord))
    "stack" -> Ok(decode.map(stack_decoder(), StackRecord))
    "series" -> Ok(decode.map(codec.series_decoder(), SeriesRecord))
    "samples" -> Ok(decode.map(samples_decoder(), SamplesRecord))
    "profile" -> Ok(decode.map(profile_decoder(profile), ProfileRecord))
    "events" -> Ok(decode.map(events_decoder(), EventsRecord))
    "coverage" -> Ok(decode.map(codec.coverage_decoder(), CoverageRecord))
    "checkpoint" -> Ok(decode.map(checkpoint_decoder(), CheckpointRecord))
    "perturbation" -> Ok(decode.map(cost_decoder(), ProbeCostRecord))
    "audit" -> Ok(decode.map(codec.audit_decoder(), AuditRecord))
    "owners_detail" ->
      Ok(decode.map(readings.owners_detail_decoder(), OwnersDetailRecord))
    "ets_tables" -> Ok(decode.map(readings.ets_listing_decoder(), EtsRecord))
    "binaries" -> Ok(decode.map(readings.binaries_decoder(), BinariesRecord))
    "footer" -> Ok(decode.map(footer_decoder(), FooterRecord))
    _ -> Error(Nil)
  }
}

fn header_decoder() -> Decoder(Header) {
  use capture_id <- decode.field("capture_id", decode.string)
  use provenance <- decode.field("provenance", codec.provenance_decoder())
  use redaction <- decode.field("redaction", decode.string)

  decode.success(Header(capture_id:, provenance:, redaction:))
}

fn clock_decoder() -> Decoder(Clock) {
  use agent_monotonic_ns <- decode.field("agent_monotonic_ns", decode.int)
  use agent_system_ms <- decode.field("agent_system_ms", decode.int)
  use viewer_system_ms <- decode.field("viewer_system_ms", decode.int)
  use round_trip_ns <- decode.field("round_trip_ns", decode.int)

  decode.success(Clock(
    agent_monotonic_ns:,
    agent_system_ms:,
    viewer_system_ms:,
    round_trip_ns:,
  ))
}

fn strings_decoder() -> Decoder(Strings) {
  use base <- decode.field("base", decode.int)
  use values <- decode.field("values", decode.list(decode.string))

  decode.success(Strings(base:, values:))
}

fn owner_decoder() -> Decoder(OwnerDef) {
  use id <- decode.field("id", decode.int)
  use kind <- decode.field("kind", decode.string)
  use display <- decode.field("display", decode.int)
  use parent <- decode.field("parent", decode.optional(decode.int))
  use source <- decode.field(
    "source",
    codec.parsed("a source", owner.Declared, owner.parse_source),
  )

  decode.success(OwnerDef(id:, kind:, display:, parent:, source:))
}

fn proc_decoder() -> Decoder(Proc) {
  use ref <- decode.field("ref", decode.int)
  use pid_text <- decode.field("pid", decode.string)
  use birth_epoch <- decode.field("birth_epoch", decode.int)
  use first_seen_ms <- decode.field("first_seen_ms", decode.int)
  use owner <- decode.field("owner", decode.optional(decode.int))
  use registered_name <- decode.field("name", decode.optional(decode.string))
  use initial_call <- decode.field("initial_call", decode.optional(decode.int))

  decode.success(Proc(
    ref:,
    pid_text:,
    birth_epoch:,
    first_seen_ms:,
    owner:,
    registered_name:,
    initial_call:,
  ))
}

fn function_decoder() -> Decoder(FunctionDef) {
  use id <- decode.field("id", decode.int)
  use module <- decode.field("module", decode.string)
  use function <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  use file <- decode.field("file", decode.optional(decode.string))
  use line <- decode.field("line", decode.optional(decode.int))
  use precision <- decode.field(
    "precision",
    codec.parsed("a line precision", NoLine, parse_precision),
  )

  decode.success(FunctionDef(
    id:,
    module:,
    function:,
    arity:,
    file:,
    line:,
    precision:,
  ))
}

fn parse_precision(code: String) -> Result(LinePrecision, Nil) {
  list.find([ExactLine, FunctionLevel, NoLine], fn(precision) {
    precision_code(precision) == code
  })
}

fn stack_decoder() -> Decoder(Stack) {
  use id <- decode.field("id", decode.int)
  use frames <- decode.field("frames", decode.list(decode.int))

  decode.success(Stack(id:, frames:))
}

// The three parallel lists of a samples block must agree in length: a
// block whose timestamps and values drift apart would misattribute every
// reading after the first mismatch.
fn samples_decoder() -> Decoder(Samples) {
  use series <- decode.field("series", decode.int)
  use timestamps_ms <- decode.field("timestamps_ms", decode.list(decode.int))
  use intervals_ms <- decode.field("intervals_ms", decode.list(decode.int))
  use values <- decode.then(codec.column_decoder())

  case same_length(timestamps_ms, values) && same_length(intervals_ms, values) {
    True ->
      decode.success(Samples(series:, timestamps_ms:, intervals_ms:, values:))
    False ->
      decode.failure(
        Samples(series: 0, timestamps_ms: [], intervals_ms: [], values: []),
        "timestamps, intervals and values of equal length",
      )
  }
}

// Two lists have the same length when they run out together.
fn same_length(a: List(x), b: List(y)) -> Bool {
  case a, b {
    [], [] -> True
    [_, ..a], [_, ..b] -> same_length(a, b)
    [], [_, ..] | [_, ..], [] -> False
  }
}

fn profile_decoder(payload: Decoder(p)) -> Decoder(Profile(p)) {
  use id <- decode.field("id", decode.int)
  use source <- decode.field(
    "source",
    codec.parsed("a profile source", SampledStacks, parse_profile_source),
  )
  use payload <- decode.field("payload", payload)

  decode.success(Profile(id:, source:, payload:))
}

fn parse_profile_source(code: String) -> Result(ProfileSource, Nil) {
  list.find(
    [SampledStacks, TracedCalls, TracedCounters, AllocationCounts],
    fn(source) { profile_source_code(source) == code },
  )
}

fn events_decoder() -> Decoder(Events) {
  use track <- decode.field("track", decode.int)
  use kind <- decode.field("kind", decode.string)
  use timestamps_ms <- decode.field("timestamps_ms", decode.list(decode.int))
  use durations_ms <- decode.field("durations_ms", decode.list(decode.int))
  use args <- decode.field("args", decode.list(decode.string))
  use traced <- decode.optional_field(
    "traced",
    None,
    decode.map(traced_decoder(), Some),
  )

  decode.success(Events(
    track:,
    kind:,
    timestamps_ms:,
    durations_ms:,
    args:,
    traced:,
  ))
}

fn traced_json(traced: Traced) -> Json {
  case traced {
    SchedulingTraced(snapshot:) ->
      json.object([
        #("probe", json.string(scheduling_kind)),
        #("result", trace_codec.events_json(snapshot)),
      ])
    CallTreeTraced(snapshot:) ->
      json.object([
        #("probe", json.string(call_tree_kind)),
        #("result", trace_codec.calltrace_json(snapshot)),
      ])
  }
}

// The probe's code says which result follows, so a result of the wrong shape
// is refused and not read as the other kind.
fn traced_decoder() -> Decoder(Traced) {
  use probe <- decode.field("probe", decode.string)

  case probe {
    "scheduling_gc" ->
      decode.field("result", trace_codec.events_decoder(), fn(snapshot) {
        decode.success(SchedulingTraced(snapshot:))
      })
    "call_tree" ->
      decode.field("result", trace_codec.calltrace_decoder(), fn(snapshot) {
        decode.success(CallTreeTraced(snapshot:))
      })
    _ ->
      decode.failure(
        SchedulingTraced(snapshot: empty_events()),
        "scheduling_gc or call_tree",
      )
  }
}

fn empty_events() -> wire.EventsSnapshot {
  wire.EventsSnapshot(
    probe_id: 0,
    state: wire.ProbeRunning,
    stop: wire.TraceRunning,
    meter: wire.EventsMeter(
      trace: wire.TraceMeter(
        elapsed_ms: 0,
        events: 0,
        max_events: 0,
        dropped_events: 0,
        in_flight_at_stop: 0,
        peak_queue: 0,
        queue_limit: 0,
        targets_gone: 0,
      ),
      unpaired_events: 0,
      dropped_slices: 0,
      long_events_seen: 0,
      strays: 0,
      long_gc_ms: 0,
      long_schedule_ms: 0,
    ),
    processes: [],
    slices: [],
    long: [],
  )
}

fn checkpoint_decoder() -> Decoder(Checkpoint) {
  use name <- decode.field("name", decode.string)
  use agent_monotonic_ns <- decode.field("agent_monotonic_ns", decode.int)
  use system_ms <- decode.field("system_ms", decode.int)

  decode.success(Checkpoint(name:, agent_monotonic_ns:, system_ms:))
}

fn cost_decoder() -> Decoder(ProbeCost) {
  use probe <- decode.field("probe", decode.string)
  use enabled <- decode.field("enabled", decode.list(decode.string))
  use events <- decode.field("events", codec.measurement_decoder())
  use collector_reductions <- decode.field(
    "collector_reductions",
    codec.measurement_decoder(),
  )
  use bytes <- decode.field("bytes", codec.measurement_decoder())
  use wall_ms <- decode.field("wall_ms", codec.measurement_decoder())
  use matched <- codec.optional_int("matched")
  use outcome <- decode.then(codec.recorded_outcome_decoder())

  decode.success(ProbeCost(
    probe:,
    enabled:,
    events:,
    collector_reductions:,
    bytes:,
    wall_ms:,
    outcome:,
    matched:,
  ))
}

fn footer_decoder() -> Decoder(Footer) {
  use counts <- decode.field("counts", decode.dict(decode.string, decode.int))
  use digest <- decode.field("digest", digest_decoder())

  decode.success(Footer(counts: sorted_counts(counts), digest:))
}

fn sorted_counts(counts: Dict(String, Int)) -> List(#(String, Int)) {
  dict.to_list(counts)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn digest_decoder() -> Decoder(Digest) {
  use text <- decode.then(decode.string)

  case text {
    "sha256:" <> hex ->
      case digest(hex) {
        Ok(digest) -> decode.success(digest)
        Error(Nil) -> decode.failure(Digest(hex: ""), "64 hex characters")
      }
    _ -> decode.failure(Digest(hex: ""), "a sha256: digest")
  }
}

// --------------------------------------------------------------- writing

/// Count records by kind, ordered by kind. The footer carries this tally of
/// everything before it.
///
/// ## Examples
///
/// ```gleam
/// capture.tally([StackRecord(a), StackRecord(b), ClockRecord(c)])
/// // -> [#("clock", 1), #("stack", 2)]
/// ```
pub fn tally(records: List(Record(p))) -> List(#(String, Int)) {
  records
  |> list.fold(dict.new(), fn(counts, record) {
    dict.upsert(counts, kind_of(record), fn(count) {
      option.unwrap(count, 0) + 1
    })
  })
  |> sorted_counts
}

/// The text a digest covers: the header line and every record line, each
/// followed by a newline, and not the footer. The I/O side hashes this
/// string's bytes with SHA-256.
pub fn body_text(
  header: Header,
  records: List(Record(p)),
  encode_profile: fn(p) -> Json,
) -> String {
  [HeaderRecord(header), ..records]
  |> list.map(fn(record) { encode_record(record, encode_profile) <> "\n" })
  |> string.concat
}

/// The footer for a capture body, given the digest the I/O side computed
/// over `body_text`.
pub fn footer_for(
  header: Header,
  records: List(Record(p)),
  digest: Digest,
) -> Footer {
  Footer(counts: tally([HeaderRecord(header), ..records]), digest:)
}

// --------------------------------------------------------------- reading

/// Why a capture could not be read at all.
pub type ReadError {
  /// The first record was not a header, or there was no record.
  MissingHeader

  /// The header names a schema major this build does not read.
  UnsupportedSchemaMajor(found: String)

  /// A line that is not the last is malformed: the file is corrupt, not
  /// just cut short.
  MalformedLine(line: Int, detail: String)

  /// A line exceeds `max_line_bytes`.
  LineTooLong(line: Int)

  /// A second header.
  DuplicateHeader(line: Int)

  /// A record after the footer.
  RecordAfterFooter(line: Int)
}

/// A capture as read.
pub type Capture(p) {
  Capture(
    header: Header,
    /// Every record between the header and the footer, in order, unknown
    /// kinds included.
    records: List(Record(p)),
    /// The footer, if the file had a valid one. Its digest is the file's
    /// claim; core does not verify it.
    footer: Option(Footer),
    /// `Complete` only if a footer was present and its counts matched.
    status: Outcome,
    /// The line number of a malformed final line that was set aside as a
    /// torn write, if any.
    torn_line: Option(Int),
  )
}

/// The incremental reader. Opaque: feed it lines and finish it.
pub opaque type Reader(p) {
  Reader(
    profile: Decoder(p),
    line_number: Int,
    header: Option(Header),
    records: List(Record(p)),
    footer: Option(Footer),
    counts: Dict(String, Int),
    pending: Option(#(Int, ReadError)),
  )
}

/// Start reading a capture. `profile` decodes the payload of profile
/// records.
pub fn new_reader(profile: Decoder(p)) -> Reader(p) {
  Reader(
    profile:,
    line_number: 0,
    header: None,
    records: [],
    footer: None,
    counts: dict.new(),
    pending: None,
  )
}

/// Give the reader the next line, without its newline.
///
/// Blank lines are ignored. A malformed line is held back: if it turns out
/// to be the last line it is a torn write; if another record follows it,
/// the file is corrupt and the error is returned then.
pub fn feed(reader: Reader(p), line: String) -> Result(Reader(p), ReadError) {
  let number = reader.line_number + 1
  let reader = Reader(..reader, line_number: number)

  case string.trim(line) {
    "" -> Ok(reader)
    _ -> feed_record(reader, line, number)
  }
}

fn feed_record(
  reader: Reader(p),
  line: String,
  number: Int,
) -> Result(Reader(p), ReadError) {
  case reader.pending, reader.footer {
    Some(#(_, error)), _ -> Error(error)
    None, Some(_) -> Error(RecordAfterFooter(line: number))
    None, None ->
      case string.byte_size(line) > max_line_bytes {
        True -> Error(LineTooLong(line: number))
        False -> accept(reader, decode_line(line, reader.profile), number)
      }
  }
}

fn accept(
  reader: Reader(p),
  decoded: Result(Record(p), LineError),
  number: Int,
) -> Result(Reader(p), ReadError) {
  case decoded, reader.header {
    Error(UnsupportedSchema(found:)), _ -> Error(UnsupportedSchemaMajor(found:))

    // Before the header, a bad line cannot be a torn tail: there is
    // nothing to be the tail of.
    Error(error), None -> Error(MalformedLine(number, line_error_text(error)))

    Error(error), Some(_) ->
      Ok(
        Reader(
          ..reader,
          pending: Some(#(number, MalformedLine(number, line_error_text(error)))),
        ),
      )

    Ok(HeaderRecord(_)), Some(_) -> Error(DuplicateHeader(line: number))
    Ok(HeaderRecord(header)), None ->
      Ok(Reader(..count(reader, "header"), header: Some(header)))

    Ok(_), None -> Error(MissingHeader)

    Ok(FooterRecord(footer)), Some(_) ->
      Ok(Reader(..reader, footer: Some(footer)))

    Ok(record), Some(_) ->
      Ok(
        Reader(..count(reader, kind_of(record)), records: [
          record,
          ..reader.records
        ]),
      )
  }
}

fn count(reader: Reader(p), kind: String) -> Reader(p) {
  let counts =
    dict.upsert(reader.counts, kind, fn(count) { option.unwrap(count, 0) + 1 })

  Reader(..reader, counts:)
}

fn line_error_text(error: LineError) -> String {
  case error {
    NotJson(detail:) -> "not json: " <> detail
    NoKind -> "no record kind"
    UnsupportedSchema(found:) -> "unsupported schema " <> found
    BadRecord(kind:, detail:) -> kind <> ": " <> detail
  }
}

/// Finish reading and produce the capture.
///
/// The status is `Complete` only when a footer was read and its counts
/// equal the counts of the records read. No footer gives
/// `Partial(NoFooter)`; a footer whose counts disagree gives
/// `Partial(FooterCountMismatch)`.
pub fn finish(reader: Reader(p)) -> Result(Capture(p), ReadError) {
  case reader.header {
    None -> Error(MissingHeader)
    Some(header) ->
      Ok(Capture(
        header:,
        records: list.reverse(reader.records),
        footer: reader.footer,
        status: status_of(reader),
        torn_line: option.map(reader.pending, fn(pending) { pending.0 }),
      ))
  }
}

fn status_of(reader: Reader(p)) -> Outcome {
  case reader.footer {
    None -> measure.Partial(reason: measure.NoFooter)
    Some(footer) ->
      case footer.counts == sorted_counts(reader.counts) {
        True -> measure.Complete
        False -> measure.Partial(reason: measure.FooterCountMismatch)
      }
  }
}

/// Read a whole capture from its text, lines separated by `\n` (a `\r`
/// before it is tolerated).
///
/// ## Examples
///
/// ```gleam
/// capture.read(text, decode.string)
/// // -> Ok(Capture(..)) with status Partial(NoFooter) if the text has no footer
/// ```
pub fn read(
  text: String,
  profile: Decoder(p),
) -> Result(Capture(p), ReadError) {
  string.split(text, "\n")
  |> list.try_fold(new_reader(profile), fn(reader, line) {
    feed(reader, string.trim_end(line))
  })
  |> result.try(finish)
}

/// The count of records of each unknown kind, ordered by kind. A non-empty
/// result means the capture came from a newer producer than this build.
pub fn unknown_counts(capture: Capture(p)) -> List(#(String, Int)) {
  capture.records
  |> list.filter(is_unknown)
  |> tally
}

fn is_unknown(record: Record(p)) -> Bool {
  case record {
    UnknownRecord(..) -> True
    HeaderRecord(_)
    | ClockRecord(_)
    | StringsRecord(_)
    | OwnerRecord(_)
    | ProcRecord(_)
    | FunctionRecord(_)
    | StackRecord(_)
    | SeriesRecord(_)
    | SamplesRecord(_)
    | ProfileRecord(_)
    | EventsRecord(_)
    | CoverageRecord(_)
    | CheckpointRecord(_)
    | ProbeCostRecord(_)
    | AuditRecord(_)
    | OwnersDetailRecord(_)
    | EtsRecord(_)
    | BinariesRecord(_)
    | FooterRecord(_) -> False
  }
}

/// Why a digest check failed.
pub type DigestError {
  /// The capture has no footer, so there is no digest to check.
  NoDigest

  /// The digest computed over the body differs from the footer's.
  DigestMismatch
}

/// Check the footer's digest against one the I/O side computed over the
/// body.
pub fn verify_digest(
  capture: Capture(p),
  computed: Digest,
) -> Result(Nil, DigestError) {
  case capture.footer {
    None -> Error(NoDigest)
    Some(footer) ->
      case footer.digest == computed {
        True -> Ok(Nil)
        False -> Error(DigestMismatch)
      }
  }
}
