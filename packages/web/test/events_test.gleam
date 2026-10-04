import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect as lustre_effect
import pickglass_core/policy
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/msg
import pickglass_web/page
import support

fn problems(sim: simulate.Simulation(a, b)) -> List(String) {
  simulate.history(sim)
  |> list.filter_map(fn(event) {
    case event {
      simulate.Problem(name:, ..) -> Ok(name)
      _ -> Error(Nil)
    }
  })
}

// A click on a pin button decodes to a request that names the row's key.
pub fn a_pin_click_becomes_a_request_naming_the_row_key_test() {
  let sim =
    support.simulation(on: page.Processes)
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Pin"),
      )),
    )

  let model = simulate.model(sim)

  model.ui.last_request
  |> should.equal(Some(msg.RequestPin(fixture.keeper_key())))
}

// The request is recorded as pending; nothing here authorizes it.
pub fn a_request_is_reported_as_pending_not_done_test() {
  let sim =
    support.simulation(on: page.Processes)
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Pin"),
      )),
    )

  simulate.model(sim).ui.notice
  |> should.equal(Some(app.describe(msg.RequestPin(fixture.keeper_key()))))
}

// A select whose value is a key outside the alphabet is dropped by its
// decoder: update never runs and the model is unchanged.
pub fn a_forged_select_value_with_a_tab_is_dropped_test() {
  let before = support.simulation(on: page.Overview)

  let after =
    before
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [#("target", json.object([#("value", json.string("cp\tidle"))]))],
    )

  problems(after) |> should.equal(["EventHandlerNotFound"])
  simulate.model(after) |> should.equal(simulate.model(before))
}

pub fn a_select_value_of_the_wrong_type_is_dropped_test() {
  let after =
    support.simulation(on: page.Overview)
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [#("target", json.object([#("value", json.int(7))]))],
    )

  problems(after) |> should.equal(["EventHandlerNotFound"])
}

pub fn an_event_with_no_target_payload_is_dropped_test() {
  let after =
    support.simulation(on: page.Overview)
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [],
    )

  problems(after) |> should.equal(["EventHandlerNotFound"])
}

pub fn an_over_long_key_is_dropped_test() {
  let long = key_text(80)

  let after =
    support.simulation(on: page.Overview)
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [#("target", json.object([#("value", json.string(long))]))],
    )

  problems(after) |> should.equal(["EventHandlerNotFound"])
}

fn key_text(n: Int) -> String {
  list.repeat("a", n) |> list.fold("", fn(acc, c) { acc <> c })
}

// A well-formed key the page never issued passes the decoder but not
// update's membership check: no request leaves the page.
pub fn a_well_formed_key_the_page_never_issued_is_refused_test() {
  let after =
    support.simulation(on: page.Overview)
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [#("target", json.object([#("value", json.string("cp.forged"))]))],
    )

  let model = simulate.model(after)

  model.ui.last_request |> should.equal(None)
  model.ui.notice |> should.equal(Some("That checkpoint is not offered."))
}

pub fn a_known_checkpoint_key_is_accepted_test() {
  let after =
    support.simulation(on: page.Overview)
    |> simulate.event(
      on: query.element(matching: query.tag("select")),
      name: "change",
      data: [
        #("target", json.object([#("value", json.string("cp.pre-restart"))])),
      ],
    )

  simulate.model(after).ui.last_request
  |> should.equal(Some(msg.ChooseBaseline(key.make("cp.pre-restart"))))
}

pub fn a_selection_of_an_unknown_box_changes_nothing_test() {
  let sim = support.simulation(on: page.Profile)

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      simulate.model(sim),
      msg.Ui(msg.SelectBox(key.make("b9.9.9"))),
    )

  model.ui.selected |> should.equal(None)
  model.ui.notice |> should.equal(Some("That box is not in the drawn graph."))
}

pub fn confirming_a_plan_other_than_the_one_shown_is_refused_test() {
  let sim = support.simulation(on: page.Probes)

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      simulate.model(sim),
      msg.Ask(msg.ConfirmPlan(key.make("plan.stale"))),
    )

  model.ui.last_request |> should.equal(None)
}

pub fn confirming_the_plan_shown_sends_the_request_test() {
  let after =
    support.simulation(on: page.Probes)
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Confirm and run"),
      )),
    )

  simulate.model(after).ui.last_request
  |> should.equal(Some(msg.ConfirmPlan(key.make("plan.1"))))
}

// Pinning something the process page does not hold is refused.
pub fn a_pin_request_for_an_unknown_row_is_refused_test() {
  let sim = support.simulation(on: page.Processes)

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      simulate.model(sim),
      msg.Ask(msg.RequestPin(key.make("proc.99999"))),
    )

  model.ui.last_request |> should.equal(None)
}

pub fn toggling_an_owner_row_expands_it_test() {
  let id = key.make("owner:session:s-12")

  let sim =
    support.simulation(on: page.Owners)
    |> simulate.click(
      on: query.element(matching: query.attribute("aria-expanded", "false")),
    )

  let model = simulate.model(sim)

  { set.size(model.ui.expanded) > 0 } |> should.be_true
  { set.contains(model.ui.expanded, id) || set.size(model.ui.expanded) == 1 }
  |> should.be_true
}

pub fn the_plan_form_refuses_bad_module_patterns_test() {
  let sim = support.simulation(on: page.Probes)

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      simulate.model(sim),
      msg.Ui(msg.DraftTarget(key.indexed("proc", 1))),
    )

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      model,
      msg.Ui(msg.DraftModules("../etc/passwd")),
    )

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request expected" },
      model,
      msg.Ui(msg.SubmitDraft),
    )

  model.ui.last_request |> should.equal(None)
  model.ui.plan.kind |> should.equal(policy.Counters)
}

pub fn the_plan_form_sends_a_checked_draft_test() {
  let sim = support.simulation(on: page.Probes)
  let update = fn(model, message) {
    app.update(fn(_) { effect_none() }, model, message).0
  }

  let model =
    simulate.model(sim)
    |> update(msg.Ui(msg.DraftTarget(key.indexed("proc", 1))))
    |> update(msg.Ui(msg.DraftModules("loom@runtime@keeper lists")))
    |> update(msg.Ui(msg.SubmitDraft))

  model.ui.last_request
  |> should.equal(
    Some(
      msg.PlanProbe(msg.ProbeDraft(
        kind: policy.Counters,
        targets: [key.indexed("proc", 1)],
        modules: ["loom@runtime@keeper", "lists"],
        duration: msg.Seconds30,
      )),
    ),
  )
}

pub fn an_invalid_filter_pattern_is_not_sent_test() {
  let update = fn(model, message) {
    app.update(fn(_) { effect_none() }, model, message).0
  }

  let model =
    simulate.model(support.simulation(on: page.Profile))
    |> update(msg.Ui(msg.FilterPattern("*bad")))
    |> update(msg.Ui(msg.SubmitFilter))

  model.ui.last_request |> should.equal(None)
}

pub fn a_valid_filter_pattern_is_sent_test() {
  let update = fn(model, message) {
    app.update(fn(_) { effect_none() }, model, message).0
  }

  let model =
    simulate.model(support.simulation(on: page.Profile))
    |> update(msg.Ui(msg.FilterPattern("loom@runtime")))
    |> update(msg.Ui(msg.SubmitFilter))

  model.ui.last_request
  |> should.equal(Some(msg.AddFilter(msg.FocusFilter, "loom@runtime")))
}

fn effect_none() {
  lustre_effect.none()
}

pub fn a_wildcard_module_is_refused_with_the_reason_before_any_request_test() {
  let sim = support.simulation(on: page.Probes)
  let update = fn(model, message) {
    app.update(fn(_) { effect_none() }, model, message).0
  }

  let model =
    simulate.model(sim)
    |> update(msg.Ui(msg.DraftTarget(key.indexed("proc", 1))))
    |> update(msg.Ui(msg.DraftModules("runtime@*")))
    |> update(msg.Ui(msg.SubmitDraft))

  model.ui.last_request |> should.equal(None)
  assert string.contains(option.unwrap(model.ui.notice, ""), "no wildcard")
}
