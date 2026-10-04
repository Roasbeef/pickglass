//// The one-click profile on the pages: where its buttons are, who is offered
//// them, what they send, and how the plan and the finished profile are drawn
//// above a page.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/element
import pickglass_core/policy
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/state
import pickglass_web/view/overview
import pickglass_web/view/owners
import pickglass_web/view/process_detail
import pickglass_web/view/processes
import support

fn button(label: String) -> query.Selector {
  query.and(query.tag("button"), query.text(label))
}

fn last_request(
  sim: simulate.Simulation(app.Model, msg.Msg),
) -> option.Option(msg.Request) {
  simulate.model(sim).ui.last_request
}

// ------------------------------------------------------------- the buttons

pub fn the_overview_offers_the_busiest_profile_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.click(
      on: query.element(matching: button("Profile the busiest 16")),
    )

  last_request(sim) |> should.equal(Some(msg.ProfileBusiest))
}

pub fn the_processes_page_offers_the_busiest_profile_test() {
  let sim =
    support.simulation(on: page.Processes)
    |> simulate.click(
      on: query.element(matching: button("Profile the busiest 16")),
    )

  last_request(sim) |> should.equal(Some(msg.ProfileBusiest))
}

pub fn every_owner_row_offers_a_profile_of_its_own_processes_test() {
  let html = support.html_of(page.Owners)
  let data = fixture.owners()
  // Role rows appear only under an open owner, so a closed page has a
  // button on each owner and on the unknown row.
  let rows = list.count(data.rows, fn(row) { row.kind == model.OwnerGroup }) + 1

  // One button per owner row, role rows and the unknown row included, each
  // naming its row's key and nothing else.
  assert support.count(html, "btn-profile") == rows

  let assert [first, ..] = data.rows
  let sim =
    support.simulation(on: page.Owners)
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.attribute(
          "title",
          "Pin the busiest processes of "
            <> first.label
            <> " and plan one stack probe over them",
        ),
      )),
    )

  last_request(sim) |> should.equal(Some(msg.ProfileOwner(first.key)))
}

pub fn the_process_page_offers_a_profile_of_that_process_test() {
  let sim =
    support.simulation(on: page.ProcessDetail)
    |> simulate.click(
      on: query.element(matching: button("Profile this process")),
    )

  last_request(sim)
  |> should.equal(Some(msg.ProfileProcess(fixture.process_detail().key)))
}

// A button is an attached handler, so it is drawn only for a principal who
// could use it: pinning needs observe, planning a probe needs profile.
pub fn the_buttons_need_both_capabilities_test() {
  let observing = [policy.Observe]
  let profiling = [policy.Profile]
  let both = [policy.Observe, policy.Profile]
  let detail = fixture.process_detail()

  let drawn = fn(grants) {
    [
      element.to_string(overview.view(fixture.overview(), None, grants)),
      element.to_string(processes.view(fixture.processes(), page.Files, grants)),
      element.to_string(owners.view(
        fixture.owners(),
        state.initial(),
        page.Files,
        grants,
      )),
      element.to_string(process_detail.view(detail, grants, page.Files, "")),
    ]
    |> list.map(fn(html) { string.contains(html, "btn-profile") })
  }

  drawn(both) |> should.equal([True, True, True, True])
  drawn(observing) |> should.equal([False, False, False, False])
  drawn(profiling) |> should.equal([False, False, False, False])
}

// ------------------------------------------------------------------ the flow

pub fn the_plan_states_the_processes_rate_duration_and_budget_test() {
  let html = support.html_of(page.Overview)

  // The processes, how they were chosen, and each figure of the run.
  assert string.contains(html, "3 process(es) revalidated")
  assert string.contains(
    html,
    "3 of 3 processes of session s-12, the busiest by reductions/s",
  )
  assert string.contains(html, "100 Hz per process")
  assert string.contains(html, "at most 3,000 samples")
  assert string.contains(html, "100 Hz × 3 processes")
  assert string.contains(html, "Confirm and run")
}

pub fn the_plan_says_when_the_agent_lowers_the_rate_test() {
  let assert Some(card) = fixture.flow().pending
  let assert policy.StartProbe(spec:) = policy.plan_command(card.plan)

  // Sixteen processes share the agent's ceiling of 1,000 samples a second.
  assert policy.sampling_rate_hz(spec.rate_hz, 16) == 62
}

pub fn the_flow_is_not_drawn_twice_on_the_probes_page_test() {
  let html = support.html_of(page.Probes)

  // The Probes page draws its own plan, and no flow above it.
  assert support.count(html, "Confirm and run") == 1
  assert !string.contains(html, "Open profile")
}

pub fn the_flow_offers_a_link_to_the_profile_test() {
  let html = support.html_of(page.Overview)

  assert string.contains(html, "Open profile")
  assert string.contains(html, "profile.html")
  assert string.contains(html, "1,840 samples at 100 Hz")

  // The profile page needs no link to itself.
  assert !string.contains(support.html_of(page.Profile), "Open profile")
}

pub fn a_plan_in_the_flow_is_confirmed_by_its_key_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.click(on: query.element(matching: button("Confirm and run")))

  last_request(sim)
  |> should.equal(Some(msg.ConfirmPlan(key.make("plan.2"))))
}

pub fn a_forged_plan_key_is_refused_before_it_leaves_the_page_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.message(msg.Ask(msg.ConfirmPlan(key.make("plan.99"))))

  last_request(sim) |> should.equal(None)
  simulate.model(sim).ui.notice
  |> should.equal(Some("That plan is not the one shown."))
}

pub fn a_running_profile_is_stopped_by_its_key_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.click(on: query.element(matching: button("Stop")))

  last_request(sim)
  |> should.equal(Some(msg.StopProbe(key.make("probe.p-41"))))
}

// The plan's duration and rate are buttons that plan the same processes
// again, so the browser never sends a number.
pub fn the_plan_can_be_remade_with_another_duration_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.click(on: query.element(matching: button("30 s")))

  last_request(sim)
  |> should.equal(
    Some(msg.AdjustProfile(key.make("plan.2"), msg.Seconds30, msg.Hz100)),
  )
}

pub fn the_plan_can_be_remade_with_another_rate_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.click(on: query.element(matching: button("250 Hz")))

  last_request(sim)
  |> should.equal(
    Some(msg.AdjustProfile(key.make("plan.2"), msg.Seconds10, msg.Hz250)),
  )
}

pub fn a_hand_drafted_plan_offers_no_adjustment_test() {
  let html = support.html_of(page.Probes)

  assert !string.contains(html, "dialog-adjust")
}

pub fn an_adjustment_of_another_plan_is_refused_test() {
  let sim =
    support.simulation(on: page.Overview)
    |> simulate.message(
      msg.Ask(msg.AdjustProfile(key.make("plan.99"), msg.Seconds10, msg.Hz50)),
    )

  last_request(sim) |> should.equal(None)
}

pub fn a_refusal_is_said_where_the_button_was_test() {
  let data =
    model.FlowModel(
      pending: None,
      running: [],
      ready: None,
      refused: Some("no live process carries that owner"),
    )
  let model =
    app.init(app.Start(page: page.Owners, links: page.Files, feeds: []))
  let #(model, _) =
    app.update(
      fn(_) { panic as "no request" },
      model,
      msg.Fed(msg.FedFlow(data)),
    )
  let html = element.to_string(app.view(model))

  assert string.contains(
    html,
    "No profile was planned: no live process carries that owner",
  )
}

pub fn an_empty_flow_draws_nothing_test() {
  let data =
    model.FlowModel(pending: None, running: [], ready: None, refused: None)
  let model =
    app.init(app.Start(page: page.Owners, links: page.Files, feeds: []))
  let #(model, _) =
    app.update(
      fn(_) { panic as "no request" },
      model,
      msg.Fed(msg.FedFlow(data)),
    )

  assert !string.contains(element.to_string(app.view(model)), "class=\"flow")
}
