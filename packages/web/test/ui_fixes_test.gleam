//// Tests for the fixes that followed the first UI critique: what the pages
//// say about counters probes, the one profile total, the owners remainder,
//// withheld comparison colour, memory totals, timeline scales, graph text and
//// the requests a selection can make.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import lustre/dev/query
import lustre/dev/simulate
import lustre/element
import pickglass_core/analysis/pattern
import pickglass_core/analysis/transform
import pickglass_core/layout/flame
import pickglass_core/measure.{Known}
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/unit
import pickglass_web/app
import pickglass_web/census/owners as owners_builder
import pickglass_web/chart/call_graph
import pickglass_web/chart/flame as flame_chart
import pickglass_web/chart/timeline as timeline_chart
import pickglass_web/fixture
import pickglass_web/fmt
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/timeline_model
import pickglass_web/view/compare
import pickglass_web/view/overview
import pickglass_web/view/probes
import pickglass_web/view/profile as profile_view
import pickglass_web/view/ui
import support

fn fixture_profile() -> model.ProfileModel {
  let assert Ok(data) = fixture.profile() as "the fixture profile builds"
  data
}

fn layout_of(data: model.ProfileModel) -> flame.Layout {
  let assert model.HasStacks(layout:, ..) = data.stacks
    as "the fixture has stacks"
  layout
}

// ------------------------------------------------------------ probes

// A counters probe sends no trace message, so its plan must not say that
// every call emits an event; a probe that does send them still says so.
pub fn a_counters_plan_says_no_event_is_sent_and_a_tracing_plan_says_it_is_test() {
  let estimate =
    policy.Estimate(
      events_low: 4000,
      events_high: 22_000,
      bytes_high: 1_800_000,
      wall_ms: 30_000,
    )

  let counting = probes.cost_text(policy.Counting, estimate, 30_000)
  let tracing = probes.cost_text(policy.Tracing, estimate, 30_000)

  string.contains(counting, "calls counted") |> should.be_true
  string.contains(counting, "snapshot at most 1.71 MiB") |> should.be_true
  string.contains(counting, "events") |> should.be_true
  string.contains(counting, "no events sent") |> should.be_true
  string.contains(tracing, "4,000 to 22,000 events") |> should.be_true
  string.contains(tracing, "calls counted") |> should.be_false

  string.contains(
    probes.perturbation_text(policy.Counting),
    "no trace message is sent",
  )
  |> should.be_true
  string.contains(probes.perturbation_text(policy.Tracing), "collector")
  |> should.be_true
}

// The agent's counters probe sends nothing to a collector, so the history row
// has no event count and no collector reductions to report; the cells say so
// in words and keep the byte bound.
pub fn the_counters_history_row_has_words_where_a_trace_has_numbers_test() {
  let html = support.html_of(page.Probes)

  string.contains(html, "18,204") |> should.be_false
  string.contains(html, "2,100,000") |> should.be_false
  string.contains(html, "n/a") |> should.be_true
}

// ------------------------------------------------------------ profile

// The header's coverage and the chain's root chip are read from one place.
pub fn the_profile_root_chip_and_header_show_one_total_test() {
  let data = fixture_profile()
  let total = fmt.count(profile_view.root_total(data))
  let html = support.html_of(page.Profile)

  string.contains(html, total <> " of 12,000 samples over 2 targets")
  |> should.be_true
  string.contains(
    html,
    "<span class=\"crumb-total num\">" <> total <> "</span>",
  )
  |> should.be_true
}

pub fn the_root_total_is_the_first_step_total_when_there_is_a_chain_test() {
  let data = fixture_profile()

  let assert [first, ..] = data.chain as "the fixture chain has steps"
  profile_view.root_total(data) |> should.equal(first.total_before)

  // With no steps it is the profile's own total.
  let unfiltered = model.ProfileModel(..data, chain: [])
  profile_view.root_total(unfiltered)
  |> should.equal(profile.total(unfiltered.profile, unfiltered.column))
}

pub fn the_flame_does_not_draw_the_synthetic_root_test() {
  let data = fixture_profile()
  let layout = layout_of(data)
  let html = support.html_of(page.Profile)

  string.contains(html, "<title>all\n") |> should.be_false
  string.contains(html, "root-box") |> should.be_false
  // Every other box is drawn.
  support.count(html, "<title>")
  |> should.equal(list.length(layout.boxes) - 1)
}

pub fn the_search_reports_boxes_and_the_share_of_samples_test() {
  let data = fixture_profile()
  let layout = layout_of(data)
  let name_of = fn(id) { profile.name_of(data.profile, id) }

  let none = flame_chart.search_summary(layout, name_of, "")
  none.boxes |> should.equal(0)

  let keeper = flame_chart.search_summary(layout, name_of, "KEEPER")
  { keeper.boxes > 0 } |> should.be_true
  { keeper.value > 0 } |> should.be_true
  { keeper.value <= keeper.total } |> should.be_true

  // A box inside a matching box is part of its value already, so matching
  // everything counts each sample once.
  let everything = flame_chart.search_summary(layout, name_of, "@")
  { everything.value <= everything.total } |> should.be_true
  { everything.boxes >= keeper.boxes } |> should.be_true

  profile_view.search_text(keeper, unit.Count)
  |> string.contains(" boxes, ")
  |> should.be_true
  flame_chart.SearchSummary(boxes: 0, value: 0, total: 10)
  |> profile_view.search_text(unit.Count)
  |> should.equal("No box matches.")
}

// "Focus here" is a request with the selection's key; the step it stands for
// has a pattern that matches that function's name and no other.
pub fn focus_here_appends_a_step_that_matches_exactly_the_selected_function_test() {
  let data = fixture_profile()
  let layout = layout_of(data)

  let assert Ok(box) =
    list.find(layout.boxes, fn(box) { box.frame != flame.Root })
    as "a function box"
  let assert flame.Function(id:) = box.frame as "a function"

  let assert Ok(step) =
    profile_view.step_at(data, msg.FocusFilter, flame_chart.box_key(box))
    as "a step"
  let assert transform.Focus(pattern: text) = step as "a focus step"
  let assert Ok(compiled) = pattern.compile(text) as "the pattern compiles"

  pattern.matches(compiled, profile.name_of(data.profile, id))
  |> should.be_true

  // No other function in the table matches it.
  profile.functions(data.profile)
  |> list.filter(fn(function) { function.id != id })
  |> list.each(fn(function) {
    pattern.matches(compiled, profile.function_name(function))
    |> should.be_false
  })

  let assert Ok(from) =
    profile_view.step_at(data, msg.ShowFromFilter, flame_chart.box_key(box))
    as "a show-from step"
  from |> should.equal(transform.ShowFrom(pattern: text))
}

pub fn the_root_and_unknown_keys_make_no_step_test() {
  let data = fixture_profile()
  let layout = layout_of(data)

  let assert Ok(root) =
    list.find(layout.boxes, fn(box) { box.frame == flame.Root })
    as "the root"

  profile_view.step_at(data, msg.FocusFilter, flame_chart.box_key(root))
  |> should.equal(Error(Nil))
  profile_view.step_at(data, msg.FocusFilter, key.make("b9.9.9"))
  |> should.equal(Error(Nil))
}

// A click on "Focus here" reaches the viewer as a request that carries the
// key; a key the page never drew is refused.
pub fn the_page_forwards_a_focus_request_and_refuses_a_forged_key_test() {
  let data = fixture_profile()
  let layout = layout_of(data)

  let assert Ok(box) =
    list.find(layout.boxes, fn(box) { box.frame != flame.Root })
    as "a function box"
  let id = flame_chart.box_key(box)

  let selected =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Ui(msg.SelectBox(id)))
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Focus here"),
      )),
    )

  simulate.model(selected).ui.last_request
  |> should.equal(Some(msg.AddFilterAt(msg.FocusFilter, id)))

  let forged =
    support.simulation(on: page.Profile)
    |> simulate.message(
      msg.Ask(msg.AddFilterAt(msg.FocusFilter, key.make("b9.9.9"))),
    )

  simulate.model(forged).ui.last_request |> should.equal(None)
}

pub fn the_graph_has_a_persistent_selection_line_too_test() {
  let model =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Ui(msg.OpenTab(msg.GraphTab)))
    |> simulate.message(msg.Ui(msg.SelectNode(call_graph.node_key(0))))
    |> simulate.model

  let html = element.to_string(app.view(model))

  // Either the node is in the drawn graph and the line shows its figures, or
  // the page refused the key and says to click a node.
  case string.contains(html, "flat ") {
    True -> string.contains(html, "Focus here") |> should.be_true
    False ->
      string.contains(html, "Click a node to select it.") |> should.be_true
  }
}

// ------------------------------------------------------------ graph

pub fn no_node_label_is_smaller_than_eleven_points_test() {
  let html = support.html_of(page.Profile)

  let graph_html =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Ui(msg.OpenTab(msg.GraphTab)))
    |> simulate.model
    |> app.view
    |> element.to_string

  let sizes =
    string.split(graph_html, "font-size=\"")
    |> list.drop(1)
    |> list.filter_map(fn(part) {
      part |> string.split("\"") |> list.first |> result.try(int.parse)
    })

  { sizes != [] } |> should.be_true
  list.each(sizes, fn(size) { { size >= 11 } |> should.be_true })
  string.contains(html, "font-size=\"") |> should.be_false
}

pub fn heavy_edges_carry_their_weight_and_light_ones_do_not_test() {
  call_graph.labelled(weight: 50, of: 1000) |> should.be_true
  call_graph.labelled(weight: 20, of: 1000) |> should.be_true
  call_graph.labelled(weight: 19, of: 1000) |> should.be_false
  call_graph.labelled(weight: 5, of: 0) |> should.be_false

  let graph_html =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Ui(msg.OpenTab(msg.GraphTab)))
    |> simulate.model
    |> app.view
    |> element.to_string

  string.contains(graph_html, "edge-label") |> should.be_true
  string.contains(graph_html, "node-detail") |> should.be_true
}

// ------------------------------------------------------------ owners

pub fn the_owners_page_has_a_remainder_row_for_what_the_rows_leave_out_test() {
  let html = support.html_of(page.Owners)

  string.contains(html, "other, not in the listed owners") |> should.be_true
  string.contains(html, "3,398") |> should.be_true
  string.contains(html, "14 of 3,412 processes") |> should.be_true
  string.contains(html, "Labels read on 11 of the 14 processes listed")
  |> should.be_true
}

pub fn a_remainder_of_zero_draws_no_row_test() {
  let page_model = fixture.owners()

  owners_builder.with_remainder(page_model, procs: 0, heap_cap: Known(0)).remainder
  |> should.equal(model.NoRemainder)

  owners_builder.with_remainder(
    page_model,
    procs: 5,
    heap_cap: measure.Missing(measure.BudgetExhausted),
  ).remainder
  |> should.equal(model.Remainder(
    procs: Known(5),
    heap_cap: measure.Missing(measure.BudgetExhausted),
  ))
}

// The fixture's group change is the sum of its roles', and the footer says
// what the change means when they do not add.
pub fn the_group_delta_equals_the_sum_of_its_role_deltas_in_the_fixture_test() {
  let rows = fixture.owners().rows

  let assert Ok(group) =
    list.find(rows, fn(row) { row.label == "session:s-12" })
    as "the s-12 group"

  let roles =
    rows
    |> list.filter(fn(row) {
      row.kind == model.RoleGroup
      && string.contains(row.key |> key.to_string, "session:s-12")
    })

  let sum =
    list.fold(roles, 0, fn(total, row) {
      case row.delta {
        Known(value:) -> total + value
        _ -> total
      }
    })

  group.delta |> should.equal(Known(sum))
}

// A role row is not styled as the banner's role chip, whose capitals would
// spell an identifier in capitals.
pub fn a_role_row_does_not_share_the_banner_chip_class_test() {
  let html =
    support.simulation(on: page.Owners)
    |> simulate.message(msg.Ui(msg.ToggleRow(key.make("owner:session:s-12"))))
    |> simulate.model
    |> app.view
    |> element.to_string

  string.contains(html, "class=\"group role\"") |> should.be_false
  string.contains(html, "group role-row") |> should.be_true
}

// ------------------------------------------------------------ compare

pub fn a_blocking_mismatch_gives_no_direction_colour_anywhere_test() {
  let html = support.html_of(page.Compare)

  string.contains(html, "delta-up") |> should.be_false
  string.contains(html, "delta-down") |> should.be_false
  string.contains(html, "diff-up") |> should.be_false
  string.contains(html, "diff-down") |> should.be_false
  string.contains(html, "withheld: ") |> should.be_true
  string.contains(html, "No figure gets a direction: the workload differs.")
  |> should.be_true
  string.contains(html, "workload blocks a verdict") |> should.be_true
  string.contains(html, "A direction of change is allowed for")
  |> should.be_false
}

pub fn comparable_captures_keep_their_direction_colour_test() {
  let assert Ok(data) = fixture.compare() as "the compare fixture"
  let same = model.CompareModel(..data, candidate: data.baseline)

  let html = element.to_string(compare.view(same))

  string.contains(html, "delta-down") |> should.be_true
  string.contains(html, "diff-down") |> should.be_true
  string.contains(html, "withheld: ") |> should.be_false
}

// ------------------------------------------------------------ memory

pub fn memory_totals_are_scaled_not_raw_integers_test() {
  let html = support.html_of(page.Memory)

  string.contains(html, "1266679808") |> should.be_false
  string.contains(html, "bytes") |> should.be_false
  string.contains(html, "Sum of additive rows: 1.17 GiB") |> should.be_true
}

// The allocators panel lists what the overview calls allocator carriers, so
// the two pages give one figure.
pub fn the_allocator_rows_add_up_to_the_overview_carriers_test() {
  let memory = fixture.memory()
  let rows = memory.allocators.body

  let sum =
    list.fold(rows, 0, fn(total, row) {
      case row.value, row.additivity {
        Known(value:), measure.Additive -> total + value
        _, _ -> total
      }
    })

  let overview = fixture.overview()
  let assert Ok(carriers) =
    list.find(overview.layers.body, fn(row) {
      row.label == "allocator carriers"
    })
    as "the carriers layer"

  carriers.value |> should.equal(Known(sum))
}

pub fn fmt_total_scales_and_marks_a_lower_bound_test() {
  fmt.total(
    measure.Total(
      value: 3 * 1024 * 1024,
      known: 3,
      missing: 0,
      not_applicable: 0,
    ),
    unit.Bytes,
  )
  |> should.equal("3.00 MiB")

  fmt.total(
    measure.Total(value: 2048, known: 2, missing: 1, not_applicable: 0),
    unit.Bytes,
  )
  |> should.equal("at least 2.00 KiB (2 of 3 rows known)")
}

// ------------------------------------------------------------ timeline

pub fn each_counter_track_prints_its_scale_at_the_right_edge_test() {
  let html = support.html_of(page.Timeline)

  // A ratio is drawn as bars from zero and prints its peak. A level is
  // drawn as a line between its smallest and largest reading and prints the
  // range, because bars from zero hide a small rise in a large level.
  support.count(html, "peak-label") |> should.equal(3)
  support.count(html, "step-line") |> should.equal(2)
  string.contains(html, "peak 7.8%") |> should.be_true
  string.contains(html, ">0-3<") |> should.be_true
  string.contains(html, "-181 MiB<") |> should.be_true
}

pub fn a_level_track_prints_its_range_in_one_unit_test() {
  let steps = fn(values) {
    list.map(values, fn(value) {
      timeline_model.Step(at_ms: 0, width_ms: 10, value: measure.Known(value))
    })
  }
  let mib = 1_048_576

  timeline_chart.range_text(steps([57 * mib, 58 * mib]), unit.Bytes)
  |> should.equal("57.0-58.0 MiB")
  timeline_chart.range_text(steps([57 * mib, 57 * mib]), unit.Bytes)
  |> should.equal("all 57.0 MiB")
  timeline_chart.range_text([], unit.Bytes) |> should.equal("no reading")
}

pub fn a_ratio_below_the_first_decimal_is_not_written_as_zero_test() {
  fmt.ratio(3, 10_000) |> should.equal("<0.1%")
  fmt.ratio(0, 10_000) |> should.equal("0.0%")
  fmt.ratio(30, 10_000) |> should.equal("0.3%")
}

pub fn a_track_with_no_reading_says_so_instead_of_a_peak_test() {
  let steps = [
    timeline_model.Step(
      at_ms: 0,
      width_ms: 10,
      value: measure.Missing(measure.BudgetExhausted),
    ),
  ]

  timeline_chart.peak_text(steps, unit.Count) |> should.equal("no reading")
  timeline_chart.peak_of(steps) |> should.equal(None)
}

pub fn the_axis_uses_one_unit_for_the_whole_window_test() {
  timeline_chart.axis_text(0, window: 60_000) |> should.equal("0 s")
  timeline_chart.axis_text(12_000, window: 60_000) |> should.equal("12 s")
  timeline_chart.axis_text(2500, window: 10_000) |> should.equal("2.5 s")
  timeline_chart.axis_text(400, window: 800) |> should.equal("400 ms")
  timeline_chart.axis_text(0, window: 800) |> should.equal("0 ms")

  let html = support.html_of(page.Timeline)
  string.contains(html, "+0 ms") |> should.be_false
  string.contains(html, "+0 s") |> should.be_true
  string.contains(html, "+12 s") |> should.be_true
}

pub fn a_selected_reading_is_written_on_the_page_test() {
  let chosen = timeline_chart.item_key(0, 4)

  let html =
    support.simulation(on: page.Timeline)
    |> simulate.message(msg.Ui(msg.SelectReading(chosen)))
    |> simulate.model
    |> app.view
    |> element.to_string

  string.contains(html, "scheduler util · +8 s · 7.8%") |> should.be_true

  // A key that names no reading is refused and selects nothing.
  let refused =
    support.simulation(on: page.Timeline)
    |> simulate.message(msg.Ui(msg.SelectReading(key.make("t9.9"))))
    |> simulate.model

  refused.ui.selected |> should.equal(None)
}

// ------------------------------------------------------------ overview

pub fn the_overview_leads_with_the_layers_not_the_count_tiles_test() {
  let html = support.html_of(page.Overview)

  let assert Ok(#(before_layers, _)) = string.split_once(html, "Memory layers")
    as "layers panel"
  string.contains(before_layers, "tile-row") |> should.be_false
}

pub fn the_owners_that_moved_most_are_ranked_by_size_of_change_test() {
  let movers = [
    model.OwnerMover(label: "a", delta: Known(5)),
    model.OwnerMover(label: "b", delta: Known(-90)),
    model.OwnerMover(label: "c", delta: measure.Missing(measure.ProcessExited)),
    model.OwnerMover(label: "d", delta: Known(0)),
    model.OwnerMover(label: "e", delta: Known(40)),
  ]

  overview.top_movers(movers)
  |> list.map(fn(mover) { mover.label })
  |> should.equal(["b", "e", "a"])

  let html = support.html_of(page.Overview)
  string.contains(html, "Largest change by owner") |> should.be_true
}

pub fn a_cadence_far_behind_the_request_is_marked_cut_test() {
  ui.cadence_missed(measure.EveryMs(1000), Some(1500)) |> should.be_true
  ui.cadence_missed(measure.EveryMs(1000), Some(1499)) |> should.be_false
  ui.cadence_missed(measure.EveryMs(1000), None) |> should.be_false
  ui.cadence_missed(measure.OneShot, Some(9000)) |> should.be_false
}

// ------------------------------------------------------------ detail

pub fn the_detail_page_offers_a_probe_and_a_way_back_to_the_owner_test() {
  let html = support.html_of(page.ProcessDetail)

  string.contains(html, "Plan probe…") |> should.be_true
  string.contains(html, "href=\"owners.html\"") |> should.be_true
  string.contains(html, "initial call erlang:apply/2") |> should.be_true
  string.contains(html, "birth seq initial call") |> should.be_false
  string.contains(html, "incarnation") |> should.be_true
  string.contains(html, "pass time / cadence") |> should.be_true

  let sim =
    support.simulation(on: page.ProcessDetail)
    |> simulate.click(
      on: query.element(matching: query.and(
        query.tag("button"),
        query.text("Plan probe…"),
      )),
    )

  simulate.model(sim).ui.last_request
  |> should.equal(Some(msg.PlanProbeFor(fixture.keeper_key())))

  let forged =
    support.simulation(on: page.ProcessDetail)
    |> simulate.message(msg.Ask(msg.PlanProbeFor(key.make("proc.99999"))))

  simulate.model(forged).ui.last_request |> should.equal(None)
}

// ------------------------------------------------------------ copy

pub fn the_source_tab_names_its_column_precision_test() {
  let html =
    support.simulation(on: page.Profile)
    |> simulate.message(msg.Ui(msg.OpenTab(msg.SourceTab)))
    |> simulate.model
    |> app.view
    |> element.to_string

  string.contains(html, "<th>precision</th>") |> should.be_true
  string.contains(html, "<th>line</th>") |> should.be_false
}
