//// Tests for the agent's ETS, binaries and initial-call readings in the
//// viewer: how a pass collects them, how a capture keeps them, and how the
//// owners, memory, process and supervision pages use them.

import fixture
import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/capture_build
import pickglass/capture_file
import pickglass/feeds
import pickglass/hub
import pickglass/observation.{type Observation, Observation}
import pickglass/observation_codec
import pickglass/remote
import pickglass/seam
import pickglass/service
import pickglass/supervision_build
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{Known, Missing}
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile/activity
import pickglass_core/readings
import pickglass_core/wire
import pickglass_web/memory_model
import pickglass_web/model
import pickglass_web/msg
import simplifile

// ---------------------------------------------------------------- scripts

fn segment(kind: String, id: String) -> owner.Segment {
  let assert Ok(found) = owner.segment(kind, id) as "a valid segment"

  found
}

fn session_owner() -> wire.OwnerReading {
  wire.Labelled([segment("session", "s1")], "worker")
}

fn ets_pass() -> wire.EtsPass {
  wire.EtsPass(
    tables: 9,
    memory_bytes: 20_000,
    skipped: 1,
    stop: wire.EtsFinished,
  )
}

fn detailed_reply() -> wire.Reply {
  let rows = [
    fixture.row("<0.10.0>", 5000, session_owner()),
    fixture.row("<0.11.0>", 4000, wire.Unlabelled),
  ]
  let census = fixture.census(rows)

  wire.OwnersDetailReport(wire.OwnersDetailSnapshot(
    coverage: census.coverage,
    rows: [
      wire.DetailedRow(
        row: fixture.row("<0.10.0>", 5000, session_owner()),
        initial_call: "supervisor:my_sup/1",
      ),
      wire.DetailedRow(
        row: fixture.row("<0.11.0>", 4000, wire.Unlabelled),
        initial_call: "",
      ),
    ],
    owners: [
      wire.OwnerDetail(
        owner: wire.OwnerHeapTotal(
          total: wire.OwnerTotal(session_owner(), 1, 5000, 0, 0),
          total_heap_words: 100,
        ),
        ets_tables: 2,
        ets_bytes: 8000,
      ),
      wire.OwnerDetail(
        owner: wire.OwnerHeapTotal(
          total: wire.OwnerTotal(wire.Unlabelled, 1, 4000, 0, 0),
          total_heap_words: 50,
        ),
        ets_tables: 6,
        ets_bytes: 11_000,
      ),
    ],
    totals: wire.CensusTotals(2, 9000, 0, 0, 150, 2, 2),
    ets: ets_pass(),
  ))
}

fn ets_listing() -> wire.EtsSnapshot {
  wire.EtsSnapshot(
    coverage: wire.EtsCoverage(
      total: 9,
      counted: 8,
      skipped: 1,
      stop: wire.EtsFinished,
      elapsed_ms: 2,
    ),
    tables: [
      wire.EtsTable(
        id_text: "#Ref<0.1.2.3>",
        name: "registry",
        owner_pid_text: "<0.10.0>",
        owner: session_owner(),
        kind: "set",
        objects: 40,
        memory_bytes: 9000,
        protection: "protected",
        heir_pid_text: "",
      ),
    ],
    totals: wire.EtsTotals(tables: 8, objects: 90, memory_bytes: 19_000),
  )
}

fn binaries() -> wire.BinariesSnapshot {
  wire.BinariesSnapshot(
    pid_text: "<0.5.0>",
    distinct: 3,
    bytes: 121_000,
    references: 100,
    binaries: [
      wire.BinaryRef(address_text: "7f00aa", bytes: 120_000, refc: 3),
      wire.BinaryRef(address_text: "7f00bb", bytes: 1000, refc: 1),
    ],
  )
}

fn script(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskOwnersDetail(..)) -> Ok(detailed_reply())
    wire.Extended(wire.AskEtsTables(_)) ->
      Ok(wire.EtsTablesReport(ets_listing()))
    wire.Extended(wire.AskBinaries(..)) -> Ok(wire.BinariesReport(binaries()))
    other -> fixture.healthy(other)
  }
}

fn refusing(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskBinaries(..)) ->
      Error(remote.Refusal(
        "too_many_binaries",
        "the process holds more binary references than one read may list",
      ))
    other -> script(other)
  }
}

fn pinned(page: seam.Page) -> String {
  let assert seam.PinIssued(token, _) = page.submit(seam.PinProcess("<0.5.0>"))

  token
}

// -------------------------------------------------------------- collection

fn collect(seq: Int) -> Observation {
  let seen = process.new_subject()

  observation.collect(
    fixture.fake_remote(seen, script),
    observation.Budget(100, 10),
    seq,
    observation.ReadOnly,
    fn() { 1000 + seq },
    fn() { Error("no OS reader in this test") },
  )
}

// The owners_detail reply is the pass's census, and what the census cannot
// hold is kept beside it: initial calls, per-owner ETS and the pass's totals.
pub fn a_pass_reads_the_owners_detail_in_place_of_the_owners_test() {
  let pass = collect(1)
  let assert Ok(census) = pass.census
  let assert Ok(detail) = pass.detail

  assert list.length(census.rows) == 2
  assert pass.totals == Ok(wire.CensusTotals(2, 9000, 0, 0, 150, 2, 2))
  assert detail.initial_calls == [#("<0.10.0>", "supervisor:my_sup/1")]
  assert detail.ets == ets_pass()
  assert list.map(detail.owners, fn(entry) { #(entry.tables, entry.bytes) })
    == [#(2, 8000), #(6, 11_000)]
}

// The table listing walks every table, so it is read on the first pass and
// every few passes after, and the others say they did not.
pub fn the_table_listing_is_read_every_few_passes_test() {
  let first = collect(0)
  let between = collect(1)
  let again = collect(observation.ets_every)

  let assert Ok(listing) = first.ets

  assert listing.snapshot == ets_listing()
  assert listing.at_ms == first.at_ms
  assert between.ets == Error(observation.ets_skipped)
  assert result_is_ok(again.ets)
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// A refused owners request is the same reason in every reading it feeds, and
// the table listing's own refusal is its own.
pub fn a_refused_owners_detail_fails_every_reading_it_feeds_test() {
  let seen = process.new_subject()
  let pass =
    observation.collect(
      fixture.fake_remote(seen, fn(request) {
        case request {
          wire.Extended(wire.AskOwnersDetail(..)) ->
            Error(remote.Refusal("busy", "four workers are already running"))
          other -> script(other)
        }
      }),
      observation.Budget(100, 10),
      0,
      observation.ReadOnly,
      fn() { 1000 },
      fn() { Error("no OS reader in this test") },
    )

  let assert Error(census_reason) = pass.census
  let assert Error(detail_reason) = pass.detail
  let assert Error(totals_reason) = pass.totals

  assert census_reason == detail_reason
  assert census_reason == totals_reason
  assert string.contains(census_reason, "busy")
}

// --------------------------------------------------------------- captures

fn facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 4242,
    boot: fixture.boot(),
    role: "loomd",
    workload: "idle",
    top_k: 200,
    deadline_ms: 15_000,
    os_start: identity.UnreadableStart,
    clock: None,
  )
}

fn parsed(
  observations: List(Observation),
  reads: List(readings.BinariesReading),
) -> capture_file.Loaded {
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(),
      "cap-readings",
      observations,
      measure.EveryMs(2000),
      [],
      [],
      [],
      reads,
    )
  let assert Ok(text) = capture_file.render(header, records)
  let assert Ok(loaded) = capture_file.parse(text)

  assert loaded.digest == capture_file.DigestVerified
  assert loaded.capture.status == measure.Complete

  loaded
}

fn replayed(loaded: capture_file.Loaded) -> List(Observation) {
  let assert Ok(back) =
    observation_codec.of_records(
      loaded.capture.records,
      capture_build.runtime_of(loaded.capture.header),
    )

  back
}

// What a pass read beyond the census is written as records and read back as
// the same readings, so a replay draws the owners page's ETS column and the
// memory page's tables as the live viewer did.
pub fn the_detail_and_the_listing_survive_a_capture_test() {
  let passes = [collect(0), collect(1)]
  let back = replayed(parsed(passes, []))

  assert list.map(back, fn(pass) { pass.detail })
    == list.map(passes, fn(pass) { pass.detail })
  assert list.map(back, fn(pass) { pass.ets |> result_is_ok }) == [True, False]

  let assert [first, ..] = back
  let assert Ok(listing) = first.ets

  assert listing.snapshot == ets_listing()
}

// A capture written before the readings existed has none of these records and
// reads back with the reason, not with invented zeros.
pub fn a_capture_without_the_readings_reads_back_with_a_reason_test() {
  let old = [fixture.observation(0, 1000), fixture.observation(1, 3000)]
  let loaded = parsed(old, [])
  let kinds = list.map(loaded.capture.records, capture.kind_of)

  assert !list.contains(kinds, "owners_detail")
  assert !list.contains(kinds, "ets_tables")

  let back = replayed(loaded)

  assert list.map(back, fn(pass) { pass.detail })
    == [
      Error(observation.detail_not_recorded),
      Error(observation.detail_not_recorded),
    ]
  assert list.map(back, fn(pass) { pass.ets })
    == [
      Error(observation.ets_not_recorded),
      Error(observation.ets_not_recorded),
    ]
}

pub fn a_binaries_reading_is_a_record_of_its_own_test() {
  let loaded =
    parsed([collect(0)], [
      readings.BinariesReading(at_ms: 5000, snapshot: binaries()),
    ])
  let kinds = list.map(loaded.capture.records, capture.kind_of)

  assert list.contains(kinds, "binaries")
  assert list.contains(
    loaded.capture.records,
    capture.BinariesRecord(readings.BinariesReading(
      at_ms: 5000,
      snapshot: binaries(),
    )),
  )
}

// ------------------------------------------------------------------ feeds

fn inputs(observations: List(Observation)) -> feeds.Inputs {
  feeds.Inputs(
    page: harness.page(harness.live(script, None), "alice", harness.all),
    observations:,
    pins: [],
    plans: [],
    marks: [],
    baseline: None,
    probes: [],
    samples: activity.OnSchedulerOnly,
    chain: [],
    exports: [],
    comparison: feeds.no_comparison,
    now_ms: 10_000,
    subject: None,
    detail: None,
    results: [],
    supervision: None,
    entries: [],
    notes: [],
    refusal: None,
    refused_starts: [],
    lost: None,
    cadence_ms: 2000,
    sort: model.ByMemory,
    offset: 0,
  )
}

fn owners_page(observations: List(Observation)) -> model.OwnersModel {
  let assert Ok(page) =
    list.find_map(feeds.feeds_for(feeds.Owners, inputs(observations)), fn(feed) {
      case feed {
        msg.FedOwners(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  page
}

fn memory_page(observations: List(Observation)) -> model.MemoryModel {
  let assert Ok(page) =
    list.find_map(feeds.feeds_for(feeds.Memory, inputs(observations)), fn(feed) {
      case feed {
        msg.FedMemory(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  page
}

pub fn the_owners_page_has_an_ets_column_for_every_row_test() {
  // Fifty processes on the node in all, so most are outside the listed rows.
  let pass = collect(0)
  let page =
    owners_page([
      Observation(
        ..pass,
        totals: Ok(wire.CensusTotals(50, 9000, 0, 0, 150, 2, 2)),
      ),
    ])

  // The session's two tables and 8,000 bytes, on the owner and its role.
  let assert [group, role] = page.rows

  assert group.ets_bytes == Known(8000)
  assert group.ets_tables == Known(2)
  assert role.ets_bytes == Known(8000)

  // Tables of a process with no label are under unknown, as the agent says.
  assert page.unknown.ets_bytes == Known(11_000)
  assert page.unknown.ets_tables == Known(6)

  // 20,000 bytes on the node less the 19,000 the listed owners hold.
  let assert model.Remainder(ets_bytes: remainder, ..) = page.remainder

  assert remainder == Known(1000)

  assert page.ets
    == memory_model.EtsPassRead(
      tables: 9,
      bytes: 20_000,
      skipped: 1,
      reach: memory_model.EveryTable,
      owners: 2,
      tracked: 2,
    )
}

// A pass that did not read the detail says so in the column and the note;
// no row reads as zero.
pub fn an_owners_page_without_the_detail_says_so_test() {
  let page = owners_page([fixture.observation(1, 3000)])

  assert page.ets == memory_model.EtsNotRead(observation.detail_not_recorded)
  assert page.unknown.ets_bytes == Missing(measure.NotCollected)
  assert list.all(page.rows, fn(row) {
    row.ets_bytes == Missing(measure.NotCollected)
  })
}

// An owner the agent did not list an aggregate for is not an owner with no
// tables: the cell says the list was cut.
pub fn an_owner_without_an_aggregate_is_not_a_zero_when_the_list_was_cut_test() {
  let pass = collect(0)
  let cut =
    Observation(
      ..pass,
      totals: Ok(wire.CensusTotals(2, 9000, 0, 0, 150, 5, 2)),
      detail: Ok(readings.OwnersDetail(
        at_ms: 1000,
        initial_calls: [],
        owners: [],
        ets: ets_pass(),
      )),
    )
  let page = owners_page([cut])

  assert page.unknown.ets_bytes == Missing(measure.BudgetExhausted)
}

pub fn an_ets_pass_that_stopped_early_marks_empty_rows_as_unread_test() {
  let pass = collect(0)
  let early =
    Observation(
      ..pass,
      detail: Ok(readings.OwnersDetail(
        at_ms: 1000,
        initial_calls: [],
        owners: [],
        ets: wire.EtsPass(
          tables: 1,
          memory_bytes: 10,
          skipped: 0,
          stop: wire.EtsDeadline,
        ),
      )),
    )
  let page = owners_page([early])

  assert page.unknown.ets_bytes == Missing(measure.DeadlineReached)

  let assert memory_model.EtsPassRead(reach: memory_model.StoppedAtDeadline, ..) =
    page.ets
}

pub fn the_memory_page_lists_the_tables_of_the_newest_listing_test() {
  let page = memory_page([collect(1), collect(0)])
  let assert memory_model.EtsListed(rows:, total:, read:, skipped:, ..) =
    page.ets.body
  let assert [row] = rows

  assert total == 9
  assert read == 8
  assert skipped == 1
  assert row.label == "registry"
  assert row.id == "#Ref<0.1.2.3>"
  assert row.owner_pid == "<0.10.0>"
  assert string.contains(row.owner_label, "session:s1")
  assert row.bytes == Known(9000)
  assert row.kind == "set"
  assert row.protection == "protected"
}

pub fn a_table_without_a_name_is_labelled_by_its_identifier_test() {
  let pass = collect(0)
  let assert Ok(listing) = pass.ets
  let snapshot = listing.snapshot
  let assert [table] = snapshot.tables
  let anonymous =
    Observation(
      ..pass,
      ets: Ok(
        readings.EtsListing(
          ..listing,
          snapshot: wire.EtsSnapshot(..snapshot, tables: [
            wire.EtsTable(..table, name: "", owner: wire.Unlabelled),
          ]),
        ),
      ),
    )
  let assert memory_model.EtsListed(rows: [row], ..) =
    memory_page([anonymous]).ets.body

  assert row.label == "#Ref<0.1.2.3>"
  assert row.owner_label == "unknown"
}

// A pass between listings leaves the page the last listing and its age.
pub fn the_memory_page_says_when_no_pass_listed_the_tables_test() {
  let page = memory_page([collect(1)])
  let assert memory_model.EtsListingMissing(reason) = page.ets.body

  assert string.contains(reason, "every 5 passes")
}

// ------------------------------------------------------------- supervision

fn edge(
  child: String,
  parent: String,
  name: String,
  call: String,
) -> wire.SpawnEdge {
  wire.SpawnEdge(child, parent, name, call, wire.Unlabelled)
}

fn supervision_of(
  edges: List(wire.SpawnEdge),
  calls: List(#(String, String)),
) -> model.SupervisionModel {
  supervision_build.build(
    feeds_info(),
    wire.SupervisionSnapshot(
      coverage: wire.SupervisionCoverage(
        list.length(edges),
        list.length(edges),
        wire.SupervisionFinished,
        1,
      ),
      edges:,
    ),
    dict.from_list(calls),
  )
}

fn feeds_info() -> model.PanelInfo {
  model.PanelInfo(
    source: "x",
    method: "y",
    cadence: measure.OneShot,
    achieved_ms: None,
    took_ms: None,
    coverage: measure.Coverage(
      scope: "z",
      requested: 1,
      achieved: 1,
      outcome: measure.Complete,
      dropped_events: measure.NotApplicable,
      in_flight_events: measure.NotApplicable,
      unscanned_bytes: measure.NotApplicable,
    ),
  )
}

// A process whose own initial call is known is classed by it. A worker that
// is named like a supervisor is a worker, and a supervisor with no `_sup` in
// its name is a supervisor.
pub fn a_known_initial_call_decides_a_supervisor_from_a_worker_test() {
  let page =
    supervision_of(
      [
        edge("<0.1.0>", "", "", "proc_lib:init_p/5"),
        edge("<0.2.0>", "<0.1.0>", "pretend_sup", "proc_lib:init_p/5"),
        edge("<0.3.0>", "<0.1.0>", "", "proc_lib:init_p/5"),
        edge("<0.4.0>", "<0.3.0>", "", "proc_lib:init_p/5"),
      ],
      [
        #("<0.1.0>", "supervisor:top/1"),
        #("<0.2.0>", "my_server:init/1"),
        #("<0.3.0>", "supervisor:my_app_sup/1"),
        #("<0.4.0>", "gen_statem:init_it/6"),
      ],
    )
  let assert [top] = page.roots

  assert top.kind == model.Supervisor
  assert list.map(top.children, fn(node) { node.kind })
    == [model.Worker, model.Supervisor]

  let assert [_, inner] = top.children

  assert list.map(inner.children, fn(node) { node.kind }) == [model.Worker]
}

// A process the census did not list keeps the name and initial-call hints,
// which the page still calls hints.
pub fn an_unlisted_process_keeps_the_hints_test() {
  let page =
    supervision_of(
      [
        edge("<0.1.0>", "", "kernel_sup", "proc_lib:init_p/5"),
        edge("<0.2.0>", "<0.1.0>", "", "m:run/1"),
      ],
      [],
    )
  let assert [root] = page.roots

  assert root.kind == model.Supervisor
  assert list.map(root.children, fn(node) { node.kind }) == [model.Leaf]
}

pub fn the_supervision_feed_reads_initial_calls_from_the_newest_pass_test() {
  let supervision =
    wire.SupervisionSnapshot(
      coverage: wire.SupervisionCoverage(2, 2, wire.SupervisionFinished, 1),
      edges: [
        edge("<0.10.0>", "", "", "proc_lib:init_p/5"),
        edge("<0.11.0>", "<0.10.0>", "", "proc_lib:init_p/5"),
      ],
    )
  let with =
    feeds.Inputs(..inputs([collect(1)]), supervision: Some(Ok(supervision)))
  let assert Ok(page) =
    list.find_map(feeds.feeds_for(feeds.Supervision, with), fn(feed) {
      case feed {
        msg.FedSupervision(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })
  let assert [root] = page.roots

  // `<0.10.0>` is `supervisor:my_sup/1` in the pass's rows.
  assert root.kind == model.Supervisor
  // `<0.11.0>` has no initial call in the rows, so only the hints are left.
  assert list.map(root.children, fn(node) { node.kind }) == [model.Leaf]
}

// --------------------------------------------------------------- binaries

pub fn a_binaries_read_is_planned_and_then_confirmed_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, plan) =
    page.submit(seam.PlanReadBinaries(token))

  assert policy.plan_perturbation(plan) == policy.Polling

  // Nothing was asked of the agent before the confirm.
  assert list.all(fixture.drain(rig.seen, 20), fn(request) {
    case request {
      wire.Extended(wire.AskBinaries(..)) -> False
      _ -> True
    }
  })

  let assert seam.BinariesRead(snapshot) = page.submit(seam.ConfirmPlan(id))

  assert snapshot == binaries()

  let assert [seam.BinariesRan(kept, _)] = page.results()

  assert kept == snapshot
}

pub fn a_binaries_read_needs_the_observe_capability_test() {
  let rig = harness.live(script, None)
  let token = pinned(harness.page(rig, "alice", harness.all))
  let reader = harness.page(rig, "reader", [policy.Profile])
  let assert seam.Rejected(reason) = reader.submit(seam.PlanReadBinaries(token))

  assert string.contains(reason, "missing capability observe")
}

// A malformed token is refused before the gate sees it.
pub fn a_binaries_read_of_a_malformed_pin_is_refused_test() {
  assert seam.intent(seam.PlanReadBinaries("not a token"))
    == Error("malformed pin token")
}

pub fn a_refused_binaries_read_is_kept_in_the_agents_words_test() {
  let rig = harness.live(refusing, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, _) = page.submit(seam.PlanReadBinaries(token))
  let assert seam.Rejected(reason) = page.submit(seam.ConfirmPlan(id))

  assert string.contains(reason, "too_many_binaries")

  let assert [seam.BinariesRefused(kept_token, kept_reason, _)] = page.results()

  assert kept_token == token
  assert string.contains(kept_reason, "too_many_binaries")
}

fn detail_page(
  results: List(seam.ProcessResult),
  pins: List(seam.PinCard),
) -> model.ProcessDetailModel {
  let with =
    feeds.Inputs(
      ..inputs([fixture.observation(1, 3000)]),
      subject: Some(feeds.row_key("<0.10.0>")),
      pins:,
      results:,
    )
  let assert Ok(data) =
    list.find_map(feeds.feeds_for(feeds.ProcessDetail, with), fn(feed) {
      case feed {
        msg.FedProcessDetail(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  data
}

pub fn the_process_page_shows_the_newest_binaries_read_test() {
  let snapshot = wire.BinariesSnapshot(..binaries(), pid_text: "<0.10.0>")
  let data =
    detail_page([seam.BinariesRan(snapshot, 4000)], [
      seam.PinCard("pin-x", "<0.10.0>", seam.PinLive, 1),
    ])

  assert data.binaries
    == memory_model.BinariesListed(
      distinct: 3,
      bytes: 121_000,
      references: 100,
      largest: [
        memory_model.BinaryRow("7f00aa", Known(120_000), Known(3)),
        memory_model.BinaryRow("7f00bb", Known(1000), Known(1)),
      ],
      age_ms: 6000,
    )
}

pub fn a_refusal_is_shown_on_the_process_it_was_made_over_test() {
  let pin = seam.PinCard("pin-x", "<0.10.0>", seam.PinLive, 1)
  let refused =
    detail_page(
      [
        seam.BinariesRefused(
          "pin-x",
          "the agent refused (too_many_binaries)",
          9000,
        ),
      ],
      [pin],
    )

  assert refused.binaries
    == memory_model.BinariesRefused(
      reason: "the agent refused (too_many_binaries)",
      age_ms: 1000,
    )

  // Another process's pin, or none, does not carry the refusal.
  let other =
    detail_page(
      [
        seam.BinariesRefused(
          "pin-y",
          "the agent refused (too_many_binaries)",
          9000,
        ),
      ],
      [pin],
    )

  assert other.binaries == memory_model.BinariesNotRead
  assert detail_page([], [pin]).binaries == memory_model.BinariesNotRead
}

// A read of another process's binaries is not this process's reading.
pub fn another_processs_binaries_are_not_shown_test() {
  let data =
    detail_page([seam.BinariesRan(binaries(), 4000)], [
      seam.PinCard("pin-x", "<0.10.0>", seam.PinLive, 1),
    ])

  assert data.binaries == memory_model.BinariesNotRead
}

// A plan the process page's button made is confirmed there, where the
// button was.
pub fn a_binaries_plan_is_drawn_above_every_page_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, plan) =
    page.submit(seam.PlanReadBinaries(token))
  let with =
    feeds.Inputs(
      ..inputs([fixture.observation(1, 3000)]),
      page:,
      pins: [seam.PinCard(token, "<0.5.0>", seam.PinLive, 1)],
      plans: [#(id, plan)],
    )
  let assert Ok(flow) =
    list.find_map(feeds.feeds_for(feeds.Owners, with), fn(feed) {
      case feed {
        msg.FedFlow(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })
  let assert Some(card) = flow.pending

  assert card.what == model.BinariesPlan
  assert card.key == feeds.plan_key(id)
}

// A capture saved after a read keeps the reading.
pub fn a_saved_capture_keeps_the_binaries_it_read_test() {
  let directory = "build/memory_readings_out"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let rig =
    harness.live(
      script,
      Some(service.Saver(directory:, facts: facts(), cadence_ms: 2000)),
    )
  let page = harness.page(rig, "alice", harness.all)
  let updates = process.new_subject()

  // A capture needs a pass to describe the runtime from.
  let assert Ok(Nil) = page.subscribe(updates)
  hub.tick(rig.hub)
  let assert Ok(hub.Observed(_)) = process.receive(updates, 3000)

  let token = pinned(page)
  let assert seam.PlanReady(id, _) = page.submit(seam.PlanReadBinaries(token))
  let assert seam.BinariesRead(_) = page.submit(seam.ConfirmPlan(id))
  let assert seam.CaptureSaved(path) = page.submit(seam.SaveCapture)
  let assert Ok(loaded) = capture_file.read(path)

  assert list.any(loaded.capture.records, fn(record) {
    case record {
      capture.BinariesRecord(readings.BinariesReading(snapshot:, ..)) ->
        snapshot == binaries()
      _ -> False
    }
  })
}

// ------------------------------------------------------------------- strip

fn strip_of(with: feeds.Inputs) -> model.StripModel {
  let assert Ok(strip) =
    list.find_map(feeds.feeds_for(feeds.Overview, with), fn(feed) {
      case feed {
        msg.FedStrip(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  strip
}

// After a detach the strip says the node is gone and what that means, and
// does not go on describing an attachment with full authority.
pub fn a_lost_target_is_said_in_the_banner_line_test() {
  let live = strip_of(inputs([collect(0)]))
  let gone =
    strip_of(feeds.Inputs(..inputs([collect(0)]), lost: Some("detached")))

  assert live.source == model.Live
  assert string.contains(
    live.banner.source_line,
    "full code-execution authority",
  )
  assert gone.source == model.Detached("detached")
  assert string.contains(
    gone.banner.source_line,
    "Detached from the target (detached)",
  )
  assert !string.contains(gone.banner.source_line, "full code-execution")
}
