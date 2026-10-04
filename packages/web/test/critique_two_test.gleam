//// The second round of live-page fixes: title-bar wording, plan costs, the
//// memory page, the processes and owners tables, the profile page and the
//// compare page.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import lustre/element
import pickglass_core/layout/flame
import pickglass_core/measure.{Known, Missing}
import pickglass_core/policy
import pickglass_core/unit
import pickglass_web/chart/flame as flame_chart
import pickglass_web/fixture
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/state
import pickglass_web/view/memory
import pickglass_web/view/owners
import pickglass_web/view/probes
import pickglass_web/view/processes
import pickglass_web/view/profile as profile_view
import pickglass_web/view/ui
import support

fn count(html: String, needle: String) -> Int {
  support.count(html, needle)
}

// ------------------------------------------------------------ title bar

fn info(
  cadence: measure.Cadence,
  gap: option.Option(Int),
  took: option.Option(Int),
) -> model.PanelInfo {
  model.PanelInfo(
    ..fixture.owners().info,
    cadence:,
    achieved_ms: gap,
    took_ms: took,
  )
}

// The time a pass took is a cost, not an interval. It follows the cadence
// as its own segment and is never written as the interval achieved.
pub fn the_title_bar_says_took_and_not_actual_test() {
  let parts = ui.meta_parts(info(measure.EveryMs(2000), Some(2010), Some(77)))

  list.contains(parts, "every 2.00 s · took 77 ms") |> should.be_true
  string.join(parts, " ") |> string.contains("actual") |> should.be_false
}

// The interval is stated only when the collector fell behind its cadence,
// and that is judged by the gap between passes, never by how long one took.
pub fn a_slow_pass_is_not_a_missed_cadence_but_a_late_one_is_test() {
  let slow_pass = info(measure.EveryMs(2000), Some(2000), Some(9980))
  let late = info(measure.EveryMs(2000), Some(3400), Some(77))

  ui.cadence_missed(slow_pass.cadence, slow_pass.achieved_ms)
  |> should.be_false
  ui.cadence_missed(late.cadence, late.achieved_ms) |> should.be_true
  list.contains(
    ui.meta_parts(late),
    "every 2.00 s (achieved 3.40 s) · took 77 ms",
  )
  |> should.be_true
}

pub fn a_one_shot_panel_has_no_cadence_to_miss_test() {
  let probe = info(measure.OneShot, None, Some(9980))

  list.contains(ui.meta_parts(probe), "one shot · took 9.98 s")
  |> should.be_true
  ui.cadence_missed(probe.cadence, probe.achieved_ms) |> should.be_false
}

// ------------------------------------------------------------ plans

pub fn a_collection_is_one_action_not_events_test() {
  let estimate =
    policy.Estimate(events_low: 1, events_high: 1, bytes_high: 0, wall_ms: 50)
  let text = probes.cost_text(policy.ForcedGc, estimate, 0)

  text
  |> should.equal(
    "one collection · about 50 ms · the process is stopped meanwhile",
  )
}

pub fn a_stack_probe_counts_samples_test() {
  let estimate =
    policy.Estimate(
      events_low: 0,
      events_high: 500,
      bytes_high: 64_000,
      wall_ms: 10_000,
    )
  let text = probes.cost_text(policy.Polling, estimate, 10_000)

  string.contains(text, "up to 500 samples") |> should.be_true
  string.contains(text, "events") |> should.be_false

  let request =
    policy.Estimate(events_low: 1, events_high: 1, bytes_high: 0, wall_ms: 2000)

  probes.cost_text(policy.Polling, request, 0)
  |> should.equal("one request · waits at most 2.00 s")
}

// ------------------------------------------------------------ memory

fn row(
  label: String,
  value: Int,
  used: measure.Measurement,
  why: String,
) -> model.CategoryRow {
  model.CategoryRow(
    label:,
    unit: unit.Bytes,
    value: Known(value),
    used:,
    additivity: measure.Overlapping(why:),
    note: "",
  )
}

fn memory_page(rows: List(model.CategoryRow)) -> String {
  let base = fixture.memory()

  element.to_string(memory.view(
    model.MemoryModel(
      ..base,
      allocators: model.Panel(info: base.allocators.info, body: rows),
    ),
  ))
}

// A table of rows that overlap for one reason says it once, with the rows it
// applies to, and not once per row.
pub fn an_overlap_reason_is_written_once_test() {
  let html =
    memory_page([
      row("ll_alloc", 100, Known(40), "allocators share the memory"),
      row("binary_alloc", 50, Known(10), "allocators share the memory"),
      row("eheap_alloc", 20, Known(20), "allocators share the memory"),
    ])

  // Each row's own hover text carries the reason; the note carries it once.
  count(
    html,
    "ll_alloc, binary_alloc, eheap_alloc: allocators share the memory.",
  )
  |> should.equal(1)
}

// Capacity and use are separate readings; the unused part is derived from
// them and drawn as its own column, only for a table that has the split.
pub fn an_allocator_table_shows_the_unused_capacity_test() {
  let html = memory_page([row("ll_alloc", 100, Known(40), "shared")])

  string.contains(html, ">unused<") |> should.be_true
  string.contains(html, ">capacity<") |> should.be_true
  // 100 B of capacity less 40 B in use.
  string.contains(html, "60 B") |> should.be_true

  let plain =
    memory_page([row("ll_alloc", 100, measure.NotApplicable, "shared")])

  string.contains(plain, ">unused<") |> should.be_false
}

// ------------------------------------------------------------ processes

pub fn a_column_of_identical_missing_words_is_said_once_test() {
  let base = fixture.processes()
  let rows =
    list.map(base.rows, fn(process) {
      model.ProcRow(..process, binary_refs: Missing(measure.NotCollected))
    })
  let html =
    element.to_string(
      processes.view(model.ProcessesModel(..base, rows:), page.Files, []),
    )

  string.contains(html, "binary refs") |> should.be_false
  string.contains(
    html,
    "Binary references: missing (not_collected) for every row.",
  )
  |> should.be_true
}

// ------------------------------------------------------------ owners

fn unknown_with(members: Int) -> model.OwnersModel {
  let page = fixture.owners()
  let template = case fixture.census() {
    [first, ..] -> first
    [] -> panic as "the fixture census is empty"
  }
  let processes =
    list.map(
      list.index_map(list.repeat(Nil, members), fn(_, i) { i + 1 }),
      fn(index) {
        model.ProcRow(
          ..template,
          key: key.make("unk" <> string.inspect(index)),
          pid_text: "<9." <> string.inspect(index) <> ".0>",
          heap_cap: Known(index * 1000),
        )
      },
    )

  model.OwnersModel(
    ..page,
    unknown: model.OwnerRow(..page.unknown, members: processes),
  )
}

// The unknown row names its five largest members while closed, so the page
// answers "who" without a click.
pub fn the_unknown_row_lists_its_largest_members_test() {
  let html =
    element.to_string(
      owners.view(unknown_with(8), state.initial(), page.Files, []),
    )

  // Members 8 to 4 are the five largest.
  string.contains(html, "&lt;9.8.0&gt;") |> should.be_true
  string.contains(html, "&lt;9.4.0&gt;") |> should.be_true
  string.contains(html, "&lt;9.3.0&gt;") |> should.be_false
}

// ------------------------------------------------------------ profile

fn profile_data() -> model.ProfileModel {
  let assert Ok(data) = fixture.profile() as "the fixture profile builds"

  data
}

// Each loss is already a sentence, so joining them must not leave ".;" or "..".
pub fn export_losses_are_joined_without_doubled_punctuation_test() {
  let data = profile_data()
  let html =
    element.to_string(profile_view.view(
      model.ProfileModel(..data, exports: [
        model.ExportReady("Collapsed", key.make("t1"), [
          "Time is lost.",
          "Units are lost.",
        ]),
      ]),
      state.initial(),
    ))

  string.contains(html, "does not carry: Time is lost; Units are lost.")
  |> should.be_true
  string.contains(html, ".;") |> should.be_false
  string.contains(html, "..") |> should.be_false
}

// One selection serves every tab: a box picked in the flame feeds Peek.
pub fn a_flame_selection_feeds_peek_test() {
  let data = profile_data()
  let assert model.HasStacks(layout:, ..) = data.stacks
  let assert Ok(box) =
    list.find(layout.boxes, fn(box) {
      case box.frame {
        flame.Function(_) -> True
        flame.Root -> False
      }
    })
  let chosen =
    state.UiState(
      ..state.initial(),
      tab: msg.PeekTab,
      selected: Some(flame_chart.box_key(box)),
    )
  let html = element.to_string(profile_view.view(data, chosen))

  string.contains(html, "Select a box in Flame") |> should.be_false
  string.contains(html, "Callers") |> should.be_true
}
