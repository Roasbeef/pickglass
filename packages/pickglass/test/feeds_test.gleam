//// What each page is fed from what the viewer holds.

import fixture
import gleam/list
import gleam/option.{None, Some}
import harness
import pickglass/feeds
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
import pickglass_core/wire
import pickglass_web/model
import pickglass_web/msg

fn page() -> seam.Page {
  seam.Page(
    principal: policy.PrincipalId("p-test"),
    grants: policy.all_capabilities,
    mode: harness.mode(),
    latest: fn() { [] },
    subscribe: fn(_) { Ok(Nil) },
    submit: fn(_) { seam.Done("") },
    plans: fn() { [] },
    checkpoints: fn() { [] },
    probes: fn() { [] },
    results: fn() { [] },
    captures: fn() { [] },
    read_capture: fn(_) { Error("none") },
    audit: fn(_) { [] },
    pins: fn() { [] },
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
    chain: [],
    exports: [],
    comparison: feeds.no_comparison,
    now_ms: 10_000,
    subject: None,
    detail: None,
    results: [],
    supervision: None,
    entries: [],
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

  // The macOS start time is marked coarse in a note, not hidden.
  let assert [target, ..] = page.roles.body

  assert target.note == "start time is good to a second"
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
    probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2),
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

pub fn the_profile_page_waits_when_no_probe_has_measured_anything_test() {
  let running =
    probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2)

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
    probe_book.started(8, policy.Counters, ["lists"], 5000, 30_000, 2)
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
