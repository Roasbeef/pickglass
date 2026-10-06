import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/result
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

// Sharing the agent adds one request and two replies. A viewer that joins is
// told how many viewers the agent serves, and a viewer that detaches from a
// shared agent is told how many remain.
pub fn shared_attach_wire_round_trips_test() {
  assert wire.decode_reply(tuple([text("joined"), num(2)]))
    == Ok(wire.Joined(2))
  assert wire.decode_reply(tuple([text("left"), num(1)])) == Ok(wire.Left(1))
  assert is_error(wire.decode_reply(tuple([text("joined"), text("two")])))
  assert is_error(wire.decode_reply(tuple([text("left")])))
  assert wire.encode_extended_request(
      text("pid"),
      text("ref"),
      wire.AskJoin("pg1", 30_000, "abc"),
    )
    == tuple([
      text("pg"),
      num(1),
      text("pid"),
      text("ref"),
      tuple([text("join"), text("pg1"), num(30_000), text("abc")]),
    ])
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

// ------------------------------------------------- the added replies
//
// Each reply below has a test-side encoder that writes the shape
// `packages/agent/CLAUDE.md` documents ("Wire requests and replies"), and a
// generator of the domain value. A round trip checks the decoder against the
// documented contract.

fn coverage_term(report: wire.CensusCoverage) -> Dynamic {
  tuple([
    num(report.scanned),
    num(report.total),
    text("scan_budget"),
    num(report.elapsed_ms),
  ])
}

fn census_coverage() -> Generator(wire.CensusCoverage) {
  qcheck.map2(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.non_negative(),
    fn(counts, extra) {
      wire.CensusCoverage(
        scanned: counts.0,
        total: counts.1 + extra,
        stop: wire.ScanBudgetReached,
        elapsed_ms: counts.2,
      )
    },
  )
}

fn census_totals() -> Generator(wire.CensusTotals) {
  qcheck.map2(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(a, b) {
      wire.CensusTotals(
        processes: a.0,
        memory: a.1,
        queue_length: a.2,
        reductions: b.0,
        total_heap_words: b.1,
        owners_tracked: b.2,
        owners_listed: a.0,
      )
    },
  )
}

fn owner_heap_total() -> Generator(wire.OwnerHeapTotal) {
  qcheck.map2(owner_total(), gen.non_negative(), fn(total, words) {
    wire.OwnerHeapTotal(total, words)
  })
}

fn owners_snapshot() -> Generator(wire.OwnersSnapshot) {
  qcheck.map4(
    census_coverage(),
    gen.small_list(process_row()),
    gen.small_list(owner_heap_total()),
    census_totals(),
    fn(coverage, rows, owners, totals) {
      wire.OwnersSnapshot(coverage:, rows:, owners:, totals:)
    },
  )
}

fn encode_owners(report: wire.OwnersSnapshot) -> Dynamic {
  tuple([
    text("owners"),
    coverage_term(report.coverage),
    dynamic.list(list.map(report.rows, encode_row)),
    dynamic.list(
      list.map(report.owners, fn(entry) {
        tuple([
          encode_owner(entry.total.owner),
          num(entry.total.processes),
          num(entry.total.memory),
          num(entry.total.queue_length),
          num(entry.total.reductions),
          num(entry.total_heap_words),
        ])
      }),
    ),
    tuple([
      num(report.totals.processes),
      num(report.totals.memory),
      num(report.totals.queue_length),
      num(report.totals.reductions),
      num(report.totals.total_heap_words),
      num(report.totals.owners_tracked),
      num(report.totals.owners_listed),
    ]),
  ])
}

fn function_memory() -> Generator(wire.FunctionMemory) {
  qcheck.map3(
    gen.tuple2(gen.ident(), gen.ident()),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(names, shape, counted) {
      wire.FunctionMemory(
        names.0,
        names.1,
        shape.0,
        shape.1,
        counted.0,
        counted.1,
      )
    },
  )
}

fn memory_totals() -> Generator(wire.MemoryTotals) {
  qcheck.map3(
    gen.non_negative(),
    gen.non_negative(),
    gen.non_negative(),
    fn(read, unread, words) { wire.MemoryTotals(read, unread, words) },
  )
}

fn counter_memory() -> Generator(wire.CounterMemorySnapshot) {
  qcheck.map3(
    gen.non_negative(),
    gen.one_of(wire.ProbeRunning, [wire.ProbeFinished, wire.ProbeStopped]),
    qcheck.from_generators(qcheck.constant(wire.NoMemoryCounted), [
      qcheck.map2(
        gen.small_list(function_memory()),
        memory_totals(),
        fn(rows, totals) { wire.MemoryCounted(rows, totals) },
      ),
    ]),
    fn(id, state, memory) { wire.CounterMemorySnapshot(id, state, memory) },
  )
}

fn probe_state_text(state: wire.ProbeState) -> String {
  case state {
    wire.ProbeRunning -> "running"
    wire.ProbeFinished -> "finished"
    wire.ProbeStopped -> "stopped"
  }
}

fn encode_counter_memory(report: wire.CounterMemorySnapshot) -> Dynamic {
  tuple([
    text("counter_memory"),
    num(report.probe_id),
    text(probe_state_text(report.state)),
    case report.memory {
      wire.NoMemoryCounted -> tuple([text("none")])
      wire.MemoryCounted(rows, totals) ->
        tuple([
          text("words"),
          dynamic.list(
            list.map(rows, fn(row) {
              tuple([
                text(row.module),
                text(row.function),
                num(row.arity),
                num(row.words),
                num(row.calls),
                num(row.time_us),
              ])
            }),
          ),
          num(totals.read),
          num(totals.unread),
          num(totals.words),
        ])
    },
  ])
}

pub fn property_owners_round_trip_test() {
  use report <- gen.check(owners_snapshot())

  assert wire.decode_envelope(envelope(encode_owners(report)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.OwnersReport(report)))
}

// The allocation rows carry the calls and call time of the same read. A row
// that stops at the words is the shape an earlier agent sent, and a reply that
// leaves out the totals is refused: neither is read with the missing numbers
// made up.
pub fn a_counter_memory_reply_missing_a_field_is_refused_test() {
  let row = fn(fields) { tuple(fields) }
  let reply = fn(rows, totals) {
    tuple([
      text("counter_memory"),
      num(1),
      text("running"),
      tuple([text("words"), dynamic.list(rows), ..totals]),
    ])
  }
  let whole = row([text("m"), text("f"), num(1), num(5), num(2), num(9)])
  let short = row([text("m"), text("f"), num(1), num(5)])

  assert wire.decode_envelope(
      envelope(reply([whole], [num(1), num(0), num(5)])),
    )
    == Ok(wire.Envelope(
      dynamic.string("ref"),
      wire.CounterMemoryReport(wire.CounterMemorySnapshot(
        1,
        wire.ProbeRunning,
        wire.MemoryCounted(
          [wire.FunctionMemory("m", "f", 1, 5, 2, 9)],
          wire.MemoryTotals(read: 1, unread: 0, words: 5),
        ),
      )),
    ))
  assert result.is_error(
    wire.decode_envelope(envelope(reply([short], [num(1), num(0), num(5)]))),
  )
  assert result.is_error(wire.decode_envelope(envelope(reply([whole], []))))
}

pub fn property_counter_memory_round_trips_test() {
  use report <- gen.check(counter_memory())

  assert wire.decode_envelope(envelope(encode_counter_memory(report)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.CounterMemoryReport(report)))
}

// --------------------------------------------------------- process detail

fn process_detail() -> Generator(wire.ProcessDetail) {
  qcheck.map6(
    gen.ident(),
    qcheck.tuple4(
      gen.non_negative(),
      gen.non_negative(),
      gen.non_negative(),
      gen.non_negative(),
    ),
    qcheck.tuple6(
      gen.non_negative(),
      gen.non_negative(),
      gen.ident(),
      gen.text(),
      gen.text(),
      gen.text(),
    ),
    gen.tuple3(
      gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
      gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
      gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    ),
    qcheck.tuple4(
      gen.non_negative(),
      gen.non_negative(),
      gen.non_negative(),
      gen.text(),
    ),
    gen.tuple2(owner_reading(), gen.small_list(gen.ident())),
    fn(pid, sizes, activity, gc, relations, tail) {
      wire.ProcessDetail(
        pid_text: pid,
        sizes: wire.ProcessSizes(sizes.0, sizes.1, sizes.2, sizes.3),
        activity: wire.ProcessActivity(
          activity.0,
          activity.1,
          activity.2,
          activity.3,
          activity.4,
          activity.5,
        ),
        gc: wire.ProcessGc(
          gc.0.0,
          gc.0.1,
          gc.0.2,
          gc.1.0,
          gc.1.1,
          gc.1.2,
          gc.2.0,
          gc.2.1,
          gc.2.2,
        ),
        relations: wire.ProcessRelations(
          relations.0,
          relations.1,
          relations.2,
          relations.3,
        ),
        owner: tail.0,
        capabilities: tail.1,
      )
    },
  )
}

fn encode_detail(detail: wire.ProcessDetail) -> Dynamic {
  tuple([
    text("process_detail"),
    text(detail.pid_text),
    tuple([
      num(detail.sizes.memory_bytes),
      num(detail.sizes.total_heap_bytes),
      num(detail.sizes.heap_bytes),
      num(detail.sizes.stack_bytes),
    ]),
    tuple([
      num(detail.activity.queue_length),
      num(detail.activity.reductions),
      text(detail.activity.status),
      text(detail.activity.current_function),
      text(detail.activity.initial_call),
      text(detail.activity.registered_name),
    ]),
    tuple([
      num(detail.gc.minor_gcs),
      num(detail.gc.fullsweep_after),
      num(detail.gc.min_heap_bytes),
      num(detail.gc.max_heap_bytes),
      num(detail.gc.heap_block_bytes),
      num(detail.gc.old_heap_bytes),
      num(detail.gc.old_heap_block_bytes),
      num(detail.gc.mbuf_bytes),
      num(detail.gc.bin_vheap_bytes),
    ]),
    tuple([
      num(detail.relations.links),
      num(detail.relations.monitors),
      num(detail.relations.monitored_by),
      text(detail.relations.parent_pid_text),
    ]),
    encode_owner(detail.owner),
    dynamic.list(list.map(detail.capabilities, text)),
  ])
}

pub fn property_process_detail_round_trips_test() {
  use detail <- gen.check(process_detail())

  assert wire.decode_envelope(envelope(encode_detail(detail)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.ProcessDetailReport(detail)))
}

// ------------------------------------------------------------ supervision

fn spawn_edge() -> Generator(wire.SpawnEdge) {
  qcheck.map3(
    gen.tuple2(gen.ident(), gen.text()),
    gen.tuple2(gen.text(), gen.text()),
    owner_reading(),
    fn(a, b, owner) { wire.SpawnEdge(a.0, a.1, b.0, b.1, owner) },
  )
}

fn walk_stop() -> Generator(#(wire.WalkStop, String)) {
  gen.one_of(#(wire.SupervisionFinished, "finished"), [
    #(wire.SupervisionScanBudget, "scan_budget"),
    #(wire.SupervisionDeadline, "deadline"),
    #(wire.SupervisionEdgeBudget, "edge_budget"),
  ])
}

pub fn property_supervision_round_trips_test() {
  use #(counts, stop, edges) <- gen.check(gen.tuple3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    walk_stop(),
    gen.small_list(spawn_edge()),
  ))
  let snapshot =
    wire.SupervisionSnapshot(
      coverage: wire.SupervisionCoverage(
        scanned: counts.0,
        total: counts.1,
        stop: stop.0,
        elapsed_ms: counts.2,
      ),
      edges: edges,
    )
  let body =
    tuple([
      text("supervision"),
      tuple([num(counts.0), num(counts.1), text(stop.1), num(counts.2)]),
      dynamic.list(
        list.map(edges, fn(edge) {
          tuple([
            text(edge.child_pid_text),
            text(edge.parent_pid_text),
            text(edge.registered_name),
            text(edge.initial_call),
            encode_owner(edge.owner),
          ])
        }),
      ),
    ])

  assert wire.decode_envelope(envelope(body))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.SupervisionReport(snapshot)))
}

// ----------------------------------------------------------------- system

fn node_facts() -> Generator(wire.NodeFacts) {
  qcheck.map4(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.ident()),
    gen.tuple3(gen.ident(), gen.ident(), gen.ident()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(a, b, c, d) {
      wire.NodeFacts(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1, c.2, d.0, d.1, d.2)
    },
  )
}

fn carrier_row() -> Generator(wire.CarrierRow) {
  qcheck.map3(
    gen.tuple2(
      gen.ident(),
      gen.one_of(wire.InCarrierPool, [wire.NotInCarrierPool]),
    ),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.non_negative(),
    fn(a, b, unscanned) { wire.CarrierRow(a.0, a.1, b.0, b.1, b.2, unscanned) },
  )
}

fn carriers() -> Generator(wire.Carriers) {
  qcheck.from_generators(
    qcheck.map(gen.ident(), fn(reason) { wire.CarriersUnavailable(reason) }),
    [qcheck.map(gen.small_list(carrier_row()), wire.CarriersRead)],
  )
}

pub fn property_system_round_trips_test() {
  use #(facts, read) <- gen.check(gen.tuple2(node_facts(), carriers()))
  let body =
    tuple([
      text("system"),
      tuple([
        num(facts.uptime_ms),
        num(facts.creation),
        text(facts.emulator_flavor),
        text(facts.emulator_type),
        text(facts.erts_version),
        text(facts.otp_release),
        num(facts.schedulers),
        num(facts.schedulers_online),
        num(facts.dirty_cpu),
        num(facts.dirty_cpu_online),
        num(facts.dirty_io),
        num(facts.word_size),
      ]),
      case read {
        wire.CarriersUnavailable(reason) ->
          tuple([text("unavailable"), text(reason)])
        wire.CarriersRead(rows) ->
          tuple([
            text("carriers"),
            dynamic.list(
              list.map(rows, fn(row) {
                tuple([
                  text(row.allocator),
                  dynamic.bool(row.pool == wire.InCarrierPool),
                  num(row.carriers),
                  num(row.total_bytes),
                  num(row.used_bytes),
                  num(row.unscanned_bytes),
                ])
              }),
            ),
          ])
      },
    ])

  assert wire.decode_envelope(envelope(body))
    == Ok(wire.Envelope(
      dynamic.string("ref"),
      wire.SystemReport(wire.SystemSnapshot(facts, read)),
    ))
}

// ------------------------------------------------- collection and measure

fn heap_sizes() -> Generator(wire.HeapSizes) {
  qcheck.map3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(a, b, c) { wire.HeapSizes(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1, c.2) },
  )
}

fn heap_reading() -> Generator(wire.HeapReading) {
  qcheck.from_generators(qcheck.constant(wire.HeapGone), [
    qcheck.map(heap_sizes(), wire.HeapRead),
  ])
}

fn encode_heap(reading: wire.HeapReading) -> Dynamic {
  case reading {
    wire.HeapGone -> tuple([text("gone")])
    wire.HeapRead(sizes) ->
      tuple([
        text("heap"),
        num(sizes.memory_bytes),
        num(sizes.total_heap_bytes),
        num(sizes.heap_bytes),
        num(sizes.heap_block_bytes),
        num(sizes.old_heap_bytes),
        num(sizes.old_heap_block_bytes),
        num(sizes.mbuf_bytes),
        num(sizes.stack_bytes),
        num(sizes.bin_vheap_bytes),
      ])
  }
}

pub fn property_collection_round_trips_test() {
  use #(pid, outcome, elapsed, before, after) <- gen.check(qcheck.tuple5(
    gen.ident(),
    gen.one_of(#(wire.CollectionCompleted, "completed"), [
      #(wire.CollectionTargetGone, "target_gone"),
    ]),
    gen.non_negative(),
    heap_reading(),
    heap_reading(),
  ))
  let body =
    tuple([
      text("gc"),
      text("intrusive"),
      text(pid),
      text(outcome.1),
      num(elapsed),
      encode_heap(before),
      encode_heap(after),
    ])

  assert wire.decode_envelope(envelope(body))
    == Ok(wire.Envelope(
      dynamic.string("ref"),
      wire.CollectionReport(wire.CollectionSnapshot(
        pid,
        outcome.0,
        elapsed,
        before,
        after,
      )),
    ))
}

fn self_reading() -> Generator(#(wire.SelfReading, String)) {
  qcheck.map2(
    gen.tuple2(gen.ident(), gen.non_negative()),
    gen.one_of(#(wire.ReadingWords, "words"), [
      #(wire.ReadingBytes, "bytes"),
      #(wire.ReadingCount, "count"),
    ]),
    fn(a, unit) { #(wire.SelfReading(a.0, a.1, unit.0), unit.1) },
  )
}

pub fn property_measure_round_trips_test() {
  use #(pid, elapsed, readings) <- gen.check(gen.tuple3(
    gen.ident(),
    gen.non_negative(),
    gen.small_list(self_reading()),
  ))
  let body =
    tuple([
      text("measure"),
      text(pid),
      num(elapsed),
      dynamic.list(
        list.map(readings, fn(pair) {
          tuple([text({ pair.0 }.name), num({ pair.0 }.value), text(pair.1)])
        }),
      ),
    ])

  assert wire.decode_envelope(envelope(body))
    == Ok(wire.Envelope(
      dynamic.string("ref"),
      wire.MeasureReport(wire.MeasureSnapshot(
        pid,
        elapsed,
        list.map(readings, fn(pair) { pair.0 }),
      )),
    ))
}

// ----------------------------------------------------------------- stacks

fn frame_location() -> Generator(wire.FrameLocation) {
  qcheck.from_generators(qcheck.constant(wire.NoLocation), [
    qcheck.map(gen.ident(), wire.FileOnly),
    qcheck.map2(gen.ident(), gen.non_negative(), wire.AtLine),
  ])
}

fn stack_frame() -> Generator(wire.StackFrame) {
  qcheck.map3(
    gen.tuple2(gen.ident(), gen.ident()),
    gen.non_negative(),
    frame_location(),
    fn(names, arity, location) {
      wire.StackFrame(names.0, names.1, arity, location)
    },
  )
}

fn sampled_stack() -> Generator(wire.SampledStack) {
  qcheck.map3(
    gen.non_negative(),
    gen.ident(),
    gen.small_list(gen.non_negative()),
    fn(count, status, frames) { wire.SampledStack(count, status, frames) },
  )
}

fn sampler_meter() -> Generator(wire.SamplerMeter) {
  qcheck.map4(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(a, b, c, d) {
      wire.SamplerMeter(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1, c.2, d.0, d.1)
    },
  )
}

fn encode_frame(frame: wire.StackFrame) -> Dynamic {
  tuple([
    text(frame.module),
    text(frame.function),
    num(frame.arity),
    case frame.location {
      wire.NoLocation -> tuple([text("none")])
      wire.FileOnly(file) -> tuple([text("file"), text(file)])
      wire.AtLine(file, line) -> tuple([text("at"), text(file), num(line)])
    },
  ])
}

fn sampling_stop() -> Generator(#(wire.SamplingStop, String)) {
  gen.one_of(#(wire.SamplingRunning, "running"), [
    #(wire.SamplingDeadline, "deadline"),
    #(wire.SamplingBudget, "sample_budget"),
    #(wire.SamplingTargetsGone, "targets_gone"),
    #(wire.SamplingStopped, "stopped"),
  ])
}

fn encode_stacks(snapshot: wire.StacksSnapshot, stop_text: String) -> Dynamic {
  let meter = snapshot.meter

  tuple([
    text("stacks"),
    num(snapshot.probe_id),
    text(probe_state_text(snapshot.state)),
    text(stop_text),
    tuple([
      text("polled_current_stacktrace"),
      num(meter.requested_hz),
      num(meter.achieved_millihz),
      num(meter.rounds),
      num(meter.samples),
      num(meter.elapsed_ms),
      num(meter.depth_limit),
      num(meter.at_depth_limit),
      num(meter.targets_gone),
      num(meter.dropped_samples),
      num(meter.distinct_stacks),
      num(meter.truncated_samples),
    ]),
    dynamic.list(list.map(snapshot.frames, encode_frame)),
    dynamic.list(
      list.map(snapshot.stacks, fn(stack) {
        tuple([
          num(stack.count),
          text(stack.status),
          dynamic.list(list.map(stack.frames, num)),
        ])
      }),
    ),
  ])
}

pub fn property_stacks_round_trip_test() {
  use #(id, state, stop, meter, frames, stacks) <- gen.check(qcheck.tuple6(
    gen.non_negative(),
    gen.one_of(wire.ProbeRunning, [wire.ProbeFinished, wire.ProbeStopped]),
    sampling_stop(),
    sampler_meter(),
    gen.small_list(stack_frame()),
    gen.small_list(sampled_stack()),
  ))
  let snapshot = wire.StacksSnapshot(id, state, stop.0, meter, frames, stacks)

  assert wire.decode_envelope(envelope(encode_stacks(snapshot, stop.1)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.StacksReport(snapshot)))
}

pub fn stacks_started_decodes_test() {
  assert wire.decode_reply(
      tuple([
        text("stacks_started"),
        num(3),
        num(2),
        num(100),
        num(5000),
        num(900),
      ]),
    )
    == Ok(wire.StacksStarted(3, 2, 100, 5000, 900))
}

// ------------------------------------------- totality of the added replies

// A well-formed example of each added reply, so the corruption properties
// below can cut and break each one.
fn added_examples() -> List(Dynamic) {
  let heap = tuple([text("gone")])

  [
    encode_owners(wire.OwnersSnapshot(
      wire.CensusCoverage(1, 2, wire.WalkFinished, 3),
      [],
      [],
      wire.CensusTotals(1, 2, 3, 4, 5, 6, 7),
    )),
    encode_counter_memory(wire.CounterMemorySnapshot(
      1,
      wire.ProbeRunning,
      wire.NoMemoryCounted,
    )),
    tuple([
      text("supervision"),
      tuple([num(1), num(1), text("finished"), num(1)]),
      dynamic.list([]),
    ]),
    tuple([
      text("system"),
      tuple([
        num(1),
        num(2),
        text("jit"),
        text("opt"),
        text("17"),
        text("29"),
        num(8),
        num(8),
        num(8),
        num(8),
        num(10),
        num(8),
      ]),
      tuple([text("unavailable"), text("instrument_not_loaded")]),
    ]),
    tuple([
      text("gc"),
      text("intrusive"),
      text("<0.1.0>"),
      text("completed"),
      num(1),
      heap,
      heap,
    ]),
    tuple([text("measure"), text("<0.1.0>"), num(1), dynamic.list([])]),
    encode_ets_tables(wire.EtsSnapshot(
      wire.EtsCoverage(3, 2, 1, wire.EtsFinished, 4),
      [],
      wire.EtsTotals(2, 10, 800),
    )),
    tuple([
      text("binaries"),
      text("<0.1.0>"),
      num(1),
      num(2),
      num(3),
      dynamic.list([]),
    ]),
    encode_owners_detail(wire.OwnersDetailSnapshot(
      wire.CensusCoverage(1, 2, wire.WalkFinished, 3),
      [],
      [],
      wire.CensusTotals(1, 2, 3, 4, 5, 6, 7),
      wire.EtsPass(1, 2, 3, wire.EtsFinished),
    )),
  ]
}

// Dropping the last element of any added reply is an error, never a
// default-filled value.
pub fn truncated_added_replies_are_errors_test() {
  list.each(added_examples(), fn(example) {
    assert is_error(wire.decode_reply(truncated_tuple(example)))
  })
}

fn truncated_tuple(term: Dynamic) -> Dynamic {
  case decode.run(term, decode.list(decode.dynamic)) {
    Ok(items) -> tuple(list.take(items, list.length(items) - 1))
    Error(_) -> tuple([])
  }
}

// An enumeration outside its closed list is an error for every added reply
// that has one.
pub fn unknown_codes_in_added_replies_are_errors_test() {
  let heap = tuple([text("gone")])

  assert is_error(
    wire.decode_reply(
      tuple([
        text("supervision"),
        tuple([num(1), num(1), text("sideways"), num(1)]),
        dynamic.list([]),
      ]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([
        text("gc"),
        text("intrusive"),
        text("<0.1.0>"),
        text("exploded"),
        num(1),
        heap,
        heap,
      ]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([
        text("gc"),
        text("gentle"),
        text("<0.1.0>"),
        text("completed"),
        num(1),
        heap,
        heap,
      ]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([
        text("measure"),
        text("<0.1.0>"),
        num(1),
        dynamic.list([tuple([text("n"), num(1), text("furlongs")])]),
      ]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([
        text("counter_memory"),
        num(1),
        text("running"),
        tuple([text("zeros")]),
      ]),
    ),
  )
}

// A stacks reply that names a method other than polled `current_stacktrace`,
// an unknown stop reason or a frame location of an unknown kind is refused.
pub fn stacks_replies_are_checked_test() {
  let meter = fn(method: String) {
    tuple([
      text(method),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
      num(8),
      num(0),
      num(0),
      num(0),
      num(0),
      num(0),
    ])
  }
  let reply = fn(method: String, stop: String, location: Dynamic) {
    tuple([
      text("stacks"),
      num(1),
      text("running"),
      text(stop),
      meter(method),
      dynamic.list([
        tuple([text("m"), text("f"), num(1), location]),
      ]),
      dynamic.list([]),
    ])
  }

  assert wire.decode_reply(reply(
      "polled_current_stacktrace",
      "running",
      tuple([text("none")]),
    ))
    |> result_ok
  assert is_error(
    wire.decode_reply(reply("tracing", "running", tuple([text("none")]))),
  )
  assert is_error(
    wire.decode_reply(reply(
      "polled_current_stacktrace",
      "sideways",
      tuple([text("none")]),
    )),
  )
  assert is_error(
    wire.decode_reply(reply(
      "polled_current_stacktrace",
      "running",
      tuple([text("somewhere")]),
    )),
  )
}

fn result_ok(result: Result(a, b)) -> Bool {
  !is_error(result)
}

// Totality over arbitrary input is already covered by
// `property_junk_never_decodes_and_never_crashes_test`; this adds the
// property that junk placed inside each added tag still never raises.
pub fn property_junk_inside_added_tags_never_crashes_test() {
  use #(junk_a, junk_b) <- gen.check(gen.tuple2(junk(2), junk(2)))

  list.each(
    [
      "owners",
      "owners_detail",
      "ets_tables",
      "binaries",
      "counter_memory",
      "process_detail",
      "supervision",
      "system",
      "gc",
      "measure",
      "stacks_started",
      "stacks",
    ],
    fn(tag) {
      assert is_error(
        wire.decode_reply(tuple([text(tag), junk_a, junk_b, junk_a])),
      )
    },
  )
}

// ------------------------------------------------- the extended requests

pub fn extended_requests_encode_to_the_agent_shape_test() {
  let reply_to = text("pid")
  let reference = text("ref")
  let envelope = fn(body: Dynamic) {
    tuple([text("pg"), num(1), reply_to, reference, body])
  }
  let encode = fn(request) {
    wire.encode_extended_request(reply_to, reference, request)
  }
  let assert Ok(boot) = identity.boot_id("boot-1") as "valid boot id"
  let assert Ok(token) = identity.pin(boot, 4) as "valid serial"
  let token_term = tuple([text("boot-1"), num(4)])

  assert encode(wire.AskOwners(100, 10))
    == envelope(tuple([text("owners"), num(100), num(10)]))
  assert encode(wire.AskSystem) == envelope(tuple([text("system")]))
  assert encode(wire.AskSupervision(500, 20))
    == envelope(tuple([text("supervision"), num(500), num(20)]))
  assert encode(wire.AskProcessDetail(token))
    == envelope(tuple([text("process_detail"), token_term]))
  assert encode(wire.AskGc(token, 3000))
    == envelope(tuple([text("gc"), token_term, num(3000)]))
  assert encode(wire.AskMeasure(token, 500))
    == envelope(tuple([text("measure"), token_term, num(500)]))
  assert encode(wire.AskStartStacks([token], 100, 5000, 1000))
    == envelope(
      tuple([
        text("start_stacks"),
        dynamic.list([token_term]),
        num(100),
        num(5000),
        num(1000),
      ]),
    )
  assert encode(wire.AskReadStacks(3))
    == envelope(tuple([text("read_stacks"), num(3)]))
  assert encode(wire.AskStopStacks(3))
    == envelope(tuple([text("stop_stacks"), num(3)]))
  assert encode(wire.AskReadCounterMemory(2))
    == envelope(tuple([text("read_counter_memory"), num(2)]))
  assert encode(wire.AskStartCounterSet(
      [wire.CounterPattern("a", "run"), wire.CounterPattern("b", "_")],
      wire.PinnedProcesses([token]),
      5000,
      wire.CountTimeAndMemory,
    ))
    == envelope(
      tuple([
        text("start_counter_set"),
        dynamic.list([
          tuple([text("a"), text("run")]),
          tuple([text("b"), text("_")]),
        ]),
        tuple([text("pins"), dynamic.list([token_term])]),
        num(5000),
        text("time_and_memory"),
      ]),
    )
  assert encode(wire.AskStartCounterSet(
      [wire.CounterPattern("a", "run")],
      wire.AllProcesses,
      100,
      wire.CountTime,
    ))
    == envelope(
      tuple([
        text("start_counter_set"),
        dynamic.list([tuple([text("a"), text("run")])]),
        tuple([text("all")]),
        num(100),
        text("time"),
      ]),
    )
}

// ----------------------------------------------------------------- traces

fn trace_stop() -> Generator(#(wire.TraceStop, String)) {
  gen.one_of(#(wire.TraceRunning, "running"), [
    #(wire.TraceDeadline, "deadline"),
    #(wire.TraceBudget, "event_budget"),
    #(wire.TraceOverrun, "overrun"),
    #(wire.TraceTargetsGone, "targets_gone"),
    #(wire.TraceStopped, "stopped"),
  ])
}

fn probe_state() -> Generator(wire.ProbeState) {
  gen.one_of(wire.ProbeRunning, [wire.ProbeFinished, wire.ProbeStopped])
}

fn trace_meter() -> Generator(wire.TraceMeter) {
  qcheck.map3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(a, b, c) { wire.TraceMeter(a.0, a.1, a.2, b.0, b.1, b.2, c.0, c.1) },
  )
}

fn encode_trace_meter(method: String, meter: wire.TraceMeter) -> List(Dynamic) {
  [
    text(method),
    num(meter.elapsed_ms),
    num(meter.events),
    num(meter.max_events),
    num(meter.dropped_events),
    num(meter.in_flight_at_stop),
    num(meter.peak_queue),
    num(meter.queue_limit),
    num(meter.targets_gone),
  ]
}

fn calltrace_meter() -> Generator(wire.CalltraceMeter) {
  qcheck.map3(
    trace_meter(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(trace, a, b) { wire.CalltraceMeter(trace, a.0, a.1, a.2, b.0, b.1, b.2) },
  )
}

fn call_path() -> Generator(wire.CallPath) {
  qcheck.map3(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.small_list(gen.non_negative()),
    gen.non_negative(),
    fn(totals, frames, _) {
      wire.CallPath(totals.0, totals.1, totals.2, frames)
    },
  )
}

fn call_slice() -> Generator(wire.CallSlice) {
  qcheck.map2(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(a, b) { wire.CallSlice(a.0, a.1, a.2, b.0, b.1) },
  )
}

fn encode_calltrace(snapshot: wire.CalltraceSnapshot, stop: String) -> Dynamic {
  let meter = snapshot.meter

  tuple([
    text("calltrace"),
    num(snapshot.probe_id),
    text(probe_state_text(snapshot.state)),
    text(stop),
    tuple(
      list.append(encode_trace_meter("traced_call_return_to", meter.trace), [
        num(meter.forced_closes),
        num(meter.distinct_paths),
        num(meter.dropped_calls),
        num(meter.elided_calls),
        num(meter.strays),
        num(meter.depth_limit),
      ]),
    ),
    dynamic.list(list.map(snapshot.frames, encode_frame)),
    dynamic.list(
      list.map(snapshot.paths, fn(path) {
        tuple([
          num(path.calls),
          num(path.inclusive_ns),
          num(path.exclusive_ns),
          dynamic.list(list.map(path.frames, num)),
        ])
      }),
    ),
    tuple([
      dynamic.list(list.map(snapshot.processes, text)),
      dynamic.list(
        list.map(snapshot.slices, fn(slice) {
          tuple([
            num(slice.process),
            num(slice.frame),
            num(slice.start_ns),
            num(slice.duration_ns),
            num(slice.depth),
          ])
        }),
      ),
    ]),
  ])
}

// A call tree snapshot the agent could send decodes to exactly what was sent.
pub fn property_calltrace_round_trips_test() {
  use #(head, tail) <- gen.check(gen.tuple2(
    qcheck.tuple4(
      gen.non_negative(),
      probe_state(),
      trace_stop(),
      calltrace_meter(),
    ),
    qcheck.tuple4(
      gen.small_list(stack_frame()),
      gen.small_list(call_path()),
      gen.small_list(gen.ident()),
      gen.small_list(call_slice()),
    ),
  ))
  let #(id, state, stop, meter) = head
  let #(frames, paths, processes, slices) = tail
  let snapshot =
    wire.CalltraceSnapshot(
      id,
      state,
      stop.0,
      meter,
      frames,
      paths,
      processes,
      slices,
    )

  assert wire.decode_envelope(envelope(encode_calltrace(snapshot, stop.1)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.CalltraceReport(snapshot)))
}

fn traced_process() -> Generator(wire.TracedProcess) {
  qcheck.map2(
    gen.ident(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(pid, a) { wire.TracedProcess(pid, a.0, a.1, a.2, a.0, a.1) },
  )
}

fn activity_slice() -> Generator(#(wire.ActivitySlice, String)) {
  qcheck.map2(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.one_of(#(wire.RunSlice, "run"), [
      #(wire.MinorGcSlice, "gc_minor"),
      #(wire.MajorGcSlice, "gc_major"),
    ]),
    fn(a, kind) { #(wire.ActivitySlice(a.0, kind.0, a.1, a.2), kind.1) },
  )
}

fn long_event() -> Generator(wire.LongEvent) {
  qcheck.from_generators(
    qcheck.map2(
      gen.ident(),
      gen.tuple2(gen.non_negative(), gen.non_negative()),
      fn(pid, a) { wire.LongGc(pid, a.0, a.1) },
    ),
    [
      qcheck.map2(
        gen.ident(),
        gen.tuple2(gen.non_negative(), qcheck.string()),
        fn(pid, a) { wire.LongSchedule(pid, a.0, a.1) },
      ),
    ],
  )
}

fn events_meter() -> Generator(wire.EventsMeter) {
  qcheck.map3(
    trace_meter(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(trace, a, b) { wire.EventsMeter(trace, a.0, a.1, a.2, b.0, b.1, b.2) },
  )
}

fn encode_events(
  snapshot: wire.EventsSnapshot,
  stop: String,
  kinds: List(String),
) -> Dynamic {
  let meter = snapshot.meter

  tuple([
    text("events"),
    num(snapshot.probe_id),
    text(probe_state_text(snapshot.state)),
    text(stop),
    tuple(
      list.append(encode_trace_meter("traced_running_gc", meter.trace), [
        num(meter.unpaired_events),
        num(meter.dropped_slices),
        num(meter.long_events_seen),
        num(meter.strays),
        num(meter.long_gc_ms),
        num(meter.long_schedule_ms),
      ]),
    ),
    dynamic.list(
      list.map(snapshot.processes, fn(process) {
        tuple([
          text(process.pid_text),
          num(process.runs),
          num(process.run_ns),
          num(process.minor_gcs),
          num(process.major_gcs),
          num(process.gc_ns),
        ])
      }),
    ),
    dynamic.list(
      list.map(list.zip(snapshot.slices, kinds), fn(pair) {
        tuple([
          num({ pair.0 }.process),
          text(pair.1),
          num({ pair.0 }.start_ns),
          num({ pair.0 }.duration_ns),
        ])
      }),
    ),
    dynamic.list(
      list.map(snapshot.long, fn(event) {
        case event {
          wire.LongGc(pid, ms, words) ->
            tuple([text("long_gc"), text(pid), num(ms), num(words)])
          wire.LongSchedule(pid, ms, function) ->
            tuple([text("long_schedule"), text(pid), num(ms), text(function)])
        }
      }),
    ),
  ])
}

// An events snapshot the agent could send decodes to exactly what was sent,
// including both kinds of threshold event.
pub fn property_events_round_trips_test() {
  use #(head, tail) <- gen.check(gen.tuple2(
    qcheck.tuple4(
      gen.non_negative(),
      probe_state(),
      trace_stop(),
      events_meter(),
    ),
    qcheck.tuple3(
      gen.small_list(traced_process()),
      gen.small_list(activity_slice()),
      gen.small_list(long_event()),
    ),
  ))
  let #(id, state, stop, meter) = head
  let #(processes, slices, long) = tail
  let snapshot =
    wire.EventsSnapshot(
      id,
      state,
      stop.0,
      meter,
      processes,
      list.map(slices, fn(pair) { pair.0 }),
      long,
    )

  assert wire.decode_envelope(
      envelope(encode_events(
        snapshot,
        stop.1,
        list.map(slices, fn(pair) { pair.1 }),
      )),
    )
    == Ok(wire.Envelope(dynamic.string("ref"), wire.EventsReport(snapshot)))
}

pub fn trace_started_replies_decode_test() {
  assert wire.decode_reply(
      tuple([
        text("calltrace_started"),
        num(3),
        num(2),
        num(11),
        num(500),
        num(1000),
        num(100),
      ]),
    )
    == Ok(wire.CalltraceStarted(3, 2, 11, 500, 1000, 100))
  assert wire.decode_reply(
      tuple([
        text("events_started"),
        num(3),
        num(2),
        num(500),
        num(1000),
        num(100),
        num(5),
        num(0),
      ]),
    )
    == Ok(wire.EventsStarted(3, 2, 500, 1000, 100, 5, 0))
}

// A well-formed example of each trace reply, to be cut and broken below.
fn trace_examples() -> List(Dynamic) {
  let meter = wire.TraceMeter(1, 2, 3, 4, 5, 6, 7, 8)
  let calltrace =
    wire.CalltraceSnapshot(
      1,
      wire.ProbeRunning,
      wire.TraceRunning,
      wire.CalltraceMeter(meter, 1, 2, 3, 4, 5, 6),
      [],
      [],
      [],
      [],
    )
  let events =
    wire.EventsSnapshot(
      1,
      wire.ProbeRunning,
      wire.TraceRunning,
      wire.EventsMeter(meter, 1, 2, 3, 4, 5, 6),
      [],
      [],
      [],
    )

  [
    encode_calltrace(calltrace, "running"),
    encode_events(events, "running", []),
    tuple([
      text("calltrace_started"),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
    ]),
    tuple([
      text("events_started"),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
      num(1),
    ]),
  ]
}

pub fn truncated_trace_replies_are_errors_test() {
  list.each(trace_examples(), fn(example) {
    assert is_error(wire.decode_reply(truncated_tuple(example)))
  })
}

// A trace reply that names another method, an unknown stop reason, an
// unknown slice kind or an unknown threshold event is refused.
pub fn trace_replies_are_checked_test() {
  let meter = wire.TraceMeter(1, 2, 3, 4, 5, 6, 7, 8)
  let calltrace = fn(method: String, stop: String) {
    encode_calltrace(
      wire.CalltraceSnapshot(
        1,
        wire.ProbeRunning,
        wire.TraceRunning,
        wire.CalltraceMeter(meter, 1, 2, 3, 4, 5, 6),
        [],
        [],
        [],
        [],
      ),
      stop,
    )
    |> replace_method(method)
  }
  let events = fn(method: String, kind: String, long: Dynamic) {
    tuple([
      text("events"),
      num(1),
      text("running"),
      text("running"),
      tuple(
        list.append(encode_trace_meter(method, meter), [
          num(0),
          num(0),
          num(0),
          num(0),
          num(0),
          num(0),
        ]),
      ),
      dynamic.list([]),
      dynamic.list([tuple([num(0), text(kind), num(1), num(1)])]),
      dynamic.list([long]),
    ])
  }
  let good_long = tuple([text("long_gc"), text("<0.1.0>"), num(5), num(6)])

  assert wire.decode_reply(calltrace("traced_call_return_to", "running"))
    |> result_ok
  assert is_error(wire.decode_reply(calltrace("sampled", "running")))
  assert is_error(
    wire.decode_reply(calltrace("traced_call_return_to", "sideways")),
  )
  assert wire.decode_reply(events("traced_running_gc", "run", good_long))
    |> result_ok
  assert is_error(wire.decode_reply(events("sampled", "run", good_long)))
  assert is_error(
    wire.decode_reply(events("traced_running_gc", "sleep", good_long)),
  )
  assert is_error(
    wire.decode_reply(events(
      "traced_running_gc",
      "run",
      tuple([text("long_port"), text("<0.1.0>"), num(5), num(6)]),
    )),
  )
  assert is_error(
    wire.decode_reply(events(
      "traced_running_gc",
      "run",
      tuple([text("long_schedule"), text("<0.1.0>"), num(5), num(6)]),
    )),
  )
}

// The method is the first element of the meter, which is the fifth element
// of the reply.
fn replace_method(reply: Dynamic, method: String) -> Dynamic {
  case decode.run(reply, decode.list(decode.dynamic)) {
    Ok([tag, id, phase, stop, meter, ..rest]) ->
      case decode.run(meter, decode.list(decode.dynamic)) {
        Ok([_, ..fields]) ->
          tuple([tag, id, phase, stop, tuple([text(method), ..fields]), ..rest])
        _ -> reply
      }
    _ -> reply
  }
}

pub fn property_junk_inside_trace_tags_never_crashes_test() {
  use #(junk_a, junk_b) <- gen.check(gen.tuple2(junk(2), junk(2)))

  list.each(
    ["calltrace_started", "calltrace", "events_started", "events"],
    fn(tag) {
      assert is_error(
        wire.decode_reply(tuple([text(tag), junk_a, junk_b, junk_a])),
      )
    },
  )
}

pub fn trace_requests_encode_to_the_agent_shape_test() {
  let reply_to = text("pid")
  let reference = text("ref")
  let envelope = fn(body: Dynamic) {
    tuple([text("pg"), num(1), reply_to, reference, body])
  }
  let encode = fn(request) {
    wire.encode_extended_request(reply_to, reference, request)
  }
  let assert Ok(boot) = identity.boot_id("boot-1") as "valid boot id"
  let assert Ok(token) = identity.pin(boot, 4) as "valid serial"
  let token_term = tuple([text("boot-1"), num(4)])

  assert encode(wire.AskStartCalltrace(
      [token],
      [wire.CounterPattern("a", "run"), wire.CounterPattern("b", "_")],
      2000,
      100_000,
      500,
    ))
    == envelope(
      tuple([
        text("start_calltrace"),
        dynamic.list([token_term]),
        dynamic.list([
          tuple([text("a"), text("run")]),
          tuple([text("b"), text("_")]),
        ]),
        num(2000),
        num(100_000),
        num(500),
      ]),
    )
  assert encode(wire.AskReadCalltrace(3))
    == envelope(tuple([text("read_calltrace"), num(3)]))
  assert encode(wire.AskStopCalltrace(3))
    == envelope(tuple([text("stop_calltrace"), num(3)]))
  assert encode(wire.AskStartEvents([token, token], 5000, 200_000, 1000, 5, 0))
    == envelope(
      tuple([
        text("start_events"),
        dynamic.list([token_term, token_term]),
        num(5000),
        num(200_000),
        num(1000),
        num(5),
        num(0),
      ]),
    )
  assert encode(wire.AskReadEvents(3))
    == envelope(tuple([text("read_events"), num(3)]))
  assert encode(wire.AskStopEvents(3))
    == envelope(tuple([text("stop_events"), num(3)]))
}

// ------------------------------------------------- ets, binaries, detail

fn ets_stop() -> Generator(#(wire.EtsStop, String)) {
  gen.one_of(#(wire.EtsFinished, "finished"), [#(wire.EtsDeadline, "deadline")])
}

fn ets_table() -> Generator(wire.EtsTable) {
  qcheck.map4(
    gen.tuple3(gen.ident(), gen.text(), gen.ident()),
    owner_reading(),
    gen.tuple3(gen.ident(), gen.non_negative(), gen.non_negative()),
    gen.tuple2(gen.ident(), gen.text()),
    fn(names, owner, sizes, more) {
      wire.EtsTable(
        id_text: names.0,
        name: names.1,
        owner_pid_text: names.2,
        owner: owner,
        owner_name: more.1,
        kind: sizes.0,
        objects: sizes.1,
        memory_bytes: sizes.2,
        protection: more.0,
        heir_pid_text: more.1,
      )
    },
  )
}

fn ets_snapshot() -> Generator(#(wire.EtsSnapshot, String)) {
  qcheck.map4(
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    ets_stop(),
    gen.small_list(ets_table()),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    fn(counts, stop, tables, totals) {
      #(
        wire.EtsSnapshot(
          coverage: wire.EtsCoverage(
            total: counts.0,
            counted: counts.1,
            skipped: counts.2,
            stop: stop.0,
            elapsed_ms: counts.0,
          ),
          tables: tables,
          totals: wire.EtsTotals(totals.0, totals.1, totals.2),
        ),
        stop.1,
      )
    },
  )
}

fn ets_stop_text(stop: wire.EtsStop) -> String {
  case stop {
    wire.EtsFinished -> "finished"
    wire.EtsDeadline -> "deadline"
  }
}

fn encode_ets_tables(snapshot: wire.EtsSnapshot) -> Dynamic {
  let coverage = snapshot.coverage
  let totals = snapshot.totals

  tuple([
    text("ets_tables"),
    tuple([
      num(coverage.total),
      num(coverage.counted),
      num(coverage.skipped),
      text(ets_stop_text(coverage.stop)),
      num(coverage.elapsed_ms),
    ]),
    dynamic.list(
      list.map(snapshot.tables, fn(table) {
        tuple([
          text(table.id_text),
          text(table.name),
          text(table.owner_pid_text),
          encode_owner(table.owner),
          text(table.kind),
          num(table.objects),
          num(table.memory_bytes),
          text(table.protection),
          text(table.heir_pid_text),
          text(table.owner_name),
        ])
      }),
    ),
    tuple([num(totals.tables), num(totals.objects), num(totals.memory_bytes)]),
  ])
}

pub fn property_ets_tables_round_trip_test() {
  use #(snapshot, _) <- gen.check(ets_snapshot())

  assert wire.decode_envelope(envelope(encode_ets_tables(snapshot)))
    == Ok(wire.Envelope(dynamic.string("ref"), wire.EtsTablesReport(snapshot)))
}

fn binary_ref() -> Generator(wire.BinaryRef) {
  qcheck.map2(
    gen.ident(),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(address, sizes) { wire.BinaryRef(address, sizes.0, sizes.1) },
  )
}

fn binaries_snapshot() -> Generator(wire.BinariesSnapshot) {
  qcheck.map3(
    gen.ident(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    gen.small_list(binary_ref()),
    fn(pid, totals, binaries) {
      wire.BinariesSnapshot(pid, totals.0, totals.1, totals.2, binaries)
    },
  )
}

pub fn property_binaries_round_trip_test() {
  use snapshot <- gen.check(binaries_snapshot())

  assert wire.decode_envelope(
      envelope(
        tuple([
          text("binaries"),
          text(snapshot.pid_text),
          num(snapshot.distinct),
          num(snapshot.bytes),
          num(snapshot.references),
          dynamic.list(
            list.map(snapshot.binaries, fn(ref) {
              tuple([text(ref.address_text), num(ref.bytes), num(ref.refc)])
            }),
          ),
        ]),
      ),
    )
    == Ok(wire.Envelope(dynamic.string("ref"), wire.BinariesReport(snapshot)))
}

fn owner_detail() -> Generator(wire.OwnerDetail) {
  qcheck.map2(
    owner_heap_total(),
    gen.tuple2(gen.non_negative(), gen.non_negative()),
    fn(owner, ets) { wire.OwnerDetail(owner, ets.0, ets.1) },
  )
}

fn owners_detail_snapshot() -> Generator(#(wire.OwnersDetailSnapshot, String)) {
  qcheck.map6(
    census_coverage(),
    gen.small_list(qcheck.map2(process_row(), gen.text(), wire.DetailedRow)),
    gen.small_list(owner_detail()),
    census_totals(),
    gen.tuple3(gen.non_negative(), gen.non_negative(), gen.non_negative()),
    ets_stop(),
    fn(coverage, rows, owners, totals, ets, stop) {
      #(
        wire.OwnersDetailSnapshot(
          coverage:,
          rows:,
          owners:,
          totals:,
          ets: wire.EtsPass(ets.0, ets.1, ets.2, stop.0),
        ),
        stop.1,
      )
    },
  )
}

fn encode_owners_detail(snapshot: wire.OwnersDetailSnapshot) -> Dynamic {
  let totals = snapshot.totals
  let ets = snapshot.ets

  tuple([
    text("owners_detail"),
    coverage_term(snapshot.coverage),
    dynamic.list(
      list.map(snapshot.rows, fn(detailed) {
        let assert Ok(fields) =
          decode.run(encode_row(detailed.row), decode.list(decode.dynamic))
          as "a row encodes to a tuple"

        tuple(list.append(fields, [text(detailed.initial_call)]))
      }),
    ),
    dynamic.list(
      list.map(snapshot.owners, fn(entry) {
        tuple([
          encode_owner(entry.owner.total.owner),
          num(entry.owner.total.processes),
          num(entry.owner.total.memory),
          num(entry.owner.total.queue_length),
          num(entry.owner.total.reductions),
          num(entry.owner.total_heap_words),
          num(entry.ets_tables),
          num(entry.ets_bytes),
        ])
      }),
    ),
    tuple([
      num(totals.processes),
      num(totals.memory),
      num(totals.queue_length),
      num(totals.reductions),
      num(totals.total_heap_words),
      num(totals.owners_tracked),
      num(totals.owners_listed),
    ]),
    tuple([
      num(ets.tables),
      num(ets.memory_bytes),
      num(ets.skipped),
      text(ets_stop_text(ets.stop)),
    ]),
  ])
}

pub fn property_owners_detail_round_trips_test() {
  use #(snapshot, _) <- gen.check(owners_detail_snapshot())

  assert wire.decode_envelope(envelope(encode_owners_detail(snapshot)))
    == Ok(wire.Envelope(
      dynamic.string("ref"),
      wire.OwnersDetailReport(snapshot),
    ))
}

// The detail reply is the `owners` reply with fields appended, so the older
// decoder, which reads by position, still reads the prefix it knows.
pub fn owners_detail_prefix_is_an_owners_reply_test() {
  let snapshot =
    wire.OwnersDetailSnapshot(
      wire.CensusCoverage(1, 2, wire.ScanBudgetReached, 3),
      [],
      [],
      wire.CensusTotals(1, 2, 3, 4, 5, 6, 7),
      wire.EtsPass(1, 2, 3, wire.EtsDeadline),
    )
  let assert Ok(items) =
    decode.run(encode_owners_detail(snapshot), decode.list(decode.dynamic))
    as "a tuple"
  let relabelled = tuple([text("owners"), ..list.drop(items, 1)])

  assert wire.decode_reply(relabelled)
    == Ok(
      wire.OwnersReport(wire.OwnersSnapshot(
        snapshot.coverage,
        [],
        [],
        snapshot.totals,
      )),
    )
}

// A stop reason outside the closed list is an error, in the listing and in the
// owners detail's ETS pass.
pub fn unknown_ets_stop_reasons_are_errors_test() {
  assert is_error(
    wire.decode_reply(
      tuple([
        text("ets_tables"),
        tuple([num(1), num(1), num(0), text("early"), num(1)]),
        dynamic.list([]),
        tuple([num(1), num(1), num(1)]),
      ]),
    ),
  )
  assert is_error(
    wire.decode_reply(
      tuple([
        text("owners_detail"),
        tuple([num(1), num(1), text("finished"), num(1)]),
        dynamic.list([]),
        dynamic.list([]),
        tuple([num(0), num(0), num(0), num(0), num(0), num(0), num(0)]),
        tuple([num(0), num(0), num(0), text("never")]),
      ]),
    ),
  )
}

// A row of the detail reply without its initial call is an error, not a row
// with an empty call.
pub fn detail_rows_need_their_initial_call_test() {
  let assert Ok(fields) =
    decode.run(
      encode_row(ProcessRow(
        "<0.1.0>",
        1,
        2,
        3,
        4,
        5,
        6,
        "waiting",
        "",
        "",
        Unlabelled,
      )),
      decode.list(decode.dynamic),
    )
    as "a tuple"

  assert is_error(
    wire.decode_reply(
      tuple([
        text("owners_detail"),
        tuple([num(1), num(1), text("finished"), num(1)]),
        dynamic.list([tuple(fields)]),
        dynamic.list([]),
        tuple([num(0), num(0), num(0), num(0), num(0), num(0), num(0)]),
        tuple([num(0), num(0), num(0), text("finished")]),
      ]),
    ),
  )
}

pub fn ets_and_binaries_requests_encode_to_the_agent_shape_test() {
  let reply_to = text("pid")
  let reference = text("ref")
  let envelope = fn(body: Dynamic) {
    tuple([text("pg"), num(1), reply_to, reference, body])
  }
  let encode = fn(request) {
    wire.encode_extended_request(reply_to, reference, request)
  }
  let assert Ok(boot) = identity.boot_id("boot-1") as "valid boot id"
  let assert Ok(token) = identity.pin(boot, 4) as "valid serial"

  assert encode(wire.AskOwnersDetail(100, 10))
    == envelope(tuple([text("owners_detail"), num(100), num(10)]))
  assert encode(wire.AskEtsTables(wire.default_ets_top_k))
    == envelope(tuple([text("ets_tables"), num(100)]))
  assert encode(wire.AskBinaries(token, 20))
    == envelope(
      tuple([text("binaries"), tuple([text("boot-1"), num(4)]), num(20)]),
    )
}
