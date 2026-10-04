//// What the UI review of the newer surfaces found, one assertion each where
//// the fix is a sentence or a structure the page must keep: an empty trace
//// draws no frame, a collection says it ran, the compare page does not
//// contradict itself, and the house rules on shadows and accent bars hold.

import gleam/option.{None, Some}
import gleam/string
import lustre/effect
import lustre/element
import pickglass_core/layout/flame
import pickglass_core/measure
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/memory_model
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import support

fn run(model: app.Model, message: msg.Msg) -> app.Model {
  app.update(fn(_) { effect.none() }, model, message).0
}

fn html_after(target: page.Page, feeds: List(msg.Msg)) -> String {
  let model = list_fold(feeds, app.init(fixture.start(target, page.Files)))

  element.to_string(app.view(model))
}

fn list_fold(feeds: List(msg.Msg), model: app.Model) -> app.Model {
  case feeds {
    [] -> model
    [first, ..rest] -> list_fold(rest, run(model, first))
  }
}

// ------------------------------------------------------------ empty trace

pub fn an_empty_flame_says_nothing_was_measured_and_what_to_do_test() {
  let assert Ok(data) = fixture.profile() as "the fixture profile builds"
  let assert model.HasStacks(layout:, graph:, dag:, peeks:) = data.stacks
  let empty =
    model.ProfileModel(
      ..data,
      stacks: model.HasStacks(
        layout: flame.Layout(..layout, total: 0, omitted_boxes: 1),
        graph:,
        dag:,
        peeks:,
      ),
    )

  let html = html_after(page.Profile, [msg.Fed(msg.FedProfile(empty))])

  assert string.contains(html, "Nothing was measured")
  assert string.contains(html, "widen the module pattern")
  assert !string.contains(html, "were folded into their parents")
  assert !string.contains(html, "Click a box to select it.")
}

pub fn one_folded_box_agrees_in_number_test() {
  let assert Ok(data) = fixture.profile() as "the fixture profile builds"
  let assert model.HasStacks(layout:, graph:, dag:, peeks:) = data.stacks
  let one =
    model.ProfileModel(
      ..data,
      stacks: model.HasStacks(
        layout: flame.Layout(..layout, omitted_boxes: 1),
        graph:,
        dag:,
        peeks:,
      ),
    )

  let html = html_after(page.Profile, [msg.Fed(msg.FedProfile(one))])

  assert string.contains(html, "1 box narrower than the minimum was folded")
}

pub fn the_graph_tab_has_a_key_for_its_figures_test() {
  let assert Ok(data) = fixture.profile() as "the fixture profile builds"
  let html =
    html_after(page.Profile, [
      msg.Fed(msg.FedProfile(data)),
      msg.Ui(msg.OpenTab(msg.GraphTab)),
    ])

  assert string.contains(html, "flat (self) · cumulative")
  assert string.contains(html, "darker node has a larger")
}

// ------------------------------------------------------------ collection

pub fn a_collection_says_it_ran_even_when_nothing_was_freed_test() {
  let html =
    html_after(page.Overview, [
      msg.Fed(msg.FedFlow(
        model.FlowModel(
          ..fixture.flow(),
          pending: None,
          running: [],
          ready: None,
          collected: Some(memory_model.Collected(
            pid: "p-77",
            age_ms: 60_000,
            before: measure.Known(1_480_000),
            after: measure.Known(1_480_000),
          )),
        ),
      )),
    ])

  assert string.contains(html, "Collected p-77 1 min 0 s ago")
  assert string.contains(html, "nothing freed")
}

pub fn a_collection_that_freed_memory_says_how_much_test() {
  let html =
    html_after(page.Overview, [
      msg.Fed(msg.FedFlow(
        model.FlowModel(
          ..fixture.flow(),
          pending: None,
          running: [],
          ready: None,
          collected: Some(memory_model.Collected(
            pid: "p-77",
            age_ms: 4000,
            before: measure.Known(3_145_728),
            after: measure.Known(1_048_576),
          )),
        ),
      )),
    ])

  assert string.contains(html, "2.00 MiB freed")
}

// ------------------------------------------------------------ compare

pub fn the_compare_verdict_badges_are_not_form_fields_test() {
  let html = support.html_of(page.Compare)

  assert !string.contains(html, "badge field")
  assert string.contains(html, "match-mark")
}

pub fn the_compare_budget_prints_the_event_cap_it_judges_test() {
  let html = support.html_of(page.Compare)

  assert string.contains(html, "event cap")
}

// ------------------------------------------------------------ house rules

pub fn a_toast_says_what_was_asked_not_what_is_decided_test() {
  let sentence = app.describe(msg.ProfileBusiest)

  assert string.starts_with(sentence, "Asked the viewer to ")
  assert !string.contains(sentence, "decides")
}

pub fn a_notice_is_drawn_once_not_beside_the_form_too_test() {
  let model =
    app.init(fixture.start(page.Profile, page.Files))
    |> run(msg.Ask(msg.ProfileBusiest))
  let html = element.to_string(app.view(model))

  assert support.count(html, "Asked the viewer to") == 1
}
