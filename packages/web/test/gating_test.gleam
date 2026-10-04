import gleam/string
import gleeunit/should
import lustre/element
import pickglass_core/policy
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/view/process_detail
import support

pub fn memory_sums_only_additive_rows_and_marks_the_rest_test() {
  let html = support.html_of(page.Memory)

  string.contains(html, "Sum of additive rows") |> should.be_true
  string.contains(html, "≈") |> should.be_true
  string.contains(html, "part of processes") |> should.be_true
}

pub fn a_page_without_data_says_it_is_waiting_not_zero_test() {
  let model =
    app.init(app.Start(page: page.Owners, links: page.Files, feeds: []))

  let html = element.to_string(app.view(model))

  string.contains(html, "Waiting for the viewer") |> should.be_true
  string.contains(html, "<table") |> should.be_false
}

pub fn a_feed_replaces_one_pages_data_only_test() {
  let model =
    app.init(app.Start(page: page.Audit, links: page.Files, feeds: []))

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request" },
      model,
      msg.Fed(msg.FedAudit(fixture.audit())),
    )

  let html = element.to_string(app.view(model))

  string.contains(html, "denied: plan expired") |> should.be_true
}

// Buttons exist only for capabilities the principal holds, because an
// offered button is an attached handler.
pub fn the_gc_button_needs_the_perturb_capability_test() {
  let data = fixture.process_detail()

  let with_perturb =
    element.to_string(process_detail.view(
      data,
      policy.all_capabilities,
      page.Files,
      "",
    ))

  let without =
    element.to_string(process_detail.view(
      data,
      [policy.Observe],
      page.Files,
      "",
    ))

  string.contains(with_perturb, "Plan targeted GC") |> should.be_true
  string.contains(without, "Plan targeted GC") |> should.be_false
  string.contains(without, "Self-measure") |> should.be_false
  string.contains(without, "Unpin") |> should.be_true
}

pub fn the_plan_form_is_absent_without_the_profile_capability_test() {
  let data = fixture.probes()
  let no_profile = [policy.Observe]

  let model =
    app.init(app.Start(page: page.Probes, links: page.Files, feeds: []))

  let #(model, _) =
    app.update(
      fn(_) { panic as "no request" },
      model,
      msg.Fed(msg.FedProbes(model.ProbesModel(..data, grants: no_profile))),
    )

  let html = element.to_string(app.view(model))

  string.contains(html, "Plan probe…") |> should.be_false
}
