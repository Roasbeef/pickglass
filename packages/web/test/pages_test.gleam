import gleam/list
import gleam/string
import gleeunit/should
import pickglass_web/page
import support

// Every page renders from its fixture, shows the strip and navigation, and
// is not the waiting placeholder.
pub fn every_page_renders_from_its_fixture_test() {
  list.each(
    [
      page.Overview,
      page.Owners,
      page.Processes,
      page.ProcessDetail,
      page.Memory,
      page.Supervision,
      page.Probes,
      page.Profile,
      page.Timeline,
      page.Compare,
      page.Audit,
    ],
    fn(target) {
      let html = support.html_of(target)

      string.contains(html, "pickglass") |> should.be_true
      string.contains(html, "Waiting for the viewer") |> should.be_false
      string.contains(html, "class=\"nav\"") |> should.be_true
    },
  )
}

pub fn the_strip_carries_the_capability_banner_and_observer_meter_test() {
  let html = support.html_of(page.Overview)

  string.contains(html, "Attached: full trust") |> should.be_true
  string.contains(html, "meter") |> should.be_true
  string.contains(html, "1 probe running") |> should.be_true
  string.contains(html, "inc 7f3a") |> should.be_true
}

pub fn every_data_panel_has_the_title_bar_line_test() {
  let html = support.html_of(page.Owners)

  string.contains(html, "meta-source") |> should.be_true
  string.contains(html, "every 10.0 s (actual 10.0 s)") |> should.be_true
  string.contains(html, "3,412 of 3,412 processes") |> should.be_true
  string.contains(html, "truncated: top_k_limit") |> should.be_true
}

pub fn a_missing_value_is_a_word_never_a_zero_test() {
  let html = support.html_of(page.Overview)

  string.contains(html, "missing (unsupported_on_runtime)") |> should.be_true
  string.contains(html, "num word") |> should.be_true
}

pub fn derived_gap_rows_are_labelled_derived_test() {
  let html = support.html_of(page.Overview)

  string.contains(html, "gap: carriers − total") |> should.be_true
  string.contains(html, "derived") |> should.be_true
}

pub fn supervision_is_labelled_as_evidence_test() {
  let html = support.html_of(page.Supervision)

  string.contains(html, "evidence, not ownership") |> should.be_true
  string.contains(html, "no application master") |> should.be_true
}

pub fn the_probe_plan_states_scope_cost_perturbation_and_what_it_does_not_prove_test() {
  let html = support.html_of(page.Probes)

  string.contains(html, "Scope") |> should.be_true
  string.contains(html, "4,000 to 22,000 events") |> should.be_true
  string.contains(html, "Perturbation") |> should.be_true
  string.contains(html, "Does not prove") |> should.be_true
  string.contains(html, "Confirm and run") |> should.be_true
}

pub fn the_profile_chain_shows_totals_and_the_class_of_each_step_test() {
  let html = support.html_of(page.Profile)

  string.contains(html, "10,708 → 9,148") |> should.be_true
  string.contains(html, "changes totals") |> should.be_true
  string.contains(html, "rewrites stacks") |> should.be_true
  string.contains(html, "display only") |> should.be_true
  string.contains(html, "matched nothing") |> should.be_true
}

pub fn compare_withholds_verdicts_under_a_blocking_mismatch_test() {
  let html = support.html_of(page.Compare)

  string.contains(html, "MISMATCH") |> should.be_true
  string.contains(html, "unmatched: workload") |> should.be_true
  string.contains(html, "higher") |> should.be_false
  string.contains(html, "lower") |> should.be_false
}

pub fn the_audit_page_lists_denials_with_reasons_test() {
  let html = support.html_of(page.Audit)

  string.contains(html, "denied: missing capability: perturb") |> should.be_true
  string.contains(html, "denied: plan expired") |> should.be_true
}
