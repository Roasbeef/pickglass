//// Tests for the pages that show the agent's ETS, binaries and initial-call
//// readings: the owners page's ETS column, the memory page's table listing,
//// the process page's binaries panel and the plan card of a binaries read.

import gleam/option.{Some}
import gleam/string
import lustre/element
import pickglass_core/measure
import pickglass_core/policy
import pickglass_web/app
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/memory_model
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/state
import pickglass_web/view/memory
import pickglass_web/view/owners
import pickglass_web/view/probes
import pickglass_web/view/process_detail
import pickglass_web/view/supervision

fn owners_html(data: model.OwnersModel) -> String {
  element.to_string(owners.view(
    data,
    state.initial(),
    page.Files,
    policy.all_capabilities,
  ))
}

fn detail_html(data: model.ProcessDetailModel) -> String {
  element.to_string(process_detail.view(
    data,
    policy.all_capabilities,
    page.Files,
  ))
}

// ------------------------------------------------------------ owners

pub fn the_owners_page_draws_an_ets_column_with_its_coverage_test() {
  let shown = owners_html(fixture.owners())

  assert string.contains(shown, "ETS")
  assert string.contains(shown, "pass read 210 tables")
  assert string.contains(shown, "never contents")
  assert string.contains(shown, "count under unknown")
}

// A pass that ran out of time says every figure understates, and a pass that
// listed fewer owners than it tracked says a row may have no aggregate.
pub fn an_ets_pass_that_stopped_early_says_it_understates_test() {
  let page =
    model.OwnersModel(
      ..fixture.owners(),
      ets: memory_model.EtsPassRead(
        tables: 100,
        bytes: 4096,
        skipped: 3,
        reach: memory_model.StoppedAtDeadline,
        owners: 100,
        tracked: 250,
      ),
    )
  let shown = owners_html(page)

  assert string.contains(shown, "so every ETS figure here understates")
  assert string.contains(
    shown,
    "3 tables were deleted before they could be read",
  )
  assert string.contains(shown, "aggregates for 100 of 250 owners")
}

pub fn an_unread_ets_pass_is_said_in_words_test() {
  let page =
    model.OwnersModel(
      ..fixture.owners(),
      ets: memory_model.EtsNotRead("the agent refused (busy)"),
    )

  assert string.contains(
    owners_html(page),
    "ETS column not read: the agent refused (busy).",
  )
}

// A row the aggregate does not cover shows the word for why, never a zero.
pub fn an_owner_row_without_an_ets_reading_shows_a_word_test() {
  let page = fixture.owners()
  let unread =
    model.OwnersModel(
      ..page,
      unknown: model.OwnerRow(
        ..page.unknown,
        ets_bytes: measure.Missing(measure.BudgetExhausted),
        ets_tables: measure.Missing(measure.BudgetExhausted),
      ),
    )

  assert string.contains(owners_html(unread), "num word")
}

// ------------------------------------------------------------ memory

pub fn the_memory_page_lists_the_largest_ets_tables_test() {
  let shown = element.to_string(memory.view(fixture.memory()))

  assert string.contains(shown, "ETS tables, largest first")
  assert string.contains(shown, "conversation_index")
  assert string.contains(shown, "ordered_set")
  assert string.contains(shown, "protected")
  assert string.contains(
    shown,
    "Table properties only: contents are never read.",
  )
  assert string.contains(shown, "Listing the largest 2 of 210 tables read")
}

pub fn a_walk_that_stopped_early_says_its_figures_understate_test() {
  let base = fixture.memory()
  let assert memory_model.EtsListed(..) as listed = base.ets.body

  let early =
    model.MemoryModel(
      ..base,
      ets: model.Panel(
        info: base.ets.info,
        body: memory_model.EtsListed(
          ..listed,
          reach: memory_model.StoppedAtDeadline,
          skipped: 4,
        ),
      ),
    )
  let shown = element.to_string(memory.view(early))

  assert string.contains(shown, "The walk stopped at its deadline")
  assert string.contains(
    shown,
    "4 tables were deleted before they could be read",
  )
}

pub fn a_missing_table_walk_is_said_in_words_test() {
  let base = fixture.memory()
  let missing =
    model.MemoryModel(
      ..base,
      ets: model.Panel(
        info: base.ets.info,
        body: memory_model.EtsListingMissing("the agent refused (busy)"),
      ),
    )

  assert string.contains(
    element.to_string(memory.view(missing)),
    "The ETS table walk has not answered: the agent refused (busy).",
  )
}

// ------------------------------------------------------- process binaries

pub fn a_process_page_shows_the_binaries_it_read_test() {
  let shown = detail_html(fixture.process_detail())

  assert string.contains(shown, "212 distinct binaries")
  assert string.contains(shown, "1,840 references")
  assert string.contains(shown, "7f31a0c4e010")
  assert string.contains(shown, "counts once")
  assert string.contains(shown, "not memory it alone owns")
}

pub fn a_refused_binaries_read_is_shown_plainly_test() {
  let data =
    model.ProcessDetailModel(
      ..fixture.process_detail(),
      binaries: memory_model.BinariesRefused(
        reason: "the agent refused (too_many_binaries): the process holds too many references to list",
        age_ms: 2000,
      ),
    )
  let shown = detail_html(data)

  assert string.contains(shown, "too_many_binaries")
  assert string.contains(shown, "no partial figure is shown")
  assert !string.contains(shown, "distinct binaries")
}

pub fn an_unread_process_says_the_read_is_planned_first_test() {
  let data =
    model.ProcessDetailModel(
      ..fixture.process_detail(),
      binaries: memory_model.BinariesNotRead,
    )
  let shown = detail_html(data)

  assert string.contains(shown, "planned and confirmed first")
  assert string.contains(shown, "more than 50,000")
}

// The read button needs a pin, since the agent reads a pinned process only,
// and the observe capability.
pub fn the_binaries_button_needs_a_pin_and_the_observe_capability_test() {
  let pinned = fixture.process_detail()
  let unpinned = model.ProcessDetailModel(..pinned, pin: model.NotPinned)

  assert string.contains(detail_html(pinned), "Read binaries")
  assert !string.contains(detail_html(unpinned), "Read binaries")
  assert !string.contains(
    element.to_string(process_detail.view(pinned, [], page.Files)),
    "Read binaries",
  )
}

pub fn a_binaries_plan_names_its_cost_and_what_it_does_not_prove_test() {
  let assert Some(card) = fixture.plan_card_of(policy.CallTree, ["lists"], 5000)
  let shown =
    element.to_string(probes.plan_dialog(
      model.PlanCard(..card, what: model.BinariesPlan),
    ))

  assert string.contains(shown, "Read the binaries one process holds")
  assert string.contains(shown, "one entry per reference-counted binary")
  assert string.contains(shown, "more than 50,000 references is refused")
  assert string.contains(shown, "a sub-binary counts the whole")
  assert !string.contains(shown, "modules ")
}

// The request names a pin the page must hold, like every request that does.
pub fn a_binaries_request_for_an_unknown_pin_is_refused_test() {
  let model =
    app.init(app.Start(page: page.ProcessDetail, links: page.Files, feeds: []))
  let #(model, _) =
    app.update(
      fn(_) { panic as "no request leaves the page" },
      model,
      msg.Ask(msg.PlanBinaries(key.make("pin.nothing"))),
    )

  assert option_notice(model) == "That pin is not held by this page."
}

fn option_notice(model: app.Model) -> String {
  option.unwrap(model.ui.notice, "")
}

// ------------------------------------------------------------ supervision

pub fn a_worker_with_a_known_initial_call_is_badged_a_worker_test() {
  let node =
    model.SupNode(
      key: key.make("proc.1"),
      label: "gen_worker <0.1.0>",
      kind: model.Worker,
      owner_label: option.None,
      children: [],
    )
  let data = model.SupervisionModel(..fixture.supervision(), roots: [node])
  let shown = element.to_string(supervision.view(data, page.Files))

  assert string.contains(shown, "worker")
  assert !string.contains(shown, "kind unknown")
}
