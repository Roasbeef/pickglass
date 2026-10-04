import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pg_data_gen as gen
import pickglass_core/capture.{
  type Header, type Record, FooterRecord, HeaderRecord, UnknownRecord,
}
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/readings
import pickglass_core/wire
import qcheck

fn encode(record: Record(String)) -> String {
  capture.encode_record(record, json.string)
}

fn decode_one(line: String) -> Result(Record(String), capture.LineError) {
  capture.decode_line(line, decode.string)
}

fn read(text: String) -> Result(capture.Capture(String), capture.ReadError) {
  capture.read(text, decode.string)
}

fn a_digest() -> capture.Digest {
  let assert Ok(digest) = capture.digest(string.repeat("ab", 32))
    as "64 hex characters"
  digest
}

// Build the text of a complete capture the way a writer would: body,
// then a footer whose counts come from `tally`.
fn written(header: Header, records: List(Record(String))) -> String {
  let body = capture.body_text(header, records, json.string)
  let footer = capture.footer_for(header, records, a_digest())

  body <> encode(FooterRecord(footer)) <> "\n"
}

// ------------------------------------------------------------ round trips

// Every record kind must read back as exactly what was written.
pub fn property_records_round_trip_test() {
  use record <- gen.check(gen.record())

  assert decode_one(encode(record)) == Ok(record)
}

pub fn property_headers_round_trip_test() {
  use header <- gen.check(gen.header())

  assert decode_one(encode(HeaderRecord(header))) == Ok(HeaderRecord(header))
}

pub fn property_footers_round_trip_test() {
  use #(counts, digest) <- gen.check(gen.tuple2(
    gen.small_list(gen.tuple2(gen.ident(), gen.non_negative())),
    gen.digest(),
  ))
  let counts =
    counts
    |> list.unique
    |> list.key_set("x", 0)
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> dedupe_keys
  let footer = capture.Footer(counts:, digest:)

  assert decode_one(encode(FooterRecord(footer))) == Ok(FooterRecord(footer))
}

fn dedupe_keys(counts: List(#(String, Int))) -> List(#(String, Int)) {
  case counts {
    [#(a, _), #(b, y), ..rest] if a == b -> dedupe_keys([#(b, y), ..rest])
    [first, ..rest] -> [first, ..dedupe_keys(rest)]
    [] -> []
  }
}

pub fn property_whole_captures_round_trip_test() {
  use #(header, records) <- gen.check(gen.tuple2(
    gen.header(),
    gen.small_list(gen.record()),
  ))
  let assert Ok(read) = read(written(header, records)) as "reads"

  assert read.header == header
  assert read.records == records
  assert read.status == measure.Complete
  assert read.torn_line == None
  assert read.footer == Some(capture.footer_for(header, records, a_digest()))
}

// ------------------------------------------------------------ totality

// Cutting a record anywhere before its end leaves invalid JSON, and the
// decoder must say so rather than return a partial record.
pub fn property_truncated_lines_are_refused_test() {
  use #(record, cut) <- gen.check(gen.tuple2(gen.record(), gen.non_negative()))
  let line = encode(record)
  let keep = cut % string.length(line)
  let prefix = string.slice(line, 0, keep)

  assert is_error(decode_one(prefix))
}

pub fn property_arbitrary_text_never_crashes_test() {
  use text <- gen.check(gen.text())

  case decode_one(text) {
    Ok(record) -> {
      // Anything accepted must be stable under re-encoding.
      assert decode_one(encode(record)) == Ok(record)
    }
    Error(_) -> Nil
  }
}

fn json_value(depth: Int) -> qcheck.Generator(json.Json) {
  let leaves = [
    qcheck.constant(json.null()),
    qcheck.map(qcheck.bool(), json.bool),
    qcheck.map(qcheck.uniform_int(), json.int),
    qcheck.map(gen.text(), json.string),
  ]

  case depth {
    0 -> qcheck.from_generators(qcheck.constant(json.null()), leaves)
    _ ->
      qcheck.from_generators(qcheck.constant(json.null()), [
        qcheck.map(qcheck.uniform_int(), json.int),
        qcheck.map(gen.text(), json.string),
        qcheck.map(gen.small_list(json_value(depth - 1)), fn(items) {
          json.array(items, fn(item) { item })
        }),
        qcheck.map(
          gen.small_list(gen.tuple2(gen.text(), json_value(depth - 1))),
          json.object,
        ),
      ])
  }
}

// Arbitrary JSON, with and without a known record kind, must decode to a
// record or an error and never crash; a record kind with the wrong shape is
// an error, never a default-filled record.
pub fn property_arbitrary_json_never_crashes_test() {
  use #(kind, fields) <- gen.check(gen.tuple2(
    gen.one_of("header", [
      "clock", "strings", "owner", "proc", "fn", "stack", "series", "samples",
      "profile", "events", "coverage", "checkpoint", "perturbation", "audit",
      "footer", "future",
    ]),
    gen.small_list(gen.tuple2(gen.ident(), json_value(2))),
  ))
  let line = json.to_string(json.object([#("t", json.string(kind)), ..fields]))

  case decode_one(line) {
    Ok(UnknownRecord(kind: found, line: raw)) -> {
      assert found == "future"
      assert raw == line
    }
    Ok(record) -> {
      assert decode_one(encode(record)) == Ok(record)
    }
    Error(_) -> Nil
  }
}

pub fn malformed_lines_are_classified_test() {
  assert is_not_json(decode_one("not json"))
  assert is_not_json(decode_one(""))
  assert decode_one("[1,2]") == Error(capture.NoKind)
  assert decode_one("{}") == Error(capture.NoKind)
  assert decode_one("{\"t\":3}") == Error(capture.NoKind)
  assert is_bad_record(decode_one("{\"t\":\"stack\"}"))
  assert is_bad_record(decode_one(
    "{\"t\":\"stack\",\"id\":\"x\",\"frames\":[]}",
  ))
}

fn is_not_json(result: Result(a, capture.LineError)) -> Bool {
  case result {
    Error(capture.NotJson(_)) -> True
    Ok(_) | Error(_) -> False
  }
}

fn is_bad_record(result: Result(a, capture.LineError)) -> Bool {
  case result {
    Error(capture.BadRecord(..)) -> True
    Ok(_) | Error(_) -> False
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// ------------------------------------------------ no silent zero readings

// A column position with neither a value nor a reason would be a silent
// zero, and positions with both are contradictory. Both are refused, as
// are columns whose arrays disagree in length.
pub fn samples_columns_are_strict_test() {
  let line = fn(values: String, reasons: String, stamps: String) {
    "{\"t\":\"samples\",\"series\":1,\"timestamps_ms\":"
    <> stamps
    <> ",\"intervals_ms\":"
    <> stamps
    <> ",\"values\":"
    <> values
    <> ",\"reasons\":"
    <> reasons
    <> "}"
  }

  assert is_ok(
    decode_one(line("[1,null]", "[null,\"process_exited\"]", "[1,2]")),
  )
  assert is_ok(decode_one(line("[null]", "[\"not_applicable\"]", "[1]")))
  assert is_error(decode_one(line("[null]", "[null]", "[1]")))
  assert is_error(decode_one(line("[1]", "[\"process_exited\"]", "[1]")))
  assert is_error(decode_one(line("[null]", "[\"zero\"]", "[1]")))
  assert is_error(decode_one(line("[1,2]", "[null]", "[1,2]")))
  assert is_error(decode_one(line("[1]", "[null]", "[1,2]")))
}

fn is_ok(result: Result(a, b)) -> Bool {
  !is_error(result)
}

// ---------------------------------------------------------- the reader

fn a_header() -> Header {
  capture.Header(
    capture_id: "cap-1",
    provenance: gen.sample_provenance(),
    redaction: "none",
  )
}

fn stack_record(id: Int) -> Record(String) {
  capture.StackRecord(capture.Stack(id:, frames: [id]))
}

pub fn a_file_with_no_footer_is_partial_test() {
  let text =
    capture.body_text(
      a_header(),
      [stack_record(1), stack_record(2)],
      json.string,
    )
  let assert Ok(read) = read(text) as "reads"

  assert read.status == measure.Partial(measure.NoFooter)
  assert read.footer == None
  assert read.records == [stack_record(1), stack_record(2)]
}

pub fn a_file_with_only_a_header_is_partial_test() {
  let assert Ok(read) = read(encode(HeaderRecord(a_header()))) as "reads"

  assert read.status == measure.Partial(measure.NoFooter)
  assert read.records == []
}

pub fn a_footer_that_disagrees_with_the_records_is_partial_test() {
  let header = a_header()
  let footer = capture.footer_for(header, [stack_record(1)], a_digest())
  let text =
    capture.body_text(header, [stack_record(1), stack_record(2)], json.string)
    <> encode(FooterRecord(footer))
    <> "\n"
  let assert Ok(read) = read(text) as "reads"

  assert read.status == measure.Partial(measure.FooterCountMismatch)
}

pub fn the_digest_slot_is_checked_by_the_caller_test() {
  let header = a_header()
  let assert Ok(read) = read(written(header, [])) as "reads"
  let assert Ok(other) = capture.digest(string.repeat("cd", 32)) as "hex"

  assert capture.verify_digest(read, a_digest()) == Ok(Nil)
  assert capture.verify_digest(read, other) == Error(capture.DigestMismatch)

  let assert Ok(unfinished) =
    read_text(capture.body_text(header, [], json.string))
  assert capture.verify_digest(unfinished, a_digest())
    == Error(capture.NoDigest)
}

fn read_text(
  text: String,
) -> Result(capture.Capture(String), capture.ReadError) {
  read(text)
}

pub fn digests_must_be_64_lowercase_hex_characters_test() {
  assert is_error(capture.digest(""))
  assert is_error(capture.digest(string.repeat("a", 63)))
  assert is_error(capture.digest(string.repeat("a", 65)))
  assert is_error(capture.digest(string.repeat("A", 64)))
  assert is_error(capture.digest(string.repeat("g", 64)))
  assert is_ok(capture.digest(string.repeat("0", 64)))
}

// An unknown major is refused outright, even though the rest of the header
// is valid.
pub fn an_unknown_schema_major_is_refused_test() {
  let header_line = encode(HeaderRecord(a_header()))
  let newer =
    string.replace(header_line, "pickglass.capture/1", "pickglass.capture/2")

  assert read(newer)
    == Error(capture.UnsupportedSchemaMajor("pickglass.capture/2"))
  assert capture.schema_major("pickglass.capture/1.4") == Ok(1)
  assert capture.schema_major("pickglass.capture/") == Error(Nil)
  assert capture.schema_major("pickglass.capture/x") == Error(Nil)
  assert capture.schema_major("something/1") == Error(Nil)

  // A minor revision of the same major is read.
  let minor =
    string.replace(header_line, "pickglass.capture/1", "pickglass.capture/1.3")
  assert is_ok(read(minor))
}

// A newer producer's extra record kinds are kept, counted and passed
// through unchanged.
pub fn unknown_record_kinds_are_kept_and_counted_test() {
  let header = a_header()
  let future = "{\"t\":\"gpu\",\"x\":[1,2,3]}"
  let body = capture.body_text(header, [], json.string)
  let text =
    body <> future <> "\n" <> future <> "\n" <> encode(stack_record(1)) <> "\n"
  let assert Ok(read) = read(text) as "reads"

  assert capture.unknown_counts(read) == [#("gpu", 2)]
  assert list.filter(read.records, fn(r) { r == UnknownRecord("gpu", future) })
    |> list.length
    == 2
  assert encode(UnknownRecord("gpu", future)) == future
}

// Unknown records are part of the footer's counts, so a footer written by
// the newer producer still matches what an older reader saw.
pub fn footer_counts_include_unknown_kinds_test() {
  let header = a_header()
  let future = UnknownRecord("gpu", "{\"t\":\"gpu\"}")
  let text = written(header, [future, stack_record(1)])
  let assert Ok(read) = read(text) as "reads"

  assert read.status == measure.Complete
}

pub fn a_missing_or_misplaced_header_is_refused_test() {
  assert read("") == Error(capture.MissingHeader)
  assert read(encode(stack_record(1))) == Error(capture.MissingHeader)
  assert read("\n\n") == Error(capture.MissingHeader)

  let header_line = encode(HeaderRecord(a_header()))
  assert read(header_line <> "\n" <> header_line)
    == Error(capture.DuplicateHeader(2))
}

pub fn a_bad_first_line_is_an_error_not_a_torn_tail_test() {
  assert is_malformed(read("garbage"), 1)
}

fn is_malformed(
  result: Result(a, capture.ReadError),
  expected_line: Int,
) -> Bool {
  case result {
    Error(capture.MalformedLine(line:, ..)) -> line == expected_line
    Ok(_) | Error(_) -> False
  }
}

// A malformed last line is a torn write: set aside, and the capture is
// partial. The same line followed by another record is corruption.
pub fn a_torn_final_line_is_set_aside_test() {
  let header = a_header()
  let body = capture.body_text(header, [stack_record(1)], json.string)
  let torn = string.slice(encode(stack_record(2)), 0, 7)
  let assert Ok(read) = read(body <> torn) as "reads"

  assert read.records == [stack_record(1)]
  assert read.torn_line == Some(3)
  assert read.status == measure.Partial(measure.NoFooter)
}

pub fn a_malformed_line_in_the_middle_is_corruption_test() {
  let header = a_header()
  let body = capture.body_text(header, [stack_record(1)], json.string)
  let torn = string.slice(encode(stack_record(2)), 0, 7)

  assert is_malformed(read(body <> torn <> "\n" <> encode(stack_record(3))), 3)
}

pub fn a_torn_footer_leaves_the_capture_partial_test() {
  let header = a_header()
  let text = written(header, [stack_record(1)])
  let cut = string.slice(text, 0, string.length(text) - 5)
  let assert Ok(read) = read(cut) as "reads"

  assert read.status == measure.Partial(measure.NoFooter)
  assert read.footer == None
  assert read.torn_line == Some(3)
}

pub fn records_after_the_footer_are_refused_test() {
  let text = written(a_header(), []) <> encode(stack_record(1)) <> "\n"

  assert read(text) == Error(capture.RecordAfterFooter(3))
}

pub fn blank_lines_and_carriage_returns_are_tolerated_test() {
  let header = a_header()
  let text =
    string.replace(written(header, [stack_record(1)]), "\n", "\r\n\r\n")
  let assert Ok(read) = read(text) as "reads"

  assert read.status == measure.Complete
  assert read.records == [stack_record(1)]
}

pub fn over_long_lines_are_refused_test() {
  let header_line = encode(HeaderRecord(a_header()))
  let long =
    "{\"t\":\"gpu\",\"x\":\""
    <> string.repeat("a", capture.max_line_bytes)
    <> "\"}"

  assert read(header_line <> "\n" <> long) == Error(capture.LineTooLong(2))
}

pub fn the_tally_counts_kinds_in_order_test() {
  assert capture.tally([stack_record(1), stack_record(2)]) == [#("stack", 2)]
  assert capture.tally([]) == []
}

// ---------------------------------------------------- memory readings

fn an_owners_detail() -> Record(String) {
  capture.OwnersDetailRecord(readings.OwnersDetail(
    at_ms: 1000,
    initial_calls: [#("<0.9.0>", "supervisor:my_sup/1")],
    owners: [
      readings.OwnerEts(
        owner: wire.Labelled(
          path: [owner.Segment(kind: "session", id: "abc")],
          role: "gateway",
        ),
        tables: 2,
        bytes: 4096,
      ),
      readings.OwnerEts(owner: wire.Unlabelled, tables: 7, bytes: 9000),
    ],
    ets: wire.EtsPass(
      tables: 9,
      memory_bytes: 13_096,
      skipped: 1,
      stop: wire.EtsDeadline,
    ),
  ))
}

fn an_ets_listing() -> Record(String) {
  capture.EtsRecord(readings.EtsListing(
    at_ms: 1000,
    snapshot: wire.EtsSnapshot(
      coverage: wire.EtsCoverage(
        total: 9,
        counted: 8,
        skipped: 1,
        stop: wire.EtsFinished,
        elapsed_ms: 3,
      ),
      tables: [
        wire.EtsTable(
          id_text: "#Ref<0.1.2.3>",
          name: "",
          owner_pid_text: "<0.9.0>",
          owner: wire.Unlabelled,
          owner_name: "code_server",
          kind: "set",
          objects: 12,
          memory_bytes: 2048,
          protection: "protected",
          heir_pid_text: "",
        ),
      ],
      totals: wire.EtsTotals(tables: 8, objects: 99, memory_bytes: 8192),
    ),
  ))
}

fn a_binaries_reading() -> Record(String) {
  capture.BinariesRecord(readings.BinariesReading(
    at_ms: 2000,
    snapshot: wire.BinariesSnapshot(
      pid_text: "<0.9.0>",
      distinct: 2,
      bytes: 121_000,
      references: 100,
      binaries: [
        wire.BinaryRef(address_text: "7f00aa", bytes: 121_000, refc: 3),
      ],
    ),
  ))
}

pub fn the_memory_readings_round_trip_test() {
  assert decode_one(encode(an_owners_detail())) == Ok(an_owners_detail())
  assert decode_one(encode(an_ets_listing())) == Ok(an_ets_listing())
  assert decode_one(encode(a_binaries_reading())) == Ok(a_binaries_reading())
}

pub fn the_memory_readings_have_their_own_kinds_test() {
  assert capture.kind_of(an_owners_detail()) == "owners_detail"
  assert capture.kind_of(an_ets_listing()) == "ets_tables"
  assert capture.kind_of(a_binaries_reading()) == "binaries"
}

// A capture written before the readings existed reads as it always did, and
// one that has them keeps them in order, counted in the footer.
pub fn a_capture_with_and_without_the_readings_reads_test() {
  let header = a_header()
  let old = written(header, [stack_record(1)])
  let new =
    written(header, [
      stack_record(1),
      an_owners_detail(),
      an_ets_listing(),
      a_binaries_reading(),
    ])

  let assert Ok(before) = read(old) as "old reads"
  let assert Ok(after) = read(new) as "new reads"

  assert before.status == measure.Complete
  assert after.status == measure.Complete
  assert capture.unknown_counts(after) == []
  assert list.contains(after.records, an_ets_listing())
  assert list.contains(after.records, a_binaries_reading())
}

// A record of a known kind with the wrong shape is an error and not a
// default-filled record.
pub fn a_malformed_memory_reading_is_an_error_test() {
  let assert Error(capture.BadRecord(kind: "ets_tables", ..)) =
    decode_one("{\"t\":\"ets_tables\",\"at_ms\":1}")
  let assert Error(capture.BadRecord(kind: "binaries", ..)) =
    decode_one(
      "{\"t\":\"binaries\",\"at_ms\":1,\"pid\":\"<0.1.0>\",\"distinct\":1,\"bytes\":1,\"references\":1,\"binaries\":[{\"address\":\"a\",\"bytes\":\"x\",\"refc\":1}]}",
    )
  let assert Error(capture.BadRecord(kind: "owners_detail", ..)) =
    decode_one(
      "{\"t\":\"owners_detail\",\"at_ms\":1,\"initial_calls\":[],\"owners\":[],\"ets\":{\"tables\":1,\"bytes\":1,\"skipped\":0,\"stop\":\"never\"}}",
    )
}
