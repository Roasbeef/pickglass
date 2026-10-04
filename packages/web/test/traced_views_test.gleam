//// What the pages show of a profile's running and waiting samples, a call
//// tree and a recording: the sentences, the controls, what each control
//// sends, and the charts' geometry.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/dev/query
import lustre/dev/simulate
import lustre/effect
import lustre/element
import pickglass_core/measure.{Known}
import pickglass_core/policy
import pickglass_core/profile/activity
import pickglass_web/app
import pickglass_web/chart/activity as activity_chart
import pickglass_web/fixture
import pickglass_web/fixture/traced
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/page
import pickglass_web/timeline_model
import pickglass_web/view/flow
import pickglass_web/view/probes
import pickglass_web/view/process_detail
import pickglass_web/view/profile as profile_view
import support

fn button(label: String) -> query.Selector {
  query.and(query.tag("button"), query.text(label))
}

// ------------------------------------------------------------- the profile

fn with_activity(view: model.ActivityView) -> app.Model {
  let model = app.init(fixture.start(page.Profile, page.Files))
  let assert app.Ready(data) = model.profile

  app.Model(
    ..model,
    profile: app.Ready(model.ProfileModel(..data, activity: view)),
  )
}

fn html(model: app.Model) -> String {
  element.to_string(app.view(model))
}

fn statuses(
  inclusion: activity.Inclusion,
  split: activity.Split,
) -> model.ActivityView {
  model.Statuses(inclusion:, split:, processes: Some(16))
}

pub fn the_split_is_stated_beside_the_choice_of_samples_test() {
  let page_html =
    html(
      with_activity(statuses(
        activity.OnSchedulerOnly,
        activity.Split(412, 2596, 0),
      )),
    )

  assert string.contains(
    page_html,
    "3,008 samples: 412 running/runnable, 2,596 waiting. Showing running and runnable samples only.",
  )
  assert string.contains(page_html, "Include waiting samples (2,596)")
  assert string.contains(page_html, "running/runnable")
  assert !string.contains(page_html, "were waiting for messages")
}

pub fn including_waiting_says_what_is_drawn_and_offers_the_way_back_test() {
  let page_html =
    html(
      with_activity(statuses(
        activity.IncludeWaiting,
        activity.Split(412, 2596, 0),
      )),
    )

  assert string.contains(
    page_html,
    "Showing every sample, waiting ones included",
  )
  assert string.contains(page_html, "Show running and runnable only")
}

// With nothing running there is nothing to draw, and the page says so in a
// sentence and offers the waiting samples instead of an empty chart.
pub fn a_profile_of_waiting_processes_says_so_and_draws_no_chart_test() {
  let page_html =
    html(
      with_activity(statuses(
        activity.OnSchedulerOnly,
        activity.Split(0, 3008, 0),
      )),
    )

  assert string.contains(
    page_html,
    "All 16 processes were waiting for messages for the whole window.",
  )
  assert string.contains(page_html, "Include waiting samples (3,008)")
  assert !string.contains(page_html, "Filter chain")
  assert !string.contains(page_html, "tabbed")
  assert !string.contains(page_html, "flame")
}

pub fn one_waiting_process_is_named_in_the_singular_test() {
  assert profile_view.idle_text(Some(1))
    == "The process was waiting for a message for the whole window."
  assert profile_view.idle_text(None)
    == "Every process was waiting for a message for the whole window."
}

pub fn a_profile_with_no_statuses_has_no_split_to_state_test() {
  let page_html = support.html_of(page.Profile)

  assert !string.contains(page_html, "activity-split")
  assert !string.contains(page_html, "running/runnable")
}

pub fn the_choice_of_samples_is_a_request_that_checks_nothing_but_its_type_test() {
  let sim =
    simulate.application(
      init: fn(_) {
        #(
          with_activity(statuses(
            activity.OnSchedulerOnly,
            activity.Split(412, 2596, 0),
          )),
          effect.none(),
        )
      },
      update: fn(model, message) {
        app.update(fn(_) { effect.none() }, model, message)
      },
      view: app.view,
    )
    |> simulate.start(Nil)
    |> simulate.click(
      on: query.element(matching: button("Include waiting samples (2,596)")),
    )

  assert simulate.model(sim).ui.last_request
    == Some(msg.ChooseSamples(activity.IncludeWaiting))
}

// ----------------------------------------------------------------- timeline

pub fn the_timeline_page_draws_a_recording_and_its_totals_test() {
  let model =
    app.Model(
      ..app.init(fixture.start(page.Timeline, page.Files)),
      timeline: app.Ready(fixture.timeline_traced()),
    )
  let page_html = html(model)

  assert string.contains(page_html, "Scheduling and collections · probe p-43")

  // One row of totals per traced process, with the figures the probe counted.
  assert string.contains(page_html, "trace-totals")
  assert string.contains(page_html, "&lt;0.4411.0&gt; session s-12 / keeper")
  assert string.contains(page_html, "time on scheduler")

  // The threshold events are a table with no time column, and the page says
  // why.
  assert string.contains(page_html, "long_gc")
  assert string.contains(page_html, "long_schedule")
  assert string.contains(page_html, "lists:sort/1")
  assert string.contains(page_html, "the VM reports no time for them")

  // Runs and both kinds of collection are drawn.
  assert string.contains(page_html, "act act-run")
  assert string.contains(page_html, "act act-gc-minor")
  assert string.contains(page_html, "act act-gc-major")
  assert string.contains(page_html, "act-window-band")

  // And the call tree's slices below, nested.
  assert string.contains(page_html, "Calls · probe p-44")
  assert string.contains(page_html, "call call-d3")
  assert string.contains(page_html, "export-trace")
}

pub fn a_page_with_no_tracing_probe_draws_none_test() {
  let page_html = support.html_of(page.Timeline)

  assert !string.contains(page_html, "Scheduling and collections")
  assert !string.contains(page_html, "Calls · probe")
}

// A probe that stopped early shades only what it watched, and says why it
// stopped.
pub fn a_cut_short_recording_states_its_stop_reason_and_losses_test() {
  let model =
    app.Model(
      ..app.init(fixture.start(page.Timeline, page.Files)),
      timeline: app.Ready(fixture.timeline_overrun()),
    )
  let page_html = html(model)

  assert string.contains(page_html, "truncated: collector_overrun")
  assert string.contains(page_html, "the collector fell behind")
  assert string.contains(page_html, "61,204 events arrived after the stop")
  assert string.contains(page_html, "the rest of the axis was not watched")
}

pub fn the_export_button_sends_the_request_for_its_probe_test() {
  let sim =
    simulate.application(
      init: fn(_) {
        #(
          app.Model(
            ..app.init(fixture.start(page.Timeline, page.Files)),
            timeline: app.Ready(fixture.timeline_traced()),
          ),
          effect.none(),
        )
      },
      update: fn(model, message) {
        app.update(fn(_) { effect.none() }, model, message)
      },
      view: app.view,
    )
    |> simulate.start(Nil)
    |> simulate.click(
      on: query.element(matching: query.attribute(
        "data-test-id",
        "export-trace",
      )),
    )

  assert simulate.model(sim).ui.last_request
    == Some(msg.ExportTrace(msg.EventsTrace))
}

// ------------------------------------------------------------ chart geometry

pub fn a_slice_is_drawn_at_its_position_and_never_thinner_than_a_pixel_test() {
  // A one second axis across a thousand pixels: a millisecond is a pixel.
  assert activity_chart.x_of(0, 1_000_000_000) == 170
  assert activity_chart.x_of(500_000_000, 1_000_000_000) == 670
  assert activity_chart.width_of(250_000_000, 1_000_000_000) == 250

  // A run of microseconds is drawn one pixel wide so that it can be seen.
  assert activity_chart.width_of(5000, 1_000_000_000) == 1
  assert activity_chart.width_of(0, 1_000_000_000) == 1

  // A negative start and an empty axis do not leave the plot or divide by
  // zero.
  assert activity_chart.x_of(-5, 1_000_000_000) == 170
  assert activity_chart.x_of(10, 0) == 170 + 10 * 1000
}

pub fn the_axis_covers_the_window_the_observed_time_and_the_last_slice_test() {
  assert activity_chart.axis_ns(5_000_000_000, 1_200_000_000, 1_000_000_000)
    == 5_000_000_000
  assert activity_chart.axis_ns(1000, 9000, 2000) == 9000
  assert activity_chart.axis_ns(1000, 2000, 7000) == 7000
  assert activity_chart.axis_ns(0, 0, 0) == 1
}

pub fn the_last_end_is_the_latest_slice_end_in_any_track_test() {
  let events = traced.events()

  assert activity_chart.last_end(events.tracks) > 0
  assert activity_chart.last_end([]) == 0

  let calls = traced.calls()

  assert activity_chart.last_call_end(calls.tracks) > 0
  assert activity_chart.hidden_calls(calls.tracks) == 0
}

pub fn calls_nested_deeper_than_the_rows_drawn_are_counted_not_drawn_test() {
  let deep =
    timeline_model.CallTrack(
      label: "<0.1.0>",
      calls: list.index_map(list.repeat(Nil, 12), fn(_, depth) {
        timeline_model.CallBox("m:f/0", depth, 10, depth)
      }),
    )

  assert activity_chart.hidden_calls([deep])
    == 12 - activity_chart.max_call_rows
}

pub fn the_drawing_has_one_rect_per_slice_test() {
  let timeline = traced.events()
  let slices =
    list.fold(timeline.tracks, 0, fn(total, track) {
      total + list.length(track.slices)
    })
  let svg = element.to_string(activity_chart.events(timeline))

  // Each slice, and the one band that shades the observed window.
  assert support.count(svg, "<rect") == slices + 1
}

// ----------------------------------------------------------------- the flow

fn flow_html(data: model.FlowModel, current: page.Page) -> String {
  element.to_string(flow.view(data, page.Files, current))
}

fn card(adjust: model.Adjust) -> model.PlanCard {
  let assert Some(found) = fixture.flow().pending

  model.PlanCard(..found, adjust:)
}

pub fn a_stack_plan_of_few_processes_offers_a_call_trace_instead_test() {
  let data =
    model.FlowModel(
      ..fixture.flow(),
      pending: Some(card(model.AdjustStacks(10_000, 100, 4))),
    )
  let shown = flow_html(data, page.Overview)

  assert string.contains(shown, "Trace calls instead")
  assert string.contains(shown, "Modules to trace")
}

pub fn a_stack_plan_of_many_processes_does_not_offer_it_test() {
  let data =
    model.FlowModel(
      ..fixture.flow(),
      pending: Some(card(model.AdjustStacks(10_000, 100, 5))),
    )

  assert !string.contains(flow_html(data, page.Overview), "Trace calls instead")
}

pub fn a_call_plan_offers_the_way_back_to_stacks_test() {
  let data =
    model.FlowModel(
      ..fixture.flow(),
      pending: Some(card(model.AdjustCalls(5000, 2))),
    )
  let shown = flow_html(data, page.Overview)

  assert string.contains(shown, "Sample stacks instead")
  assert !string.contains(shown, "Trace calls instead")
}

pub fn the_flow_names_what_is_running_and_where_the_result_is_test() {
  let running = fn(kind) {
    model.FlowModel(..fixture.flow(), pending: None, running: [
      model.ActiveProbe(
        key: key.make("probe.1"),
        kind:,
        remaining_ms: Known(4000),
      ),
    ])
  }

  assert string.contains(
    flow_html(running(policy.CallTree), page.Overview),
    "Tracing calls",
  )
  assert string.contains(
    flow_html(running(policy.SchedulingGc), page.Overview),
    "Recording scheduling and collections",
  )
  assert string.contains(
    flow_html(running(policy.Sampling), page.Overview),
    "Sampling stacks",
  )

  let ready =
    model.FlowModel(
      ..fixture.flow(),
      pending: None,
      running: [],
      ready: Some(model.ReadyProfile(
        probe: "p-9",
        age_ms: 3000,
        summary: "2 processes, 40 runs",
        opens: model.OpensTimeline,
      )),
    )
  let shown = flow_html(ready, page.Overview)

  assert string.contains(
    shown,
    "Recording ready: probe p-9, 2 processes, 40 runs",
  )
  assert string.contains(shown, "Open timeline")
  assert string.contains(shown, "timeline.html")
}

// ----------------------------------------------------------------- the forms

fn probes_model() -> app.Model {
  app.init(fixture.start(page.Probes, page.Files))
}

fn update(model: app.Model, message: msg.Msg) -> app.Model {
  let #(next, _) = app.update(fn(_) { effect.none() }, model, message)

  next
}

fn pick_kind(kind: policy.ProbeKind) -> app.Model {
  update(probes_model(), msg.Ui(msg.DraftKind(kind)))
}

// The durations on offer are the ones the agent runs for the kind.
pub fn the_form_offers_the_durations_each_kind_runs_for_test() {
  assert msg.durations_for(policy.CallTree) == [msg.Seconds5, msg.Seconds10]
  assert msg.durations_for(policy.SchedulingGc)
    == [msg.Seconds10, msg.Seconds30, msg.Seconds60]
  assert msg.durations_for(policy.Sampling)
    == [msg.Seconds10, msg.Seconds30, msg.Seconds60]
  assert msg.durations_for(policy.Counters)
    == [msg.Seconds10, msg.Seconds30, msg.Seconds60, msg.Seconds300]

  let call_tree = html(pick_kind(policy.CallTree))

  assert string.contains(call_tree, "value=\"5s\"")
  assert !string.contains(call_tree, "value=\"60s\"")
  assert !string.contains(call_tree, "value=\"300s\"")
}

// A duration the new kind cannot run is replaced by its shortest, so the
// form never holds a plan the agent would refuse.
pub fn changing_the_kind_replaces_a_duration_the_kind_cannot_run_test() {
  let model = update(probes_model(), msg.Ui(msg.DraftDuration(msg.Seconds300)))

  assert model.ui.plan.duration == msg.Seconds300
  assert update(model, msg.Ui(msg.DraftKind(policy.CallTree))).ui.plan.duration
    == msg.Seconds5
  assert update(model, msg.Ui(msg.DraftKind(policy.Sampling))).ui.plan.duration
    == msg.Seconds10

  // A duration the kind can run is kept.
  let kept =
    update(probes_model(), msg.Ui(msg.DraftDuration(msg.Seconds60)))
    |> update(msg.Ui(msg.DraftKind(policy.SchedulingGc)))

  assert kept.ui.plan.duration == msg.Seconds60
}

// Only a kind that traces named modules shows the field for them; for the
// others it is in the form but hidden.
pub fn only_counters_and_call_trees_show_the_modules_field_test() {
  let shown = fn(kind) {
    !string.contains(html(pick_kind(kind)), "field field-off")
  }

  assert shown(policy.Counters)
  assert shown(policy.CallTree)
  assert !shown(policy.Sampling)
  assert !shown(policy.SchedulingGc)
}

fn with_target(model: app.Model) -> app.Model {
  let assert app.Ready(data) = model.probes
  let assert [#(target, _), ..] = data.targets

  update(model, msg.Ui(msg.DraftTarget(target)))
}

// A recording or a stack probe plans with no modules typed; a call tree
// without any is refused in words, as a counters probe is.
pub fn a_recording_needs_no_modules_and_a_call_tree_does_test() {
  let recording =
    pick_kind(policy.SchedulingGc)
    |> with_target
    |> update(msg.Ui(msg.SubmitDraft("")))

  let assert Some(msg.PlanProbe(draft)) = recording.ui.last_request

  assert draft.kind == policy.SchedulingGc
  assert draft.modules == []

  let calls =
    pick_kind(policy.CallTree)
    |> with_target
    |> update(msg.Ui(msg.SubmitDraft("")))

  assert calls.ui.last_request == None
  assert calls.ui.notice == Some("Enter at least one module pattern.")

  let named =
    pick_kind(policy.CallTree)
    |> with_target
    |> update(msg.Ui(msg.SubmitDraft("lists gleam@list")))
  let assert Some(msg.PlanProbe(sent)) = named.ui.last_request

  assert sent.modules == ["lists", "gleam@list"]
  assert sent.duration == msg.Seconds5
}

// The "trace calls instead" control sends the modules the operator typed, and
// the page refuses text outside the pattern alphabet before it sends anything.
pub fn trace_instead_checks_the_modules_before_it_asks_test() {
  let model = app.init(fixture.start(page.Overview, page.Files))
  let assert app.Ready(flow_data) = model.flow
  let assert Some(plan) = flow_data.pending

  let empty = update(model, msg.Ui(msg.SubmitTraceInstead(plan.key, "")))

  assert empty.ui.last_request == None
  assert empty.ui.notice == Some("Enter at least one module pattern.")

  let bad = update(model, msg.Ui(msg.SubmitTraceInstead(plan.key, "../etc")))

  assert bad.ui.last_request == None

  let good = update(model, msg.Ui(msg.SubmitTraceInstead(plan.key, "lists")))

  assert good.ui.last_request
    == Some(msg.TraceCallsInstead(plan.key, ["lists"]))
}

// The browser can only name a plan the page shows, a process it lists and an
// owner it has.
pub fn the_new_requests_check_their_keys_against_the_page_test() {
  let overview = app.init(fixture.start(page.Overview, page.Files))
  let forged = key.make("plan.forged")

  assert update(overview, msg.Ask(msg.TraceCallsInstead(forged, ["lists"]))).ui.last_request
    == None
  assert update(overview, msg.Ask(msg.SampleStacksInstead(forged))).ui.last_request
    == None
  assert update(
      overview,
      msg.Ask(msg.TraceProcess(key.make("pid.forged"), ["lists"])),
    ).ui.last_request
    == None
  assert update(overview, msg.Ask(msg.RecordProcess(key.make("pid.forged")))).ui.last_request
    == None
  assert update(overview, msg.Ask(msg.RecordOwner(key.make("owner.forged")))).ui.last_request
    == None
}

// -------------------------------------------------------------- the detail

pub fn the_detail_page_offers_a_recording_and_a_call_trace_with_the_capability_test() {
  let data = fixture.process_detail()
  let drawn = fn(grants) {
    element.to_string(process_detail.view(data, grants, page.Files))
  }

  let with = drawn(policy.all_capabilities)

  assert string.contains(with, "Record scheduling…")
  assert string.contains(with, "Trace calls…")
  assert string.contains(with, "Modules to trace")
  assert string.contains(with, "name=\"modules\"")

  let without = drawn([policy.Observe])

  assert !string.contains(without, "Record scheduling…")
  assert !string.contains(without, "Trace calls…")
}

pub fn the_detail_buttons_send_their_requests_test() {
  let sim =
    support.simulation(on: page.ProcessDetail)
    |> simulate.click(on: query.element(matching: button("Record scheduling…")))

  assert simulate.model(sim).ui.last_request
    == Some(msg.RecordProcess(fixture.keeper_key()))

  // The call trace goes through the form's own check.
  let traced =
    simulate.model(sim)
    |> update(
      msg.Ui(msg.SubmitTraceProcess(fixture.keeper_key(), "loom@runtime@keeper")),
    )

  assert traced.ui.last_request
    == Some(msg.TraceProcess(fixture.keeper_key(), ["loom@runtime@keeper"]))
}

pub fn an_owner_row_offers_a_recording_beside_its_profile_test() {
  let owners = support.html_of(page.Owners)

  assert support.count(owners, "btn-record")
    == support.count(owners, "btn-profile")
}

// ------------------------------------------------------------- plan dialog

pub fn a_call_tree_plan_states_its_window_and_its_budget_test() {
  let assert Some(plan) = fixture.plan_card_of(policy.CallTree, ["lists"], 5000)
  let shown = element.to_string(probes.plan_dialog(plan))

  assert string.contains(shown, "Plan: Trace call tree")
  assert string.contains(shown, "Window")
  assert string.contains(shown, "5.00 s")
  assert string.contains(shown, "stops after 100,000 call and return events")
  assert string.contains(shown, "when the collector falls behind")
  assert string.contains(shown, "untraced callees are cheap")
  assert string.contains(shown, "moderate: every traced event")
}

pub fn a_recording_plan_states_the_thresholds_and_names_no_modules_test() {
  let assert Some(plan) = fixture.plan_card_of(policy.SchedulingGc, [], 10_000)
  let shown = element.to_string(probes.plan_dialog(plan))

  assert string.contains(shown, "Plan: Scheduling and GC events")
  assert string.contains(shown, "Node-wide thresholds")
  assert string.contains(
    shown,
    "collections of 50 ms or more and timeslices of 100 ms or more",
  )
  assert string.contains(shown, "OTP 28")
  assert string.contains(shown, "up to 2,000 slices")
  assert !string.contains(shown, "modules ")
}
