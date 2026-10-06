//// What each page is fed from what the viewer holds.

import fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import lustre/element
import pickglass/feeds
import pickglass/gate
import pickglass/marks
import pickglass/observation.{Observation}
import pickglass/os_reader
import pickglass/probe_book
import pickglass/seam
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{Known, Missing, NotApplicable}
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/wire
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/state
import pickglass_web/view/profile as profile_view

fn page() -> seam.Page {
  seam.Page(
    principal: policy.PrincipalId("p-test"),
    grants: policy.all_capabilities,
    mode: harness.mode(),
    latest: fn() { [] },
    subscribe: fn(_) { Ok(Nil) },
    submit: fn(_) { seam.Done("") },
    profile: fn(_) { seam.Done("") },
    profile_notes: fn() { [] },
    plans: fn() { [] },
    checkpoints: fn() { [] },
    probes: fn() { [] },
    results: fn() { [] },
    captures: fn() { [] },
    read_capture: fn(_) { Error("none") },
    audit: fn(_) { [] },
    pins: fn() { [] },
    lost: fn() { None },
  )
}

fn inputs(observations: List(observation.Observation)) -> feeds.Inputs {
  feeds.Inputs(
    page: page(),
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

fn with_os(observation: observation.Observation) -> observation.Observation {
  Observation(
    ..observation,
    os: Ok([
      os_reader.Reading(
        pid: 42,
        role: "target",
        rss: Known(900_000),
        anon: Missing(measure.UnsupportedOnPlatform),
        cpu_ms: Known(100),
        start: identity.CoarseStart("Fri Oct 3 12:00:00 2026"),
      ),
      os_reader.Reading(
        pid: 43,
        role: "child inet_gethost",
        rss: Known(4096),
        anon: Missing(measure.UnsupportedOnPlatform),
        cpu_ms: Known(1),
        start: identity.CoarseStart("Fri Oct 3 12:00:07 2026"),
      ),
    ]),
  )
}

fn overview_of(feeds: List(msg.Feed)) -> model.OverviewModel {
  let assert Ok(found) =
    list.find_map(feeds, fn(feed) {
      case feed {
        msg.FedOverview(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

fn row(page: model.OverviewModel, label: String) -> model.LayerRow {
  let assert Ok(found) =
    list.find(page.layers.body, fn(row) { row.label == label })

  found
}

pub fn the_overview_has_no_change_without_a_checkpoint_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([with_os(fixture.observation(1, 3000))]),
    ))

  assert row(page, "erlang:memory total").delta == NotApplicable
  assert page.checkpoint == None
  assert page.checkpoints == []
}

pub fn the_overview_shows_changes_since_the_chosen_checkpoint_test() {
  let before = fixture.observation(0, 1000)
  let after = with_os(fixture.observation(5, 9000))
  let mark = marks.take(capture.Checkpoint("idle-0", 0, 1500), Some(before))
  let found =
    feeds.feeds_for(
      feeds.Overview,
      feeds.Inputs(..inputs([after, before]), marks: [mark]),
    )
  let page = overview_of(found)

  assert row(page, "erlang:memory total").delta == Known(5000)

  // The checkpoint is offered by a key a browser can send back.
  let assert Some(chosen) = page.checkpoint

  assert chosen.checkpoint.name == "idle-0"
  assert chosen.key == feeds.checkpoint_key(0)
}

pub fn the_overview_lists_the_target_and_its_children_with_the_os_figures_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([with_os(fixture.observation(1, 3000))]),
    ))

  assert list.map(page.roles.body, fn(role) { #(role.role, role.rss) })
    == [
      #("target", Known(900_000)),
      #("child inet_gethost", Known(4096)),
    ]

  assert row(page, "OS resident set (target)").value == Known(900_000)
}

pub fn an_unreadable_os_is_a_word_in_the_layer_and_an_error_on_the_panel_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([fixture.observation(1, 3000)]),
    ))

  assert row(page, "OS resident set (target)").value
    == Missing(measure.CounterDisabled)
  assert page.roles.body == []
  assert page.roles.info.coverage.outcome
    == measure.Errored("the capture holds no OS readings")
}

fn owners_of(feeds: List(msg.Feed)) -> model.OwnersModel {
  let assert Ok(found) =
    list.find_map(feeds, fn(feed) {
      case feed {
        msg.FedOwners(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

fn growing(seq: Int, at_ms: Int, bytes: Int) -> observation.Observation {
  Observation(
    ..fixture.observation(seq, at_ms),
    census: Ok(
      fixture.census([
        fixture.row(
          "<0.10.0>",
          bytes,
          fixture.labelled("session", "s1", "worker"),
        ),
        fixture.row("<0.11.0>", 4000, wire.Unlabelled),
      ]),
    ),
  )
}

pub fn the_owners_page_shows_each_groups_heap_change_since_the_checkpoint_test() {
  let before = growing(0, 1000, 16_000)
  let after = growing(1, 3000, 48_000)
  let mark = marks.take(capture.Checkpoint("c", 0, 1500), Some(before))
  let found =
    feeds.feeds_for(
      feeds.Owners,
      feeds.Inputs(..inputs([after, before]), marks: [mark]),
    )
  let page = owners_of(found)

  // The row builder's heap capacity is total_heap_words * 8, and the memory
  // argument fixture.row divides by 16 to get words.
  let assert Ok(session) =
    list.find(page.rows, fn(row) { row.label == "session:s1" })

  assert session.delta == Known({ 48_000 / 16 - 16_000 / 16 } * 8)
  assert page.unknown.delta == Known(0)
}

pub fn an_owner_the_baseline_could_not_have_listed_has_no_baseline_test() {
  let before =
    Observation(
      ..growing(0, 1000, 16_000),
      census: Ok(
        wire.CensusSnapshot(
          ..fixture.census([fixture.row("<0.11.0>", 4000, wire.Unlabelled)]),
          coverage: wire.CensusCoverage(
            scanned: 500,
            total: 500,
            stop: wire.ScanBudgetReached,
            elapsed_ms: 1,
          ),
        ),
      ),
    )
  let mark = marks.take(capture.Checkpoint("c", 0, 1500), Some(before))
  let page =
    owners_of(feeds.feeds_for(
      feeds.Owners,
      feeds.Inputs(..inputs([growing(1, 3000, 48_000), before]), marks: [mark]),
    ))
  let assert Ok(session) =
    list.find(page.rows, fn(row) { row.label == "session:s1" })

  // The baseline census was cut at its budget, so a missing owner may have
  // been below the cut: a word, not "it grew from nothing".
  assert session.delta == Missing(measure.BudgetExhausted)
}

// A census whose walk finished but which lists only its top rows: five
// hundred processes scanned, the rows of `census` listed.
fn top_rows_only(
  observation: observation.Observation,
) -> observation.Observation {
  let assert Ok(census) = observation.census

  Observation(
    ..observation,
    census: Ok(
      wire.CensusSnapshot(
        ..census,
        coverage: wire.CensusCoverage(
          scanned: 500,
          total: 500,
          stop: wire.WalkFinished,
          elapsed_ms: 1,
        ),
      ),
    ),
  )
}

fn session_delta(
  after: observation.Observation,
  before: observation.Observation,
) -> measure.Measurement {
  let mark = marks.take(capture.Checkpoint("c", 0, 1500), Some(before))
  let page =
    owners_of(feeds.feeds_for(
      feeds.Owners,
      feeds.Inputs(..inputs([after, before]), marks: [mark]),
    ))
  let assert Ok(session) =
    list.find(page.rows, fn(row) { row.label == "session:s1" })

  session.delta
}

pub fn a_finished_walk_that_listed_only_top_rows_is_not_a_complete_baseline_test() {
  // The owner is absent from the baseline's top rows because it was below
  // the cut, not because it was not there.
  let before =
    top_rows_only(
      Observation(
        ..growing(0, 1000, 16_000),
        census: Ok(
          fixture.census([fixture.row("<0.11.0>", 4000, wire.Unlabelled)]),
        ),
      ),
    )

  assert session_delta(growing(1, 3000, 48_000), before)
    == Missing(measure.BudgetExhausted)
}

pub fn an_owner_listed_on_both_sides_of_a_cut_census_has_no_change_test() {
  // Both sides list the owner, but each sums a different part of its
  // processes, so their difference is not a change.
  assert session_delta(
      top_rows_only(growing(1, 3000, 48_000)),
      growing(0, 1000, 16_000),
    )
    == Missing(measure.BudgetExhausted)
  assert session_delta(
      growing(1, 3000, 48_000),
      top_rows_only(growing(0, 1000, 16_000)),
    )
    == Missing(measure.BudgetExhausted)
}

pub fn the_movers_feed_names_the_checkpoint_and_the_owners_test() {
  let before = growing(0, 1000, 16_000)
  let after = growing(1, 3000, 48_000)
  let mark = marks.take(capture.Checkpoint("c", 0, 1500), Some(before))
  let found =
    feeds.feeds_for(
      feeds.Overview,
      feeds.Inputs(..inputs([after, before]), marks: [mark]),
    )
  let assert Ok(movers) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedOwnerMovers(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  assert movers.since == "c"
  assert list.map(movers.rows, fn(mover) { mover.label })
    == ["session:s1", "unknown"]
}

pub fn there_are_no_movers_before_a_checkpoint_test() {
  let found =
    feeds.feeds_for(feeds.Overview, inputs([growing(1, 3000, 48_000)]))

  assert list.all(found, fn(feed) {
    case feed {
      msg.FedOwnerMovers(_) -> False
      _ -> True
    }
  })
}

fn finished_counters() -> probe_book.ProbeRecord {
  probe_book.finish_counters(
    probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2, 1),
    wire.CountersSnapshot(
      probe_id: 7,
      state: wire.ProbeFinished,
      matched_functions: 2,
      elapsed_ms: 30_004,
      functions: 2,
      with_calls: 2,
      invalidated: 0,
      rows: [
        wire.FunctionRow("lists", "map", 2, 10, 5),
        wire.FunctionRow("maps", "get", 2, 3, 9),
      ],
    ),
    31_000,
  )
}

fn profile_of(feeds: List(msg.Feed)) -> Result(model.ProfileModel, Nil) {
  list.find_map(feeds, fn(feed) {
    case feed {
      msg.FedProfile(data) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn the_profile_page_is_fed_from_the_finished_counters_probe_test() {
  let found =
    feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [finished_counters()]),
    )
  let assert Ok(data) = profile_of(found)

  assert data.header.title == "probe 7 · lists"
  assert data.header.source == profile.TracedCounters
  assert data.stacks == model.NoStacks(source: profile.TracedCounters)
  assert list.length(data.top.rows) == 2
  assert data.header.info.coverage.requested == 2
  assert data.header.info.coverage.achieved == 2
}

// An allocation profile is ranked by the words it counted, not by the call
// time a counters profile is ranked by, and its page says what produced it.
pub fn the_profile_page_ranks_an_allocation_probe_by_words_test() {
  let probe =
    probe_book.finish_allocation(
      probe_book.started(9, policy.CallMemory, ["m"], 1000, 5000, 3, 2),
      wire.CountersSnapshot(
        probe_id: 9,
        state: wire.ProbeFinished,
        matched_functions: 3,
        elapsed_ms: 5004,
        functions: 3,
        with_calls: 2,
        invalidated: 0,
        rows: [],
      ),
      wire.CounterMemorySnapshot(
        9,
        wire.ProbeFinished,
        wire.MemoryCounted(
          [
            wire.FunctionMemory("m", "heavy", 1, 9000, 10, 100),
            wire.FunctionMemory("m", "slow", 1, 40, 10, 90_000),
          ],
          wire.MemoryTotals(read: 2, unread: 0, words: 9040),
        ),
      ),
      6000,
    )
  let found =
    feeds.feeds_for(feeds.Profile, feeds.Inputs(..inputs([]), probes: [probe]))
  let assert Ok(data) = profile_of(found)

  assert data.header.source == profile.AllocationCounts
  assert data.stacks == model.NoStacks(source: profile.AllocationCounts)
  assert data.header.title == "probe 9 · m"
  assert data.header.info.coverage.requested == 3
  assert data.header.info.coverage.achieved == 2

  // The table is by words: the function that allocated most is first, though
  // the other took far longer.
  let assert [first, ..] = data.top.rows

  assert first.name == "m:heavy/1"
  assert list.length(data.top.rows) == 2
}

pub fn the_profile_page_waits_when_no_probe_has_measured_anything_test() {
  let running =
    probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2, 1)

  assert profile_of(feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [running]),
    ))
    == Error(Nil)
}

pub fn a_chain_step_changes_the_totals_the_page_reports_test() {
  let chain = [transform.Focus(pattern: "^lists:")]
  let found =
    feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [finished_counters()], chain:),
    )
  let assert Ok(data) = profile_of(found)
  let assert [report] = data.chain

  // Two functions, 5 000 ns and 9 000 ns; focusing on `lists` keeps one.
  assert report.total_before == 14_000
  assert report.total_after == 5000
  assert list.length(data.top.rows) == 1
}

pub fn a_chain_core_refuses_falls_back_to_the_unfiltered_profile_test() {
  let found =
    feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [finished_counters()], chain: [
        transform.Focus(pattern: "*bad"),
      ]),
    )
  let assert Ok(data) = profile_of(found)

  assert data.chain == []
  assert list.length(data.top.rows) == 2
}

pub fn the_probes_page_lists_active_probes_and_history_with_keys_test() {
  let running =
    probe_book.started(8, policy.Counters, ["lists"], 5000, 30_000, 2, 1)
  let found =
    feeds.feeds_for(
      feeds.Probes,
      feeds.Inputs(..inputs([fixture.observation(1, 3000)]), probes: [
        running,
        finished_counters(),
      ]),
    )
  let assert Ok(data) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedProbes(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  assert list.map(data.active, fn(probe) { #(probe.key, probe.remaining_ms) })
    == [#(feeds.probe_key("8"), Known(25_000))]
  assert list.map(data.history, fn(row) { row.key }) == [feeds.probe_key("7")]
}

pub fn the_newest_live_pin_is_offered_as_the_first_plan_target_test() {
  let pins = [
    seam.PinCard("pin-a", "<0.1.0>", seam.PinLive, 1),
    seam.PinCard("pin-b", "<0.2.0>", seam.PinGone("died"), 2),
    seam.PinCard("pin-c", "<0.3.0>", seam.PinLive, 3),
  ]
  let found =
    feeds.feeds_for(
      feeds.Probes,
      feeds.Inputs(..inputs([fixture.observation(1, 3000)]), pins:),
    )

  assert list.contains(found, msg.FedPlanTarget(feeds.pin_key("pin-c")))
}

pub fn the_timeline_page_is_fed_from_the_ring_test() {
  let found =
    feeds.feeds_for(
      feeds.Timeline,
      inputs([fixture.observation(1, 3000), fixture.observation(0, 1000)]),
    )

  assert list.any(found, fn(feed) {
    case feed {
      msg.FedTimeline(_) -> True
      _ -> False
    }
  })
}

pub fn the_compare_page_offers_files_and_notes_what_is_missing_test() {
  let found =
    feeds.feeds_for(
      feeds.Compare,
      feeds.Inputs(
        ..inputs([]),
        comparison: feeds.Comparison(
          offers: ["a.pgcap", "b.pgcap"],
          baseline: Some("a.pgcap"),
          candidate: None,
          outcome: None,
        ),
      ),
    )
  let assert Ok(offers) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedCaptures(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  assert offers.note == "Choose a candidate."
  assert list.map(offers.offers, fn(offer) { offer.chosen })
    == [model.AsBaseline, model.NotChosen]
  assert list.all(found, fn(feed) {
    case feed {
      msg.FedCompare(_) -> False
      _ -> True
    }
  })
}

pub fn a_failed_comparison_is_a_note_with_its_reason_test() {
  let found =
    feeds.feeds_for(
      feeds.Compare,
      feeds.Inputs(
        ..inputs([]),
        comparison: feeds.Comparison(
          offers: ["a.pgcap"],
          baseline: Some("a.pgcap"),
          candidate: Some("a.pgcap"),
          outcome: Some(Error("the file is not a readable capture")),
        ),
      ),
    )
  let assert Ok(offers) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedCaptures(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  assert offers.note == "the file is not a readable capture"
}

fn processes_of(feeds: List(msg.Feed)) -> model.ProcessesModel {
  let assert Ok(found) =
    list.find_map(feeds, fn(feed) {
      case feed {
        msg.FedProcesses(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

fn reductions_of(
  page: model.ProcessesModel,
  pid: String,
) -> measure.Measurement {
  let assert Ok(row) = list.find(page.rows, fn(row) { row.pid_text == pid })

  row.reductions
}

pub fn reductions_are_a_rate_over_the_last_two_passes_test() {
  // The fixture's rows have reductions of three times their memory. The
  // first process went from 48 000 to 144 000 reductions in two seconds, the
  // second did not move, and the third was not in the earlier pass.
  let before = growing(0, 1000, 16_000)
  let after =
    Observation(
      ..growing(1, 3000, 48_000),
      census: Ok(
        fixture.census([
          fixture.row(
            "<0.10.0>",
            48_000,
            fixture.labelled("session", "s1", "worker"),
          ),
          fixture.row("<0.11.0>", 4000, wire.Unlabelled),
          fixture.row("<0.12.0>", 9000, wire.Unlabelled),
        ]),
      ),
    )
  let page =
    processes_of(feeds.feeds_for(feeds.Processes, inputs([after, before])))

  assert page.rate_ms == Some(2000)
  assert reductions_of(page, "<0.10.0>") == Known(48_000)
  assert reductions_of(page, "<0.11.0>") == Known(0)
  assert reductions_of(page, "<0.12.0>") == Missing(measure.NotInBothPasses)
}

pub fn there_is_no_rate_from_a_single_pass_test() {
  let page =
    processes_of(feeds.feeds_for(
      feeds.Processes,
      inputs([growing(0, 1000, 16_000)]),
    ))

  assert page.rate_ms == None
  assert reductions_of(page, "<0.10.0>") == Missing(measure.NotInBothPasses)
}

// ------------------------------------------------- critique two: owner deltas

// What the agent's owners reply carries for the owners it listed: each
// owner's heap words over every process the walk scanned. `listed` of
// `tracked` says how many owners it named.
fn with_aggregates(
  observation: observation.Observation,
  session_words: Int,
  tracked: Int,
  listed: Int,
) -> observation.Observation {
  let total = fn(owner, words) {
    wire.OwnerHeapTotal(
      total: wire.OwnerTotal(
        owner:,
        processes: 100,
        memory: words * 8,
        queue_length: 0,
        reductions: 0,
      ),
      total_heap_words: words,
    )
  }
  let session = fixture.labelled("session", "s1", "worker")

  Observation(
    ..observation,
    totals: Ok(wire.CensusTotals(
      500,
      0,
      0,
      0,
      session_words + 700,
      tracked,
      listed,
    )),
    owner_heaps: Ok(case session_words {
      0 -> [total(wire.Unlabelled, 700)]
      _ -> [total(session, session_words), total(wire.Unlabelled, 700)]
    }),
  )
}

// On a node with more processes than the census lists, the rows alone cannot
// give a change, but the per-owner aggregates cover every scanned process.
pub fn an_owner_change_comes_from_the_aggregates_on_a_large_node_test() {
  let before =
    with_aggregates(top_rows_only(growing(0, 1000, 16_000)), 1000, 2, 2)
  let after =
    with_aggregates(top_rows_only(growing(1, 3000, 48_000)), 3000, 2, 2)

  // Words times the node's eight bytes, not the listed rows' capacity.
  assert session_delta(after, before) == Known({ 3000 - 1000 } * 8)
}

pub fn an_owner_absent_from_a_complete_listing_was_not_there_test() {
  let before = with_aggregates(top_rows_only(growing(0, 1000, 16_000)), 0, 1, 1)
  let after =
    with_aggregates(top_rows_only(growing(1, 3000, 48_000)), 3000, 2, 2)

  assert session_delta(after, before) == Known(3000 * 8)
}

// The agent lists its largest owners only. An owner the baseline does not
// list may have been below its cut.
pub fn an_owner_absent_from_a_cut_listing_has_no_baseline_test() {
  let before =
    with_aggregates(top_rows_only(growing(0, 1000, 16_000)), 0, 400, 100)
  let after =
    with_aggregates(top_rows_only(growing(1, 3000, 48_000)), 3000, 2, 2)

  assert session_delta(after, before) == Missing(measure.BudgetExhausted)
}

// A walk that stopped at its scan budget summed part of the node, so the
// aggregates are not a basis for a change either.
pub fn a_walk_that_stopped_early_still_says_budget_exhausted_test() {
  let stopped = fn(observation: observation.Observation) {
    let assert Ok(census) = observation.census

    Observation(
      ..observation,
      census: Ok(
        wire.CensusSnapshot(
          ..census,
          coverage: wire.CensusCoverage(
            ..census.coverage,
            stop: wire.ScanBudgetReached,
          ),
        ),
      ),
    )
  }
  let before =
    with_aggregates(top_rows_only(growing(0, 1000, 16_000)), 1000, 2, 2)
  let after =
    stopped(with_aggregates(top_rows_only(growing(1, 3000, 48_000)), 3000, 2, 2))

  assert session_delta(after, before) == Missing(measure.BudgetExhausted)
}

// ------------------------------------------------- critique two: title bar

fn processes_info(found: List(msg.Feed)) -> model.PanelInfo {
  let assert Ok(info) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedProcesses(data) -> Ok(data.info)
        _ -> Error(Nil)
      }
    })

  info
}

// The achieved interval is the gap between the starts of the two newest
// passes, and how long the census took is a separate figure.
pub fn the_title_bar_separates_the_gap_between_passes_from_the_pass_cost_test() {
  let info =
    processes_info(feeds.feeds_for(
      feeds.Processes,
      inputs([fixture.observation(1, 5500), fixture.observation(0, 3000)]),
    ))

  assert info.achieved_ms == Some(2500)
  assert info.took_ms == Some(3)

  let first =
    processes_info(feeds.feeds_for(
      feeds.Processes,
      inputs([fixture.observation(0, 3000)]),
    ))

  assert first.achieved_ms == None
}

pub fn the_banner_is_one_short_sentence_per_fact_test() {
  let found =
    feeds.feeds_for(feeds.Overview, inputs([fixture.observation(1, 3000)]))
  let assert Ok(strip) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedStrip(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  assert string.length(strip.banner.source_line) < 150
  assert string.contains(strip.banner.source_line, "full code-execution")
  assert string.contains(strip.observer.note, "target CPU is not measured")
}

// ------------------------------------------------- critique two: profile

fn stacks_snapshot(samples: Int) -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 3,
    state: wire.ProbeFinished,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: 50,
      achieved_millihz: 49_000,
      rounds: samples,
      samples:,
      elapsed_ms: 10_000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 1,
      truncated_samples: 0,
    ),
    frames: [
      wire.StackFrame("loom@runtime", "leaf", 1, wire.NoLocation),
    ],
    stacks: [wire.SampledStack(samples, "running", [0])],
  )
}

// A stack probe covers samples against the rate it asked for over its
// duration, and not a count of matched functions.
pub fn a_stacks_profile_covers_samples_against_the_requested_rate_test() {
  let probe =
    probe_book.finish_stacks(
      probe_book.started(3, policy.Sampling, ["*"], 1000, 10_000, 1, 1),
      stacks_snapshot(500),
      12_000,
    )
  let assert Ok(data) =
    profile_of(feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [probe]),
    ))
  let coverage = data.header.info.coverage

  assert coverage.scope == "samples"
  assert coverage.requested == 500
  assert coverage.achieved == 500
  assert data.header.info.cadence == measure.OneShot
  assert data.header.info.achieved_ms == None
  assert string.contains(data.header.title, "all modules")
}

fn silent_counters(matched: Int) -> probe_book.ProbeRecord {
  probe_book.finish_counters(
    probe_book.started(9, policy.Counters, ["lists"], 1000, 30_000, matched, 1),
    wire.CountersSnapshot(
      probe_id: 9,
      state: wire.ProbeFinished,
      matched_functions: matched,
      elapsed_ms: 30_200,
      functions: matched,
      with_calls: 0,
      invalidated: 0,
      rows: [],
    ),
    31_000,
  )
}

// A counters probe whose functions were never called is a result: the page
// opens on Top and says so, and does not tell the operator that call stacks
// are missing from a source that never had any.
pub fn a_counters_profile_with_no_calls_says_nothing_was_called_test() {
  let assert Ok(data) =
    profile_of(feeds.feeds_for(
      feeds.Profile,
      feeds.Inputs(..inputs([]), probes: [silent_counters(144)]),
    ))
  let html = element.to_string(profile_view.view(data, state.initial()))

  assert data.header.info.coverage.requested == 144
  assert data.header.info.coverage.achieved == 0
  assert string.contains(html, "No calls to the 144 matched functions")
  assert !string.contains(html, "No call stacks in this source")
}

// ------------------------------------------------- critique two: plans

pub fn a_stack_probe_plan_is_bounded_by_its_rate_not_by_a_thousand_a_second_test() {
  let spec =
    policy.ProbeSpec(
      kind: policy.Sampling,
      targets: [fixture.pin_token(1)],
      modules: [],
      duration_ms: 10_000,
      rate_hz: 50,
    )
  let estimate = gate.estimate_for(policy.StartProbe(spec))

  assert estimate.events_high == 500

  let tracing =
    gate.estimate_for(policy.StartProbe(
      policy.ProbeSpec(..spec, kind: policy.CallTree),
    ))

  assert tracing.events_high == 10_000
}

// ------------------------------------------------- critique two: memory

fn carriers_observation() -> observation.Observation {
  Observation(
    ..fixture.observation(1, 3000),
    system: Ok(wire.SystemSnapshot(
      wire.NodeFacts(
        uptime_ms: 60_000,
        creation: 3,
        emulator_flavor: "jit",
        emulator_type: "opt",
        erts_version: "17.0.5",
        otp_release: "29",
        schedulers: 8,
        schedulers_online: 8,
        dirty_cpu: 8,
        dirty_cpu_online: 8,
        dirty_io: 10,
        word_size: 8,
      ),
      wire.CarriersRead([
        wire.CarrierRow(
          "ll_alloc",
          wire.NotInCarrierPool,
          4,
          1_500_000,
          900_000,
          0,
        ),
        wire.CarrierRow(
          "binary_alloc",
          wire.NotInCarrierPool,
          2,
          500_000,
          400_000,
          0,
        ),
      ]),
    )),
  )
}

// The question "capacity or native" is two differences: carriers beyond what
// the VM counts, and the resident set beyond the carriers.
pub fn the_layers_derive_the_two_gaps_between_the_vm_the_allocators_and_the_os_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([with_os(carriers_observation())]),
    ))
  let vm = 1_001_000
  let carriers = 2_000_000

  assert row(page, "allocator carriers").value == Known(carriers)
  assert row(page, "carriers beyond erlang:memory").value
    == Known(carriers - vm)
  assert row(page, "resident set beyond carriers").value
    == Known(900_000 - carriers)
  assert row(page, "carriers beyond erlang:memory").derivation != model.Measured
}

// A pass that has not read the node yet has no carriers, and the two gaps
// then say so in words rather than showing a difference with an unknown end.
pub fn the_gaps_are_words_until_the_carriers_are_read_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([with_os(fixture.observation(1, 3000))]),
    ))

  assert row(page, "allocator carriers").value == Missing(measure.NotCollected)
  assert row(page, "carriers beyond erlang:memory").value
    == Missing(measure.NotCollected)
}

pub fn the_memory_categories_nest_under_the_total_and_system_test() {
  let page =
    overview_of(feeds.feeds_for(
      feeds.Overview,
      inputs([with_os(fixture.observation(1, 3000))]),
    ))

  assert row(page, "erlang:memory total").depth == 0
  assert row(page, "system").depth == 1
}

// ------------------------------------------------- critique two: detail

pub fn a_zero_max_heap_is_no_limit_not_a_missing_reading_test() {
  let inputs =
    feeds.Inputs(
      ..inputs([with_os(fixture.observation(1, 3000))]),
      subject: Some(feeds.row_key("<0.10.0>")),
      pins: [seam.PinCard("pin-x", "<0.10.0>", seam.PinLive, 1)],
      detail: Some(
        Ok(
          wire.ProcessDetail(
            pid_text: "<0.10.0>",
            sizes: wire.ProcessSizes(5000, 4096, 2048, 64),
            activity: wire.ProcessActivity(
              2,
              900,
              "waiting",
              "m:f/1",
              "erlang:apply/2",
              "",
            ),
            gc: wire.ProcessGc(7, 65_535, 1864, 0, 4096, 0, 0, 0, 0),
            relations: wire.ProcessRelations(2, 1, 3, "<0.49.0>"),
            owner: wire.Unlabelled,
            capabilities: [],
          ),
        ),
      ),
    )
  let assert Ok(data) =
    list.find_map(feeds.feeds_for(feeds.ProcessDetail, inputs), fn(feed) {
      case feed {
        msg.FedProcessDetail(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })
  let assert Ok(max_heap) =
    list.find(data.gc, fn(counter) { counter.label == "max heap" })

  assert max_heap.inapplicable == "no limit"
  assert data.birth == "initial call erlang:apply/2, spawned by <0.49.0>"
  assert data.info.coverage.scope == "passes"
}
