//// The call tree and scheduling probes in the viewer: what they ask the agent,
//// what becomes of their results, and how a capture keeps them.

import fixture
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import harness
import pickglass/calltrace_profile
import pickglass/capture_build
import pickglass/capture_file
import pickglass/probe_book.{type ProbeRecord}
import pickglass/remote
import pickglass/seam
import pickglass/timeline_build
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/wire
import pickglass_web/timeline_model

// ------------------------------------------------------------ test data

fn meter(events: Int) -> wire.TraceMeter {
  wire.TraceMeter(
    elapsed_ms: 4800,
    events:,
    max_events: 100_000,
    dropped_events: 0,
    in_flight_at_stop: 0,
    peak_queue: 12,
    queue_limit: 50_000,
    targets_gone: 0,
  )
}

fn calls(
  stop: wire.TraceStop,
  trace: wire.TraceMeter,
) -> wire.CalltraceSnapshot {
  wire.CalltraceSnapshot(
    probe_id: 21,
    state: wire.ProbeFinished,
    stop:,
    meter: wire.CalltraceMeter(
      trace:,
      forced_closes: 0,
      distinct_paths: 3,
      dropped_calls: 0,
      elided_calls: 0,
      strays: 0,
      depth_limit: 64,
    ),
    frames: [
      wire.StackFrame("lists", "sort", 1, wire.NoLocation),
      wire.StackFrame("m", "work", 0, wire.NoLocation),
      wire.StackFrame("m", "main", 0, wire.NoLocation),
    ],
    // Leaf first. main calls work twice (200 ns, 50 of them its own), work
    // calls sort six times (150 ns), and main also runs once on its own.
    paths: [
      wire.CallPath(2, 200, 50, [1, 2]),
      wire.CallPath(6, 150, 150, [0, 1, 2]),
      wire.CallPath(1, 30, 30, [2]),
    ],
    processes: ["<0.1.0>"],
    slices: [wire.CallSlice(0, 0, 10, 20, 2), wire.CallSlice(0, 1, 5, 80, 1)],
  )
}

fn events(stop: wire.TraceStop) -> wire.EventsSnapshot {
  wire.EventsSnapshot(
    probe_id: 31,
    state: wire.ProbeFinished,
    stop:,
    meter: wire.EventsMeter(
      trace: meter(900),
      unpaired_events: 2,
      dropped_slices: 0,
      long_events_seen: 1,
      strays: 0,
      long_gc_ms: 50,
      long_schedule_ms: 100,
    ),
    processes: [
      wire.TracedProcess("<0.1.0>", 10, 4_000_000, 2, 1, 700_000),
      wire.TracedProcess("<0.2.0>", 0, 0, 0, 0, 0),
    ],
    slices: [
      wire.ActivitySlice(0, wire.RunSlice, 1000, 500),
      wire.ActivitySlice(0, wire.MajorGcSlice, 2000, 700),
    ],
    long: [wire.LongGc("<0.1.0>", 61, 4096)],
  )
}

fn started(kind: policy.ProbeKind, id: Int) -> ProbeRecord {
  probe_book.started(id, kind, ["lists"], 0, 5000, 2)
}

fn finished_calls() -> ProbeRecord {
  started(policy.CallTree, 21)
  |> probe_book.finish_calltrace(calls(wire.TraceDeadline, meter(3000)), 6000)
}

fn finished_events() -> ProbeRecord {
  started(policy.SchedulingGc, 31)
  |> probe_book.finish_events(events(wire.TraceDeadline), 6000)
}

fn column(found: profile.Profile, name: String) -> profile.Column {
  let assert Ok(column) = profile.column_named(found, name)

  column
}

fn closed(probe: ProbeRecord) -> #(measure.Outcome, List(String)) {
  let assert probe_book.Finished(outcome:, notes:, ..) = probe.state

  #(outcome, notes)
}

fn mentions(lines: List(String), part: String) -> Bool {
  list.any(lines, fn(line) { string.contains(line, part) })
}

// -------------------------------------------------- calls to a profile

// A path is a sample whose values are the calls, the inclusive time and the
// exclusive time, and the exclusive times of every path add up to the traced
// time the probe measured.
pub fn a_call_tree_becomes_a_traced_calls_profile_test() {
  let assert Ok(built) =
    calltrace_profile.build(calls(wire.TraceDeadline, meter(3000)))

  assert profile.source(built) == profile.TracedCalls
  assert list.map(profile.value_types(built), fn(v) { v.name })
    == ["calls", "inclusive time", "exclusive time"]
  assert profile.total(built, column(built, "calls")) == 9
  assert profile.total(built, column(built, "inclusive time")) == 380
  assert profile.total(built, column(built, "exclusive time")) == 230

  // Frames are leaf first, and a function is one function in every path.
  assert list.length(profile.functions(built)) == 3
  assert list.map(profile.samples(built), fn(sample) { sample.values })
    == [[2, 200, 50], [6, 150, 150], [1, 30, 30]]
}

pub fn a_path_that_cannot_be_read_is_refused_with_its_position_test() {
  let base = calls(wire.TraceDeadline, meter(3000))

  assert calltrace_profile.build(
      wire.CalltraceSnapshot(..base, paths: [
        wire.CallPath(1, 1, 1, [0]),
        wire.CallPath(1, 1, 1, []),
      ]),
    )
    == Error(calltrace_profile.EmptyPath(1))
  assert calltrace_profile.build(
      wire.CalltraceSnapshot(..base, paths: [wire.CallPath(1, 1, 1, [0, 9])]),
    )
    == Error(calltrace_profile.UnknownFrame(0, 9))
}

pub fn two_table_entries_for_one_function_share_an_id_test() {
  let base = calls(wire.TraceDeadline, meter(3000))
  let twice =
    wire.CalltraceSnapshot(
      ..base,
      frames: list.append(base.frames, [
        wire.StackFrame("lists", "sort", 1, wire.NoLocation),
      ]),
      paths: [wire.CallPath(1, 5, 5, [3]), wire.CallPath(1, 6, 6, [0])],
    )
  let assert Ok(built) = calltrace_profile.build(twice)

  // Four table entries name three functions, and the two paths that end in
  // `lists:sort/1` end in the same one.
  assert list.length(profile.functions(built)) == 3
  assert list.map(profile.samples(built), fn(sample) { sample.frames })
    == [[0], [0]]
}

// ----------------------------------------------------------- the probe book

pub fn a_finished_call_tree_holds_its_profile_slices_and_caveats_test() {
  let probe = finished_calls()
  let assert probe_book.Finished(profile: Some(built), cost:, ..) = probe.state
  let #(outcome, notes) = closed(probe)

  assert outcome == measure.Complete
  assert profile.total(built, column(built, "calls")) == 9
  assert cost.events == measure.Known(3000)
  assert cost.enabled == ["call", "return_to"]

  // The caveats a reader of the tree needs.
  assert mentions(notes, "ran to the end of its window")
  assert mentions(
    notes,
    "Untraced time inside a traced function counts as exclusive",
  )
  assert mentions(notes, "Recursion deeper than one level reads as two levels")

  // The slices are kept for a timeline, without the paths the profile holds.
  let assert probe_book.CallSlices(snapshot:) = probe.detail

  assert snapshot.paths == []
  assert list.length(snapshot.slices) == 2
}

// The event budget and a collector that fell behind each cut a probe short,
// and the notes say how many events were lost.
pub fn a_probe_cut_short_is_partial_and_says_what_it_dropped_test() {
  let behind =
    wire.TraceMeter(
      ..meter(30_000),
      dropped_events: 60_000,
      in_flight_at_stop: 59_900,
      peak_queue: 50_012,
    )
  let #(budget, budget_notes) =
    closed(
      started(policy.CallTree, 21)
      |> probe_book.finish_calltrace(calls(wire.TraceBudget, meter(100_000)), 1),
    )
  let #(overrun, overrun_notes) =
    closed(
      started(policy.CallTree, 21)
      |> probe_book.finish_calltrace(calls(wire.TraceOverrun, behind), 1),
    )

  assert budget == measure.Partial(measure.Truncated(measure.BudgetReached))
  assert mentions(budget_notes, "budget of 100,000 events")
  assert overrun == measure.Partial(measure.Truncated(measure.CollectorOverrun))
  assert mentions(overrun_notes, "collector fell behind")
  assert mentions(overrun_notes, "50,012 of 50,000")
  assert mentions(
    overrun_notes,
    "60,000 events arrived after the stop and were discarded unread; 59,900 were already queued",
  )
}

pub fn the_operator_and_the_exit_of_every_target_are_complete_test() {
  list.each(
    [wire.TraceStopped, wire.TraceTargetsGone, wire.TraceDeadline],
    fn(stop) {
      let #(outcome, _) =
        closed(
          started(policy.SchedulingGc, 31)
          |> probe_book.finish_events(events(stop), 1),
        )

      assert outcome == measure.Complete
    },
  )
}

pub fn a_call_tree_with_no_calls_says_so_test() {
  let empty =
    wire.CalltraceSnapshot(
      ..calls(wire.TraceDeadline, meter(0)),
      paths: [],
      slices: [],
    )
  let #(outcome, notes) =
    closed(
      started(policy.CallTree, 21) |> probe_book.finish_calltrace(empty, 1),
    )

  assert outcome == measure.Complete
  assert mentions(notes, "No call to a traced function happened")
}

pub fn a_call_tree_naming_an_unlisted_frame_is_an_error_not_a_profile_test() {
  let broken =
    wire.CalltraceSnapshot(..calls(wire.TraceDeadline, meter(1)), paths: [
      wire.CallPath(1, 1, 1, [99]),
    ])
  let probe =
    started(policy.CallTree, 21) |> probe_book.finish_calltrace(broken, 1)
  let assert probe_book.Finished(profile: None, outcome:, ..) = probe.state

  assert outcome
    == measure.Errored("the call paths could not be read as a profile")
}

pub fn an_events_probe_has_its_result_and_no_profile_test() {
  let probe = finished_events()
  let assert probe_book.Finished(profile: None, cost:, ..) = probe.state
  let #(outcome, notes) = closed(probe)

  assert outcome == measure.Complete
  assert cost.enabled
    == ["running", "garbage_collection", "long_gc", "long_schedule"]
  assert cost.events == measure.Known(900)
  assert probe.detail == probe_book.SchedulingDetail(events(wire.TraceDeadline))

  // What the result leaves out, and the thresholds in force.
  assert mentions(notes, "2 events had no start or end to pair with")
  assert mentions(
    notes,
    "collections of 50 ms or more and timeslices of 100 ms or more",
  )
  assert mentions(notes, "closest the BEAM comes to per-process CPU time")
}

pub fn an_events_probe_without_thresholds_says_none_were_watched_test() {
  let base = events(wire.TraceDeadline)
  let quiet =
    wire.EventsSnapshot(
      ..base,
      meter: wire.EventsMeter(..base.meter, long_gc_ms: 0, long_schedule_ms: 0),
    )
  let probe =
    started(policy.SchedulingGc, 31) |> probe_book.finish_events(quiet, 1)
  let assert probe_book.Finished(cost:, notes:, ..) = probe.state

  assert cost.enabled == ["running", "garbage_collection"]
  assert mentions(notes, "thresholds were not set")
}

// ------------------------------------------------------------- the timeline

pub fn an_events_probe_becomes_a_track_per_traced_process_test() {
  let probe = finished_events()
  let assert probe_book.SchedulingDetail(snapshot:) = probe.detail
  let timeline =
    timeline_build.events_of(probe, snapshot, measure.Complete, fn(pid) {
      pid <> " owner"
    })

  assert timeline.probe == "31"
  assert timeline.window_ns == 5_000_000_000
  assert timeline.observed_ns == 4_800_000_000
  assert list.map(timeline.tracks, fn(track) { track.label })
    == ["<0.1.0> owner", "<0.2.0> owner"]

  let assert [first, second] = timeline.tracks

  assert first.runs == 10
  assert first.run_ns == 4_000_000
  assert first.minor_gcs == 2
  assert first.major_gcs == 1
  assert first.gc_ns == 700_000
  assert first.slices
    == [
      timeline_model.ActivitySlice(1000, 500, timeline_model.RunActivity),
      timeline_model.ActivitySlice(2000, 700, timeline_model.MajorGcActivity),
    ]
  assert second.slices == []

  assert timeline.long == [timeline_model.LongGcMarker("<0.1.0>", 61, 4096)]
  assert timeline.long_gc_ms == 50
  assert timeline.long_schedule_ms == 100
  assert timeline.long_seen == 1
  assert mentions(timeline.notes, "ran to the end of its window")
}

pub fn a_call_tree_becomes_a_nested_track_per_process_test() {
  let probe = finished_calls()
  let assert probe_book.CallSlices(snapshot:) = probe.detail
  let timeline =
    timeline_build.calls_of(probe, snapshot, measure.Complete, fn(pid) { pid })
  let assert [track] = timeline.tracks

  assert track.label == "<0.1.0>"
  assert track.calls
    == [
      timeline_model.CallBox("lists:sort/1", 10, 20, 2),
      timeline_model.CallBox("m:work/0", 5, 80, 1),
    ]
}

// The newest probe of each kind is the one the page draws, and a replay of an
// unfinished probe draws nothing.
pub fn the_newest_probe_of_each_kind_is_drawn_test() {
  let older =
    started(policy.SchedulingGc, 30)
    |> probe_book.finish_events(
      wire.EventsSnapshot(..events(wire.TraceDeadline), probe_id: 30),
      5000,
    )
  let assert Ok(page) =
    timeline_build.build(
      [fixture.observation(0, 1000)],
      [],
      [started(policy.CallTree, 22), finished_events(), older, finished_calls()],
      2000,
      9000,
    )

  let assert Some(drawn) = page.events

  assert drawn.probe == "31"

  let assert Some(called) = page.calls

  assert called.probe == "21"

  // A ring with no tracing probe has neither.
  let assert Ok(plain) =
    timeline_build.build([fixture.observation(0, 1000)], [], [], 2000, 9000)

  assert plain.events == None
  assert plain.calls == None
}

// ---------------------------------------------------------------- captures

fn facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 1,
    boot: fixture.boot(),
    role: "loomd",
    workload: "",
    top_k: 200,
    deadline_ms: 15_000,
    os_start: identity.UnreadableStart,
    clock: None,
  )
}

// A call tree is a `profile` record and an `events` record of its slices; a
// scheduling probe is an `events` record alone. Both read back as the probes
// they were, with the same results.
pub fn both_probe_kinds_survive_a_capture_file_test() {
  let probes = [finished_events(), finished_calls()]
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(),
      "cap-trace",
      [fixture.observation(0, 1000), fixture.observation(1, 3000)],
      measure.EveryMs(2000),
      [],
      [],
      probes,
    )

  // What was written: one cost record per probe, the call tree's profile, and
  // an events record for each probe.
  let kinds = list.map(records, capture.kind_of)

  assert list.count(kinds, fn(kind) { kind == "perturbation" }) == 2
  assert list.count(kinds, fn(kind) { kind == "profile" }) == 1

  let traced =
    list.filter_map(records, fn(record) {
      case record {
        capture.EventsRecord(capture.Events(traced: Some(found), ..)) ->
          Ok(found)
        _ -> Error(Nil)
      }
    })

  assert list.length(traced) == 2

  let assert Ok(text) = capture_file.render(header, records)
  let assert Ok(loaded) = capture_file.parse(text)
  let read = probe_book.of_records(loaded.capture.records)

  assert list.length(read) == 2

  let assert Ok(scheduling) =
    list.find(read, fn(probe) { probe.kind == policy.SchedulingGc })
  let assert Ok(called) =
    list.find(read, fn(probe) { probe.kind == policy.CallTree })

  assert scheduling.detail
    == probe_book.SchedulingDetail(events(wire.TraceDeadline))
  assert closed(scheduling).0 == measure.Complete

  let assert probe_book.CallSlices(snapshot:) = called.detail

  assert snapshot.slices == calls(wire.TraceDeadline, meter(3000)).slices

  let assert probe_book.Finished(profile: Some(built), ..) = called.state

  assert profile.total(built, column(built, "exclusive time")) == 230
}

// A truncated outcome is part of the record, so a replay says the probe was
// cut short.
pub fn a_cut_short_probe_is_still_partial_after_a_capture_test() {
  let probe =
    started(policy.SchedulingGc, 31)
    |> probe_book.finish_events(events(wire.TraceOverrun), 1)
  let read = probe_book.of_records(probe_book.to_records([probe]))

  assert list.map(read, fn(item) { closed(item).0 })
    == [measure.Partial(measure.Truncated(measure.CollectorOverrun))]
}

// ------------------------------------------------------- over a fake agent

fn script(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskPin(text) -> {
      let assert Ok(token) = identity.pin(fixture.boot(), serial_of(text))

      Ok(wire.Pinned(token, text))
    }
    wire.Extended(wire.AskStartCalltrace(tokens, ..)) ->
      Ok(wire.CalltraceStarted(21, list.length(tokens), 7, 5000, 100_000, 2000))
    wire.Extended(wire.AskReadCalltrace(21))
    | wire.Extended(wire.AskStopCalltrace(21)) ->
      Ok(wire.CalltraceReport(calls(wire.TraceDeadline, meter(3000))))
    wire.Extended(wire.AskStartEvents(tokens, ..)) ->
      Ok(wire.EventsStarted(
        31,
        list.length(tokens),
        10_000,
        100_000,
        2000,
        50,
        100,
      ))
    wire.Extended(wire.AskReadEvents(31))
    | wire.Extended(wire.AskStopEvents(31)) ->
      Ok(wire.EventsReport(events(wire.TraceDeadline)))
    other -> fixture.healthy(other)
  }
}

fn serial_of(text: String) -> Int {
  case string.split(text, ".") {
    [_, number, _] -> result.unwrap(int.parse(number), 0)
    _ -> 0
  }
}

fn plan_id(reply: seam.Reply) -> String {
  let assert seam.PlanReady(id, _) = reply

  id
}

// A confirmed call trace asks the agent for exactly the modules, pins and
// budgets its plan stated, and the probe is recorded as a running call tree.
pub fn a_confirmed_call_trace_asks_the_agent_for_the_planned_scope_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(
        seam.PlanCallTrace(
          pids: ["<0.1.0>", "<0.2.0>"],
          chosen: "two processes",
          duration_ms: 5000,
          modules: ["lists", "gleam@list"],
        ),
      ),
    )

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("21", 7)

  let requests = fixture.drain(rig.seen, 50)
  let assert Ok(start) =
    list.find(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCalltrace(..)) -> True
        _ -> False
      }
    })
  let assert wire.Extended(wire.AskStartCalltrace(
    tokens,
    patterns,
    duration_ms,
    max_events,
    timeline,
  )) = start

  assert list.length(tokens) == 2
  assert patterns
    == [
      wire.CounterPattern("lists", "_"),
      wire.CounterPattern("gleam@list", "_"),
    ]
  assert duration_ms == 5000
  assert max_events == policy.trace_event_budget
  assert timeline == policy.timeline_slice_limit

  let assert [probe] = page.probes()

  assert probe.kind == policy.CallTree
  assert probe.modules == ["lists", "gleam@list"]
  assert probe_book.is_running(probe)
}

// The service polls the running probe, takes the result into a profile and
// slices before the agent discards it, and releases the pins the profile took.
pub fn a_call_trace_that_ends_is_taken_and_its_pins_released_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(
        seam.PlanCallTrace(
          pids: ["<0.1.0>"],
          chosen: "one process",
          duration_ms: 5000,
          modules: ["lists"],
        ),
      ),
    )
  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))
  let requests = fixture.drain(rig.seen, 2500)

  assert list.contains(requests, wire.Extended(wire.AskReadCalltrace(21)))
  assert list.contains(requests, wire.Extended(wire.AskStopCalltrace(21)))
  assert list.any(requests, fn(request) {
    case request {
      wire.AskUnpin(_) -> True
      _ -> False
    }
  })

  let assert [probe] = page.probes()
  let assert probe_book.Finished(profile: Some(built), ..) = probe.state

  assert profile.total(built, column(built, "calls")) == 9
  assert probe.detail != probe_book.NoDetail
}

pub fn a_confirmed_recording_asks_for_the_thresholds_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(seam.PlanRecording(
        pids: ["<0.1.0>", "<0.2.0>"],
        chosen: "two processes",
        duration_ms: 10_000,
      )),
    )

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("31", 2)

  let assert Ok(start) =
    list.find(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskStartEvents(..)) -> True
        _ -> False
      }
    })
  let assert wire.Extended(wire.AskStartEvents(
    tokens,
    duration_ms,
    max_events,
    slices,
    long_gc_ms,
    long_schedule_ms,
  )) = start

  assert list.length(tokens) == 2
  assert duration_ms == 10_000
  assert max_events == policy.trace_event_budget
  assert slices == policy.timeline_slice_limit
  assert long_gc_ms == policy.long_gc_ms
  assert long_schedule_ms == policy.long_schedule_ms

  let assert [probe] = page.probes()

  assert probe.kind == policy.SchedulingGc
}

// A node older than OTP 28 refuses a probe that sets the node-wide thresholds
// and arms nothing, so the probe is asked again without them and still runs.
pub fn a_node_without_thresholds_gets_the_recording_without_them_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskStartEvents(_, _, _, _, 50, 100)) ->
        Error(remote.Refusal("thresholds_unavailable", "needs OTP 28"))
      other -> script(other)
    }
  }
  let rig = harness.live(refusing, None)
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(seam.PlanRecording(
        pids: ["<0.1.0>"],
        chosen: "one process",
        duration_ms: 10_000,
      )),
    )

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("31", 1)

  let starts =
    list.filter_map(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskStartEvents(_, _, _, _, gc, schedule)) ->
          Ok(#(gc, schedule))
        _ -> Error(Nil)
      }
    })

  assert starts == [#(50, 100), #(0, 0)]
}

// Another refusal of a start is not retried: the agent's code comes back.
pub fn a_refused_recording_is_not_retried_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskStartEvents(..)) ->
        Error(remote.Refusal("probe_limit", "an events probe is running"))
      other -> script(other)
    }
  }
  let rig = harness.live(refusing, None)
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(seam.PlanRecording(
        pids: ["<0.1.0>"],
        chosen: "one process",
        duration_ms: 10_000,
      )),
    )
  let assert seam.Rejected(reason) = page.submit(seam.ConfirmPlan(id))

  assert string.contains(reason, "probe_limit")
  assert list.count(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskStartEvents(..)) -> True
        _ -> False
      }
    })
    == 1
}

// ------------------------------------------------------ the one-click swap

fn stacks(pids: List(String)) -> seam.ProfileRequest {
  seam.PlanProfile(
    pids:,
    chosen: "chosen for the test",
    duration_ms: 10_000,
    rate_hz: 100,
  )
}

// A pending stack profile of few processes can be planned as a call trace over
// the same pins, and back; no pin is released or taken in between.
pub fn a_stack_profile_can_be_replanned_as_a_call_trace_and_back_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let first = plan_id(page.profile(stacks(["<0.1.0>", "<0.2.0>"])))
  let _ = fixture.drain(rig.seen, 50)
  let second =
    plan_id(
      page.profile(seam.ReplanProfile(first, 5000, seam.ByCalls(["lists"]))),
    )
  let requests = fixture.drain(rig.seen, 50)

  assert !list.any(requests, fn(request) {
    case request {
      wire.AskPin(_) | wire.AskUnpin(_) -> True
      _ -> False
    }
  })

  let assert [#(held, held_plan)] = page.plans()
  let assert policy.StartProbe(spec:) = policy.plan_command(held_plan)

  assert held == second
  assert spec.kind == policy.CallTree
  assert spec.modules == ["lists"]
  assert spec.duration_ms == 5000
  assert list.length(spec.targets) == 2

  let assert [note] = page.profile_notes()

  assert note.method == seam.ByCalls(["lists"])
  assert note.processes == 2

  // And back to stacks.
  let third =
    plan_id(
      page.profile(seam.ReplanProfile(second, 10_000, seam.ByStacks(100))),
    )
  let assert [#(_, back)] = page.plans()
  let assert policy.StartProbe(spec: sampled) = policy.plan_command(back)

  assert third != second
  assert sampled.kind == policy.Sampling
}

// The agent runs a call tree over four processes at most. A swap it would
// refuse is refused before the plan is touched, so the operator keeps the
// profile they had and its pins.
pub fn too_many_processes_for_a_call_trace_leave_the_plan_alone_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let first =
    plan_id(
      page.profile(
        stacks(["<0.1.0>", "<0.2.0>", "<0.3.0>", "<0.4.0>", "<0.5.0>"]),
      ),
    )
  let _ = fixture.drain(rig.seen, 50)
  let assert seam.Rejected(reason) =
    page.profile(seam.ReplanProfile(first, 5000, seam.ByCalls(["lists"])))

  assert string.contains(reason, "at most 4 processes")
  assert string.contains(reason, "chose 5")

  // The first plan is still the one pending, with every pin.
  let assert [#(held, _)] = page.plans()

  assert held == first
  assert fixture.drain(rig.seen, 50) == []
}

pub fn a_call_trace_of_five_processes_is_refused_and_its_pins_given_back_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.Rejected(reason) =
    page.profile(
      seam.PlanCallTrace(
        pids: ["<0.1.0>", "<0.2.0>", "<0.3.0>", "<0.4.0>", "<0.5.0>"],
        chosen: "five",
        duration_ms: 5000,
        modules: ["lists"],
      ),
    )

  assert string.contains(reason, "call trace takes at most 4 processes")
  assert page.plans() == []
}

pub fn a_recording_takes_at_most_eight_processes_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let many =
    list.map(fixture.numbers(9), fn(n) { "<0." <> int.to_string(n) <> ".0>" })
  let assert seam.Rejected(reason) =
    page.profile(seam.PlanRecording(
      pids: many,
      chosen: "nine",
      duration_ms: 10_000,
    ))

  assert string.contains(reason, "recording takes at most 8 processes")
}

// The plan states the durations the agent will run: a call tree for at most
// ten seconds.
pub fn a_call_trace_longer_than_the_agent_runs_is_not_planned_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.Rejected(reason) =
    page.profile(
      seam.PlanCallTrace(
        pids: ["<0.1.0>"],
        chosen: "one",
        duration_ms: 30_000,
        modules: ["lists"],
      ),
    )

  assert string.contains(reason, "duration outside 1..10000 ms")
}
