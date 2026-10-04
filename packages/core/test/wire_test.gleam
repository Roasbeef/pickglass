import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import pg_data_gen as gen
import pickglass_core/identity
import pickglass_core/owner
import pickglass_core/wire.{
  Labelled, OwnerTotal, ProbeRunning, ProcessRow, Unlabelled,
}
import qcheck.{type Generator}

// ---------------------------------------------------------------- encoding

// The test-side encoder writes the shapes `pickglass_agent/reply.gleam`
// documents, so a round trip checks the decoders against the contract.

fn tuple(items: List(Dynamic)) -> Dynamic {
  dynamic.array(items)
}

fn text(value: String) -> Dynamic {
  dynamic.string(value)
}

fn num(value: Int) -> Dynamic {
  dynamic.int(value)
}

fn encode_owner(reading: wire.OwnerReading) -> Dynamic {
  case reading {
    Unlabelled -> tuple([text("unknown")])
    Labelled(path, role) ->
      tuple([
        text("owner"),
        dynamic.list(
          list.map(path, fn(segment) {
            tuple([text(segment.kind), text(segment.id)])
          }),
        ),
        text(role),
      ])
  }
}

fn encode_row(row: wire.ProcessRow) -> Dynamic {
  tuple([
    text(row.pid_text),
    num(row.memory),
    num(row.total_heap_words),
    num(row.heap_words),
    num(row.stack_words),
    num(row.queue_length),
    num(row.reductions),
    text(row.status),
    text(row.current_function),
    text(row.registered_name),
    encode_owner(row.owner),
  ])
}

fn encode_total(total: wire.OwnerTotal) -> Dynamic {
  tuple([
    encode_owner(total.owner),
    num(total.processes),
    num(total.memory),
    num(total.queue_length),
    num(total.reductions),
  ])
}

fn encode_census(report: wire.CensusSnapshot) -> Dynamic {
  tuple([
    text("census"),
    tuple([
      num(report.coverage.scanned),
      num(report.coverage.total),
      text("scan_budget"),
      num(report.coverage.elapsed_ms),
    ]),
    dynamic.list(list.map(report.rows, encode_row)),
    dynamic.list(list.map(report.owners, encode_total)),
  ])
}

fn encode_counters(report: wire.CountersSnapshot) -> Dynamic {
  tuple([
    text("counters"),
    num(report.probe_id),
    text("running"),
    num(report.matched_functions),
    num(report.elapsed_ms),
    tuple([
      num(report.functions),
      num(report.with_calls),
      num(report.invalidated),
    ]),
    dynamic.list(
      list.map(report.rows, fn(row) {
        tuple([
          text(row.module),
          text(row.function),
          num(row.arity),
          num(row.calls),
          num(row.time_us),
        ])
      }),
    ),
  ])
}

fn envelope(body: Dynamic) -> Dynamic {
  tuple([text("pg"), num(1), text("ref"), body])
}

// -------------------------------------------------------------- generators

fn owner_reading() -> Generator(wire.OwnerReading) {
  qcheck.from_generators(qcheck.constant(Unlabelled), [
    qcheck.map2(gen.small_list(gen.segment()), gen.ident(), fn(path, role) {
      Labelled(path, role)
    }),
  ])
}

fn process_row() -> Generator(wire.ProcessRow) {
  qcheck.map6(
    gen.ident(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.ident(), gen.text(), gen.text()),
    owner_reading(),
    gen.non_negative(),
    fn(pid, words, counts, names, owner, _) {
      ProcessRow(
        pid_text: pid,
        memory: words.0,
        total_heap_words: words.1,
        heap_words: words.2,
        stack_words: counts.0,
        queue_length: counts.1,
        reductions: counts.2,
        status: names.0,
        current_function: names.1,
        registered_name: names.2,
        owner: owner,
      )
    },
  )
}

fn owner_total() -> Generator(wire.OwnerTotal) {
  qcheck.map2(
    owner_reading(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(reading, counts) {
      OwnerTotal(
        owner: reading,
        processes: counts.0,
        memory: counts.1,
        queue_length: counts.2,
        reductions: counts.0,
      )
    },
  )
}

fn census() -> Generator(wire.CensusSnapshot) {
  qcheck.map3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.small_list(process_row()),
    gen.small_list(owner_total()),
    fn(counts, rows, owners) {
      wire.CensusSnapshot(
        coverage: wire.CensusCoverage(
          scanned: counts.0,
          total: counts.1,
          stop: wire.ScanBudgetReached,
          elapsed_ms: counts.2,
        ),
        rows: rows,
        owners: owners,
      )
    },
  )
}

fn function_row() -> Generator(wire.FunctionRow) {
  qcheck.map3(
    gen.tuple2(gen.ident(), gen.ident()),
    gen.non_negative(),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(names, arity, measured) {
      wire.FunctionRow(names.0, names.1, arity, measured.0, measured.1)
    },
  )
}

fn counters() -> Generator(wire.CountersSnapshot) {
  qcheck.map3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.small_list(function_row()),
    fn(a, b, rows) {
      wire.CountersSnapshot(
        probe_id: a.0,
        state: ProbeRunning,
        matched_functions: a.1,
        elapsed_ms: a.2,
        functions: b.0,
        with_calls: b.1,
        invalidated: b.2,
        rows: rows,
      )
    },
  )
}

// Arbitrary terms, nested to a few levels: ints, strings, lists and tuples.
fn junk(depth: Int) -> Generator(Dynamic) {
  let leaf =
    qcheck.from_generators(qcheck.map(qcheck.uniform_int(), dynamic.int), [
      qcheck.map(qcheck.string(), dynamic.string),
    ])

  case depth {
    0 -> leaf
    _ ->
      qcheck.from_generators(leaf, [
        qcheck.map(gen.small_list(junk(depth - 1)), dynamic.array),
        qcheck.map(gen.small_list(junk(depth - 1)), dynamic.list),
      ])
  }
}

// -------------------------------------------------------------- properties

// A census the agent could send decodes to exactly what was sent.
pub fn property_census_round_trips_test() {
  use report <- gen.check(census())

  assert wire.decode_envelope(envelope(encode_census(report)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.CensusReport(report)))
}

pub fn property_counters_round_trip_test() {
  use report <- gen.check(counters())

  assert wire.decode_envelope(envelope(encode_counters(report)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.CountersReport(report)))
}

// Totality: whatever arrives, decoding returns a value and never raises.
// Random terms are almost never a valid envelope, so the result must be an
// error, and a valid reply with one field broken must be an error too.
pub fn property_junk_never_decodes_and_never_crashes_test() {
  use term <- gen.check(junk(3))

  assert is_error(wire.decode_envelope(term))
  assert is_error(wire.decode_reply(term))
}

pub fn property_corrupted_replies_fail_without_crashing_test() {
  use #(report, junk_field) <- gen.check(gen.tuple2(census(), junk(2)))

  let corrupted =
    tuple([text("census"), junk_field, dynamic.list([]), dynamic.list([])])

  assert is_error(wire.decode_reply(corrupted))
  assert is_error(wire.decode_reply(truncated(encode_census(report))))
}

// Dropping the last element of a reply tuple must be an error.
fn truncated(term: Dynamic) -> Dynamic {
  case decode.run(term, decode.list(decode.dynamic)) {
    Ok(items) -> tuple(list.take(items, list.length(items) - 1))
    Error(_) -> tuple([text("census")])
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// ---------------------------------------------------------------- examples

pub fn small_replies_decode_test() {
  assert wire.decode_reply(tuple([text("detached"), text("requested")]))
    == Ok(wire.Detached("requested"))
  assert wire.decode_reply(tuple([text("error"), text("busy"), text("later")]))
    == Ok(wire.Refused("busy", "later"))
  assert wire.decode_reply(tuple([text("unpinned"), num(4)]))
    == Ok(wire.Unpinned(4))
}

pub fn pinned_reply_builds_a_pin_token_test() {
  let body = tuple([text("pinned"), text("boot-1"), num(3), text("<0.91.0>")])

  let assert Ok(wire.Pinned(token, pid_text)) = wire.decode_reply(body)
    as "a well-formed pinned reply decodes"

  assert pid_text == "<0.91.0>"
  assert identity.pin_serial(token) == 3
  assert identity.boot_id_text(identity.pin_boot(token)) == "boot-1"
}

// The identity vocabulary refuses what the agent must never send: a boot id
// outside the allowed alphabet, or a negative serial.
pub fn identity_vocabulary_is_enforced_test() {
  assert is_error(
    wire.decode_reply(
      tuple([text("pinned"), text("has:colon"), num(3), text("<0.1.0>")]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([text("pinned"), text("boot-1"), num(-1), text("<0.1.0>")]),
    ),
  )
}

// A path segment the owner vocabulary refuses is a decode error, never a
// path the rest of the program would not construct.
pub fn owner_segments_are_checked_test() {
  let bad =
    tuple([
      text("owner"),
      dynamic.list([tuple([text("a/b"), text("x")])]),
      text("worker"),
    ])
  let row =
    tuple([
      text("census"),
      tuple([num(1), num(1), text("finished"), num(1)]),
      dynamic.list([]),
      dynamic.list([tuple([bad, num(1), num(1), num(1), num(1)])]),
    ])

  assert is_error(wire.decode_reply(row))
  assert owner.segment("a/b", "x") == Error(Nil)
}

pub fn unknown_tags_and_enumerations_are_errors_test() {
  assert is_error(wire.decode_reply(tuple([text("surprise")])))
  assert is_error(
    wire.decode_reply(
      tuple([
        text("census"),
        tuple([num(1), num(1), text("sideways"), num(1)]),
        dynamic.list([]),
        dynamic.list([]),
      ]),
    ),
  )
  assert is_error(
    wire.decode_envelope(
      tuple([
        text("pg"),
        num(2),
        text("ref"),
        tuple([text("detached"), text("x")]),
      ]),
    ),
  )
}

// The request envelope is exactly what the agent's decoder reads.
pub fn requests_encode_to_the_agent_shape_test() {
  let reply_to = text("pid")
  let reference = text("ref")

  assert wire.encode_request(reply_to, reference, wire.AskPing)
    == tuple([text("pg"), num(1), reply_to, reference, tuple([text("ping")])])
  assert wire.encode_request(reply_to, reference, wire.AskCensus(100, 10))
    == tuple([
      text("pg"),
      num(1),
      reply_to,
      reference,
      tuple([text("census"), num(100), num(10)]),
    ])

  let assert Ok(boot) = identity.boot_id("boot-1") as "valid boot id"
  let assert Ok(token) = identity.pin(boot, 4) as "valid serial"

  assert wire.encode_request(
      reply_to,
      reference,
      wire.AskStartCounters(
        "lists",
        "sort",
        wire.PinnedProcesses([token]),
        5000,
      ),
    )
    == tuple([
      text("pg"),
      num(1),
      reply_to,
      reference,
      tuple([
        text("start_counters"),
        text("lists"),
        text("sort"),
        tuple([
          text("pins"),
          dynamic.list([tuple([text("boot-1"), num(4)])]),
        ]),
        num(5000),
      ]),
    ])
}
