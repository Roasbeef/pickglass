//// What the pages are given for a sampled profile's two kinds of sample, a
//// call tree and a recording: the model each page draws, the choice that
//// changes it, and the files made from it.

import fixture
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/internal/ffi_dist
import pickglass/probe_book.{type ProbeRecord}
import pickglass/seam
import pickglass/service
import pickglass/web_mount
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/timeline_model
import pickglass_web/view/profile as profile_view

// ------------------------------------------------------------ test data

fn stacks(running: Int, waiting: Int) -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 11,
    state: wire.ProbeFinished,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: 100,
      achieved_millihz: 97_000,
      rounds: 97,
      samples: running + waiting,
      elapsed_ms: 1000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 2,
      truncated_samples: 0,
    ),
    frames: [
      wire.StackFrame("loom@runtime", "leaf", 1, wire.NoLocation),
      wire.StackFrame("loom@runtime", "root", 1, wire.NoLocation),
    ],
    stacks: list.flatten([
      case running {
        0 -> []
        n -> [wire.SampledStack(n, "running", [0, 1])]
      },
      case waiting {
        0 -> []
        n -> [wire.SampledStack(n, "waiting", [1])]
      },
    ]),
  )
}

fn sampled(running: Int, waiting: Int, processes: Int) -> ProbeRecord {
  probe_book.started(11, policy.Sampling, [], 1000, 10_000, processes)
  |> probe_book.finish_stacks(
    stacks(running, waiting),
    ffi_dist.system_time_ms(),
  )
}

fn calls_snapshot() -> wire.CalltraceSnapshot {
  wire.CalltraceSnapshot(
    probe_id: 21,
    state: wire.ProbeFinished,
    stop: wire.TraceBudget,
    meter: wire.CalltraceMeter(
      trace: wire.TraceMeter(
        elapsed_ms: 900,
        events: 100_000,
        max_events: 100_000,
        dropped_events: 40,
        in_flight_at_stop: 38,
        peak_queue: 70,
        queue_limit: 50_000,
        targets_gone: 0,
      ),
      forced_closes: 0,
      distinct_paths: 2,
      dropped_calls: 0,
      elided_calls: 0,
      strays: 0,
      depth_limit: 64,
    ),
    frames: [
      wire.StackFrame("lists", "sort", 1, wire.NoLocation),
      wire.StackFrame("m", "work", 0, wire.NoLocation),
    ],
    paths: [
      wire.CallPath(6, 4_000_000, 3_000_000, [0, 1]),
      wire.CallPath(2, 5_000_000, 1_000_000, [1]),
    ],
    processes: ["<0.10.0>"],
    slices: [wire.CallSlice(0, 0, 10, 20, 1)],
  )
}

fn traced() -> ProbeRecord {
  probe_book.started(21, policy.CallTree, ["lists"], 1000, 5000, 4)
  |> probe_book.finish_calltrace(calls_snapshot(), ffi_dist.system_time_ms())
}

fn recording() -> ProbeRecord {
  probe_book.started(31, policy.SchedulingGc, [], 1000, 10_000, 2)
  |> probe_book.finish_events(
    wire.EventsSnapshot(
      probe_id: 31,
      state: wire.ProbeFinished,
      stop: wire.TraceDeadline,
      meter: wire.EventsMeter(
        trace: wire.TraceMeter(
          elapsed_ms: 10_000,
          events: 900,
          max_events: 100_000,
          dropped_events: 0,
          in_flight_at_stop: 0,
          peak_queue: 3,
          queue_limit: 50_000,
          targets_gone: 0,
        ),
        unpaired_events: 0,
        dropped_slices: 0,
        long_events_seen: 1,
        strays: 0,
        long_gc_ms: 50,
        long_schedule_ms: 100,
      ),
      processes: [
        wire.TracedProcess("<0.10.0>", 10, 4_000_000, 2, 1, 700_000),
      ],
      slices: [
        wire.ActivitySlice(0, wire.RunSlice, 1000, 500),
        wire.ActivitySlice(0, wire.MajorGcSlice, 2000, 700),
      ],
      long: [wire.LongGc("<0.10.0>", 61, 4096)],
    ),
    ffi_dist.system_time_ms(),
  )
}

fn page_with(probes: List(ProbeRecord)) -> #(harness.Rig, seam.Page) {
  let rig = harness.replay_with([fixture.observation(0, 1000)], probes, None)

  #(rig, harness.page(rig, "alice", harness.all))
}

fn on(page: seam.Page, slug: String) -> web_mount.State {
  let assert Ok(state) = web_mount.new_state(page, slug, 0)

  state
}

fn drawn(state: web_mount.State) -> model.ProfileModel {
  let assert Ok(found) =
    list.find_map(web_mount.fed(state), fn(feed) {
      case feed {
        msg.FedProfile(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

fn flow_of(state: web_mount.State) -> model.FlowModel {
  let assert Ok(found) =
    list.find_map(web_mount.fed(state), fn(feed) {
      case feed {
        msg.FedFlow(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

fn timeline_of(state: web_mount.State) -> timeline_model.TimelineModel {
  let assert Ok(found) =
    list.find_map(web_mount.fed(state), fn(feed) {
      case feed {
        msg.FedTimeline(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

// ------------------------------------------------- running and waiting

// The default is the samples taken while a process was on a scheduler, and
// the model still says how the whole set split.
pub fn a_stack_profile_starts_on_the_samples_that_were_running_test() {
  let #(_, page) = page_with([sampled(412, 2596, 16)])
  let data = drawn(on(page, "profile"))

  assert profile_view.root_total(data) == 412
  assert data.activity
    == model.Statuses(
      inclusion: activity.OnSchedulerOnly,
      split: activity.Split(on_scheduler: 412, waiting: 2596, unstated: 0),
      processes: Some(16),
    )
  assert profile_view.split_text(activity.Split(412, 2596, 0))
    == "3,008 samples: 412 running/runnable, 2,596 waiting"
}

pub fn including_waiting_draws_every_sample_test() {
  let #(_, page) = page_with([sampled(412, 2596, 16)])
  let state =
    web_mount.ask(
      on(page, "profile"),
      msg.ChooseSamples(activity.IncludeWaiting),
    )
  let data = drawn(state)

  assert profile_view.root_total(data) == 3008
  assert web_mount.samples_of(state) == activity.IncludeWaiting

  // And back.
  let state = web_mount.ask(state, msg.ChooseSamples(activity.OnSchedulerOnly))

  assert profile_view.root_total(drawn(state)) == 412
}

// Each page keeps its own choice, as it keeps its own filter chain.
pub fn the_choice_of_samples_is_the_pages_own_test() {
  let #(_, page) = page_with([sampled(412, 2596, 16)])
  let first =
    web_mount.ask(
      on(page, "profile"),
      msg.ChooseSamples(activity.IncludeWaiting),
    )
  let second = on(page, "profile")

  assert web_mount.samples_of(first) == activity.IncludeWaiting
  assert web_mount.samples_of(second) == activity.OnSchedulerOnly
}

pub fn a_profile_of_idle_processes_has_nothing_running_to_draw_test() {
  let #(_, page) = page_with([sampled(0, 3008, 16)])
  let data = drawn(on(page, "profile"))

  assert profile_view.all_waiting(data)
  assert profile_view.root_total(data) == 0
  assert profile_view.idle_text(Some(16))
    == "All 16 processes were waiting for messages for the whole window."

  // Asking for the waiting samples draws them, and the message goes.
  let shown =
    drawn(web_mount.ask(
      on(page, "profile"),
      msg.ChooseSamples(activity.IncludeWaiting),
    ))

  assert !profile_view.all_waiting(shown)
  assert profile_view.root_total(shown) == 3008
}

pub fn an_older_profile_with_no_statuses_is_neither_filtered_nor_split_test() {
  // A profile read from a capture written before statuses were kept.
  let stackless =
    probe_book.started(11, policy.Sampling, [], 0, 10_000, 2)
    |> probe_book.finish_stacks(
      wire.StacksSnapshot(..stacks(10, 0), stacks: [
        wire.SampledStack(10, "", [0, 1]),
      ]),
      1,
    )
  let #(_, page) = page_with([stackless])
  let data = drawn(on(page, "profile"))

  // An empty status is one this build does not classify, neither running nor
  // waiting, so nothing is split and nothing is dropped.
  assert profile_view.root_total(data) == 10
  assert data.activity == model.NoStatuses
  assert !profile_view.all_waiting(data)
}

// The files say which samples they hold. Cut to the samples on a scheduler a
// file lists the waiting ones as left out; with every sample included it has
// nothing of the kind to say.
pub fn an_export_says_which_samples_it_holds_test() {
  let #(rig, page) = page_with([sampled(412, 2596, 16)])
  let state =
    web_mount.ask(on(page, "profile"), msg.ExportProfile(msg.AsCollapsed))
  let assert [model.ExportReady(ticket:, losses:, ..)] =
    web_mount.exports_of(state)

  assert list.first(losses)
    == Ok(
      "Waiting samples: only the 412 samples taken on a scheduler are included; 2,596 taken while a process waited are left out.",
    )

  let assert Ok(file) =
    service.take_download(rig.service, key.to_string(ticket))

  assert file.body == "loom@runtime:root/1;loom@runtime:leaf/1 412\n"

  let everything =
    web_mount.ask(
      on(page, "profile"),
      msg.ChooseSamples(activity.IncludeWaiting),
    )
    |> web_mount.ask(msg.ExportProfile(msg.AsCollapsed))
  let assert [model.ExportReady(ticket: all, losses: none, ..)] =
    web_mount.exports_of(everything)

  assert !list.any(none, string.contains(_, "Waiting samples"))

  let assert Ok(whole) = service.take_download(rig.service, key.to_string(all))

  assert whole.body
    == "loom@runtime:root/1 2596\nloom@runtime:root/1;loom@runtime:leaf/1 412\n"
}

// -------------------------------------------------------------- call trees

pub fn a_call_tree_is_drawn_from_its_exclusive_time_test() {
  let #(_, page) = page_with([traced()])
  let data = drawn(on(page, "profile"))

  assert data.header.source == profile.TracedCalls
  assert data.header.title == "probe 21 · lists"
  assert data.header.info.method
    == "call and return_to events, folded in the agent"
  assert data.header.info.coverage.scope == "functions called"
  assert data.header.info.coverage.requested == 4
  assert data.header.info.coverage.achieved == 2
  assert data.header.info.coverage.outcome
    == measure.Partial(measure.Truncated(measure.BudgetReached))

  // The widths are the exclusive time, whose sum is the traced time.
  assert profile.column_type(data.profile, data.column)
    == Ok(profile.ValueType("exclusive time", unit.Nanoseconds))
  assert profile_view.root_total(data) == 4_000_000

  // Not a stack profile: nothing is split or filtered.
  assert data.activity == model.NoStatuses

  // The caveats the page puts beside every view.
  assert list.any(data.header.caveats, string.contains(
    _,
    "budget of 100,000 events",
  ))
  assert list.any(data.header.caveats, string.contains(
    _,
    "Untraced time inside a traced function counts as exclusive",
  ))
  assert list.any(data.header.caveats, string.contains(
    _,
    "Recursion deeper than one level reads as two levels",
  ))
  assert list.any(data.header.caveats, string.contains(
    _,
    "40 events arrived after the stop",
  ))

  // And every view that needs stacks has them.
  let assert model.HasStacks(..) = data.stacks
}

// The caveats of the stack profile are unchanged by the status split.
pub fn a_stack_profile_keeps_its_coverage_in_samples_taken_test() {
  let #(_, page) = page_with([sampled(412, 2596, 16)])
  let data = drawn(on(page, "profile"))

  // The coverage counts what the probe took, not what the page draws.
  assert data.header.info.coverage.achieved == 3008
}

// ------------------------------------------------------------------- flow

pub fn a_finished_call_tree_is_ready_on_the_profile_page_test() {
  let #(_, page) = page_with([traced()])
  let state = on(page, "overview")
  let assert Some(ready) = flow_of(state).ready

  assert ready.probe == "21"
  assert ready.opens == model.OpensProfile
  assert ready.summary == "8 traced calls over 2 functions"
}

pub fn a_finished_recording_is_ready_on_the_timeline_page_test() {
  let #(_, page) = page_with([recording()])
  let assert Some(ready) = flow_of(on(page, "overview")).ready

  assert ready.probe == "31"
  assert ready.opens == model.OpensTimeline
  assert ready.summary == "1 processes, 10 runs"
}

// The stack summary says how the samples split, since the profile's page
// opens on the running ones.
pub fn the_stack_summary_names_the_split_test() {
  let #(_, page) = page_with([sampled(412, 2596, 16)])
  let assert Some(ready) = flow_of(on(page, "overview")).ready

  assert ready.opens == model.OpensProfile
  assert ready.summary == "412 running or runnable of 3,008 samples at 100 Hz"
}

// ---------------------------------------------------------------- timeline

pub fn the_timeline_page_draws_the_newest_recording_and_call_tree_test() {
  let #(_, page) = page_with([traced(), recording()])
  let data = timeline_of(on(page, "timeline"))
  let assert Some(events) = data.events
  let assert Some(calls) = data.calls

  assert events.probe == "31"
  assert list.map(events.tracks, fn(track) { track.label })
    == ["<0.10.0> session:s1 / worker"]
  assert calls.probe == "21"
  assert list.map(calls.tracks, fn(track) { track.label })
    == ["<0.10.0> session:s1 / worker"]
}

// ------------------------------------------------------------------ exports

fn parsed(body: String) -> List(#(String, String)) {
  let event = {
    use ph <- decode.field("ph", decode.string)
    use name <- decode.field("name", decode.string)
    decode.success(#(ph, name))
  }
  let assert Ok(events) =
    json.parse(
      body,
      decode.field("traceEvents", decode.list(event), decode.success),
    )

  events
}

pub fn a_recording_exports_as_a_chrome_trace_that_parses_test() {
  let #(rig, page) = page_with([recording()])
  let state =
    web_mount.ask(on(page, "timeline"), msg.ExportTrace(msg.EventsTrace))
  let assert [model.ExportReady(label:, ticket:, losses:)] =
    web_mount.exports_of(state)
  let assert Ok(file) =
    service.take_download(rig.service, key.to_string(ticket))
  let events = parsed(file.body)

  assert label == "Scheduling trace"

  // The page that asked is shown the link, since nothing else would say the
  // button did anything.
  assert timeline_of(state).exports == web_mount.exports_of(state)
  assert file.file_name == "probe-31.scheduling.trace.json"
  assert list.filter(events, fn(e) { e.0 == "X" })
    == [#("X", "run"), #("X", "gc major")]
  assert list.map(list.filter(events, fn(e) { e.0 == "i" }), fn(e) { e.1 })
    == ["long_gc", "totals"]
  assert list.any(losses, string.contains(_, "no time"))
}

pub fn a_call_tree_exports_its_calls_as_a_chrome_trace_test() {
  let #(rig, page) = page_with([traced()])
  let state =
    web_mount.ask(on(page, "timeline"), msg.ExportTrace(msg.CallsTrace))
  let assert [model.ExportReady(label: "Call trace", ticket:, ..)] =
    web_mount.exports_of(state)
  let assert Ok(file) =
    service.take_download(rig.service, key.to_string(ticket))

  assert file.file_name == "probe-21.calls.trace.json"
  assert list.filter(parsed(file.body), fn(e) { e.0 == "X" })
    == [#("X", "lists:sort/1")]
}

pub fn exporting_a_timeline_that_was_never_recorded_says_so_test() {
  let #(_, page) = page_with([sampled(1, 0, 1)])
  let state =
    web_mount.ask(on(page, "timeline"), msg.ExportTrace(msg.EventsTrace))
  let assert [model.ExportRefused(reason:, ..)] = web_mount.exports_of(state)

  assert string.contains(reason, "no probe with a timeline")
}

pub fn a_timeline_export_without_the_capability_is_refused_test() {
  let rig =
    harness.replay_with([fixture.observation(0, 1000)], [recording()], None)
  let page = harness.page(rig, "weak", [policy.Observe])
  let state =
    web_mount.ask(on(page, "timeline"), msg.ExportTrace(msg.EventsTrace))
  let assert [model.ExportRefused(reason:, ..)] = web_mount.exports_of(state)

  assert string.contains(reason, "missing capability export")
}
