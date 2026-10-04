//// Tests for what the viewer feeds the pages: the profile builder, the
//// compare page's offers, exports on the profile page, and the plan-target
//// suggestion.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/dev/simulate
import pickglass_core/analysis/transform
import pickglass_core/profile
import pickglass_core/unit
import pickglass_web/app
import pickglass_web/build/profile as profile_page
import pickglass_web/fixture
import pickglass_web/fixture/stacks
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import support

fn header(source: profile.Source) -> model.ProfileHeader {
  let assert Ok(base) = fixture.profile()

  model.ProfileHeader(..base.header, source:)
}

fn counters() -> profile.Profile {
  let assert Ok(built) =
    profile.new(
      profile.TracedCounters,
      [
        profile.ValueType(name: "calls", unit: unit.Count),
        profile.ValueType(name: "call time", unit: unit.Nanoseconds),
      ],
      [
        profile.Function(0, "lists", "map", 2, None, None, profile.NoLine),
        profile.Function(1, "lists", "foldl", 3, None, None, profile.NoLine),
      ],
      [
        profile.Sample(frames: [0], values: [10, 5000], labels: []),
        profile.Sample(frames: [1], values: [3, 9000], labels: []),
      ],
    )

  built
}

pub fn a_counters_profile_has_a_top_table_and_no_stacks_test() {
  let base = counters()
  let assert Ok(column) = profile.column_named(base, "call time")
  let assert Ok(page) =
    profile_page.build(header(profile.TracedCounters), base, column, [], [])

  assert page.stacks == model.NoStacks(source: profile.TracedCounters)
  assert list.length(page.top.rows) == 2
  assert page.top.totals == [13, 14_000]
}

pub fn a_stack_profile_has_every_view_test() {
  let assert Ok(base) = stacks.build(stacks.Base)
  let assert Ok(column) = profile.column_named(base, "samples")
  let assert Ok(page) =
    profile_page.build(header(profile.source(base)), base, column, [], [])

  let assert model.HasStacks(layout:, ..) = page.stacks

  assert layout.total == profile.total(base, column)
}

pub fn a_chain_step_changes_the_total_and_is_reported_test() {
  let assert Ok(base) = stacks.build(stacks.Base)
  let assert Ok(column) = profile.column_named(base, "samples")
  let whole = profile.total(base, column)
  let assert Ok(page) =
    profile_page.build(
      header(profile.source(base)),
      base,
      column,
      [transform.Focus(pattern: "loom@")],
      [],
    )

  let assert [report] = page.chain

  assert report.total_before == whole
  assert report.total_after < whole
  assert profile.total(page.profile, column) == report.total_after
}

pub fn a_pattern_core_refuses_is_a_failure_not_a_page_test() {
  let assert Ok(base) = stacks.build(stacks.Base)
  let assert Ok(column) = profile.column_named(base, "samples")

  assert profile_page.build(
      header(profile.source(base)),
      base,
      column,
      [transform.Focus(pattern: "*bad")],
      [],
    )
    |> is_chain_refusal
}

fn is_chain_refusal(
  built: Result(model.ProfileModel, profile_page.Failure),
) -> Bool {
  case built {
    Error(profile_page.ChainRefused(_)) -> True
    _ -> False
  }
}

fn with_offers(
  sim: simulate.Simulation(app.Model, msg.Msg),
) -> simulate.Simulation(app.Model, msg.Msg) {
  let info = fixture.probes().info

  simulate.message(
    sim,
    msg.Fed(
      msg.FedCaptures(model.CapturesModel(
        info:,
        offers: [
          model.CaptureOffer(
            key: key.make("cap:a.pgcap"),
            name: "a.pgcap",
            chosen: model.NotChosen,
          ),
        ],
        note: "Choose a baseline and a candidate.",
      )),
    ),
  )
}

pub fn the_compare_page_offers_capture_files_with_two_buttons_test() {
  let sim = support.simulation(on: page.Compare) |> with_offers

  let html = string.inspect(simulate.view(sim))

  assert string.contains(html, "a.pgcap")
  assert string.contains(html, "Baseline")
  assert string.contains(html, "Candidate")
}

pub fn a_capture_key_the_page_offered_is_accepted_as_a_baseline_test() {
  let sim =
    support.simulation(on: page.Compare)
    |> with_offers
    |> simulate.message(msg.Ask(msg.ChooseBaseline(key.make("cap:a.pgcap"))))

  assert simulate.model(sim).ui.last_request
    == Some(msg.ChooseBaseline(key.make("cap:a.pgcap")))
}

pub fn a_capture_key_nobody_offered_is_refused_test() {
  let sim =
    support.simulation(on: page.Compare)
    |> with_offers
    |> simulate.message(
      msg.Ask(msg.ChooseCandidate(key.make("cap:forged.pgcap"))),
    )

  assert simulate.model(sim).ui.last_request == None
  assert simulate.model(sim).ui.notice == Some("That capture is not offered.")
}

pub fn a_suggested_plan_target_is_applied_only_when_offered_test() {
  let assert [#(first, _), ..] = fixture.probes().targets

  let applied =
    support.simulation(on: page.Probes)
    |> simulate.message(msg.Fed(msg.FedPlanTarget(first)))

  assert simulate.model(applied).ui.plan.target == Some(first)

  let ignored =
    support.simulation(on: page.Probes)
    |> simulate.message(msg.Fed(msg.FedPlanTarget(key.make("pin.nobody"))))

  assert simulate.model(ignored).ui.plan.target == None
}

pub fn an_export_offers_a_link_and_a_refusal_gives_its_reason_test() {
  let assert Ok(data) = fixture.profile()
  let noted =
    model.ProfileModel(..data, exports: [
      model.ExportReady(
        label: "Speedscope",
        ticket: key.make("abc_DEF-123"),
        losses: ["coverage"],
      ),
      model.ExportRefused(label: "Collapsed stacks", reason: "no stacks"),
    ])

  let sim =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Fed(msg.FedProfile(noted)))
  let html = string.inspect(simulate.view(sim))

  assert string.contains(html, "/download/abc_DEF-123")
  assert string.contains(html, "no stacks")
}
