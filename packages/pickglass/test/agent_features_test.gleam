//// The agent's added requests as the viewer uses them: stack probes,
//// multi-module counters, collections and self-measures through a plan,
//// process detail, supervision, node facts and the owners totals.

import fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/feeds
import pickglass/observation.{Observation}
import pickglass/panel
import pickglass/probe_book
import pickglass/remote
import pickglass/seam
import pickglass/supervision_build
import pickglass_core/measure.{Known, Missing}
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/wire
import pickglass_web/model
import pickglass_web/msg

fn stacks(state: wire.ProbeState) -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 11,
    state:,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: 50,
      achieved_millihz: 48_000,
      rounds: 100,
      samples: 100,
      elapsed_ms: 2000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 2,
      truncated_samples: 0,
    ),
    frames: [
      wire.StackFrame("loom@runtime", "leaf", 1, wire.AtLine("src/a.gleam", 10)),
      wire.StackFrame("loom@runtime", "root", 1, wire.NoLocation),
    ],
    stacks: [
      wire.SampledStack(70, "running", [0, 1]),
      wire.SampledStack(30, "waiting", [1]),
    ],
  )
}

fn script(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskStartStacks(..)) ->
      Ok(wire.StacksStarted(11, 1, 50, 10_000, 500))
    wire.Extended(wire.AskReadStacks(11)) ->
      Ok(wire.StacksReport(stacks(wire.ProbeFinished)))
    wire.Extended(wire.AskStopStacks(11)) ->
      Ok(wire.StacksReport(stacks(wire.ProbeStopped)))
    wire.Extended(wire.AskStartCounterSet(..)) ->
      Ok(wire.CountersStarted(12, 9, 10_000))
    wire.Extended(wire.AskGc(..)) ->
      Ok(
        wire.CollectionReport(wire.CollectionSnapshot(
          pid_text: "<0.5.0>",
          outcome: wire.CollectionCompleted,
          elapsed_ms: 3,
          before: wire.HeapRead(heap(4096)),
          after: wire.HeapRead(heap(1024)),
        )),
      )
    wire.Extended(wire.AskMeasure(..)) ->
      Ok(
        wire.MeasureReport(
          wire.MeasureSnapshot("<0.5.0>", 5, [
            wire.SelfReading("state words", 10, wire.ReadingWords),
            wire.SelfReading("entries", 3, wire.ReadingCount),
          ]),
        ),
      )
    wire.Extended(wire.AskProcessDetail(..)) ->
      Ok(wire.ProcessDetailReport(detail()))
    wire.Extended(wire.AskSupervision(..)) ->
      Ok(wire.SupervisionReport(supervision()))
    other -> fixture.healthy(other)
  }
}

fn heap(total: Int) -> wire.HeapSizes {
  wire.HeapSizes(total + 100, total, total / 2, total, 0, 0, 0, 64, 0)
}

fn detail() -> wire.ProcessDetail {
  wire.ProcessDetail(
    pid_text: "<0.5.0>",
    sizes: wire.ProcessSizes(5000, 4096, 2048, 64),
    activity: wire.ProcessActivity(2, 900, "waiting", "m:f/1", "m:init/1", ""),
    gc: wire.ProcessGc(7, 65_535, 1864, 0, 4096, 0, 0, 0, 0),
    relations: wire.ProcessRelations(2, 1, 3, "<0.1.0>"),
    owner: wire.Unlabelled,
    capabilities: ["measure"],
  )
}

fn supervision() -> wire.SupervisionSnapshot {
  let edge = fn(child, parent, call) {
    wire.SpawnEdge(child, parent, "", call, wire.Unlabelled)
  }

  wire.SupervisionSnapshot(
    coverage: wire.SupervisionCoverage(4, 4, wire.SupervisionFinished, 2),
    edges: [
      edge("<0.1.0>", "", "supervisor:init/1"),
      edge("<0.2.0>", "<0.1.0>", "m:run/1"),
      edge("<0.3.0>", "<0.1.0>", "m:run/1"),
      edge("<0.4.0>", "<0.9.0>", "m:run/1"),
    ],
  )
}

fn pinned(page: seam.Page) -> String {
  let assert seam.PinIssued(token, _) = page.submit(seam.PinProcess("<0.5.0>"))

  token
}

pub fn a_sampling_probe_becomes_a_stack_profile_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(policy.Sampling, [token], ["*"], 10_000, 50))

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("11", 1)

  let assert Ok(done) = wait_profile(page, 30)
  let assert probe_book.Finished(profile: Some(found), notes:, outcome:, ..) =
    done.state
  let assert Ok(samples) = profile.column_named(found, "samples")

  assert done.kind == policy.Sampling
  assert outcome == measure.Complete
  assert profile.total(found, samples) == 100
  assert list.any(notes, fn(note) {
    string.contains(note, "48 Hz achieved of 50")
  })
  assert list.contains(
    fixture.drain(rig.seen, 50),
    wire.Extended(wire.AskStopStacks(11)),
  )
}

fn wait_profile(
  page: seam.Page,
  attempts: Int,
) -> Result(probe_book.ProbeRecord, Nil) {
  case probe_book.latest_profiled(page.probes()) {
    Ok(#(probe, _)) -> Ok(probe)
    Error(Nil) ->
      case attempts {
        0 -> Error(Nil)
        _ -> {
          sleep(100)

          wait_profile(page, attempts - 1)
        }
      }
  }
}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

pub fn stopping_a_stack_probe_reads_it_with_the_stack_request_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(policy.Sampling, [token], ["*"], 10_000, 50))
  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))
  let assert seam.StacksStopped(snapshot) = page.submit(seam.StopProbe("11"))

  assert snapshot.probe_id == 11
  assert list.contains(
    fixture.drain(rig.seen, 50),
    wire.Extended(wire.AskStopStacks(11)),
  )
}

pub fn a_stack_reply_naming_a_missing_frame_is_an_errored_probe_test() {
  let bad =
    wire.StacksSnapshot(..stacks(wire.ProbeFinished), stacks: [
      wire.SampledStack(5, "running", [7]),
    ])
  let probe = probe_book.started(11, policy.Sampling, [], 0, 1000, 1)
  let done = probe_book.finish_stacks(probe, bad, 10)
  let assert probe_book.Finished(outcome:, profile: None, ..) = done.state

  assert outcome
    == measure.Errored("a sampled stack names a frame the agent did not list")
}

// The real data shape of loom's session owners: one target is hibernating
// and the agent reports its samples as a stack of no frames.
pub fn a_sleeping_target_does_not_fail_the_whole_probe_test() {
  let asleep =
    wire.StacksSnapshot(..stacks(wire.ProbeFinished), stacks: [
      wire.SampledStack(70, "running", [0, 1]),
      wire.SampledStack(30, "waiting", []),
    ])
  let probe = probe_book.started(11, policy.Sampling, [], 0, 1000, 1)
  let done = probe_book.finish_stacks(probe, asleep, 10)
  let assert probe_book.Finished(outcome:, profile: Some(built), notes:, ..) =
    done.state

  assert outcome == measure.Complete
  assert list.length(profile.samples(built)) == 2
  assert list.any(notes, string.contains(_, "30 samples found a process"))
}

pub fn a_probe_that_hit_its_sample_budget_is_partial_and_says_so_test() {
  let cut =
    wire.StacksSnapshot(..stacks(wire.ProbeFinished), stop: wire.SamplingBudget)
  let done =
    probe_book.finish_stacks(
      probe_book.started(11, policy.Sampling, [], 0, 1000, 1),
      cut,
      10,
    )
  let assert probe_book.Finished(outcome:, ..) = done.state

  assert outcome == measure.Partial(measure.Truncated(measure.BudgetReached))
}

pub fn several_modules_start_one_counter_set_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(
      policy.Counters,
      [token],
      ["lists", "maps"],
      10_000,
      0,
    ))

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("12", 9)
  assert list.any(fixture.drain(rig.seen, 50), fn(request) {
    case request {
      wire.Extended(wire.AskStartCounterSet(
        [wire.CounterPattern("lists", "_"), wire.CounterPattern("maps", "_")],
        wire.PinnedProcesses(_),
        10_000,
        wire.CountTime,
      )) -> True
      _ -> False
    }
  })
}

pub fn a_targeted_collection_needs_a_plan_and_keeps_its_result_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)

  // It cannot be run directly.
  let assert seam.PlanReady(id, plan) = page.submit(seam.PlanTargetedGc(token))

  assert policy.plan_perturbation(plan) == policy.ForcedGc
  assert list.all(fixture.drain(rig.seen, 20), fn(request) {
    case request {
      wire.Extended(wire.AskGc(..)) -> False
      _ -> True
    }
  })

  let assert seam.Collected(snapshot) = page.submit(seam.ConfirmPlan(id))

  assert snapshot.outcome == wire.CollectionCompleted

  let assert [seam.GcRan(kept, _)] = page.results()

  assert kept == snapshot
}

pub fn a_self_measure_also_needs_a_plan_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, plan) = page.submit(seam.PlanSelfMeasure(token))

  assert policy.plan_perturbation(plan) == policy.Polling

  let assert seam.Measured(snapshot) = page.submit(seam.ConfirmPlan(id))

  assert list.length(snapshot.readings) == 2
  assert page.results() != []
}

pub fn a_page_without_perturb_cannot_plan_a_collection_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "reader", [policy.Observe, policy.Profile])
  let token = pinned(page)
  let assert seam.Rejected(reason) = page.submit(seam.PlanTargetedGc(token))

  assert string.contains(reason, "missing capability perturb")
}

fn base_inputs(page: seam.Page) -> feeds.Inputs {
  feeds.Inputs(
    page:,
    observations: [fixture.observation(1, 3000)],
    pins: [],
    plans: [],
    marks: [],
    baseline: None,
    probes: [],
    samples: activity.OnSchedulerOnly,
    chain: [],
    exports: [],
    comparison: feeds.no_comparison,
    now_ms: 10_000,
    subject: None,
    detail: None,
    results: [],
    supervision: None,
    entries: [],
    notes: [],
    refusal: None,
    refused_starts: [],
    lost: None,
    cadence_ms: 2000,
    sort: model.ByMemory,
    offset: 0,
  )
}

fn live_page() -> seam.Page {
  harness.page(harness.live(script, None), "alice", harness.all)
}

fn detail_model(inputs: feeds.Inputs) -> Result(model.ProcessDetailModel, Nil) {
  list.find_map(feeds.feeds_for(feeds.ProcessDetail, inputs), fn(feed) {
    case feed {
      msg.FedProcessDetail(data) -> Ok(data)
      _ -> Error(Nil)
    }
  })
}

pub fn the_detail_page_shows_the_census_row_when_the_process_is_not_pinned_test() {
  let inputs =
    feeds.Inputs(
      ..base_inputs(live_page()),
      subject: Some(feeds.row_key("<0.10.0>")),
    )
  let assert Ok(data) = detail_model(inputs)

  assert data.pin == model.NotPinned
  assert data.self_measure == model.Unavailable
  assert string.contains(data.birth, "pin the process")
  assert list.map(data.counters, fn(counter) { counter.label })
    == ["memory", "total heap", "mailbox", "reductions"]
}

pub fn the_detail_page_adds_the_agents_detail_and_the_last_results_test() {
  let inputs =
    feeds.Inputs(
      ..base_inputs(live_page()),
      subject: Some(feeds.row_key("<0.10.0>")),
      pins: [seam.PinCard("pin-x", "<0.10.0>", seam.PinLive, 1)],
      detail: Some(Ok(detail())),
      results: [
        seam.SelfMeasured(
          wire.MeasureSnapshot("<0.10.0>", 5, [
            wire.SelfReading("state words", 10, wire.ReadingWords),
          ]),
          1,
        ),
        seam.GcRan(
          wire.CollectionSnapshot(
            "<0.10.0>",
            wire.CollectionCompleted,
            3,
            wire.HeapRead(heap(4096)),
            wire.HeapGone,
          ),
          1,
        ),
      ],
    )
  let assert Ok(data) = detail_model(inputs)
  let value = fn(counters: List(model.Counter), label) {
    let assert Ok(found) =
      list.find(counters, fn(counter) { counter.label == label })

    found.value
  }

  assert data.pin == model.Pinned(feeds.pin_key("pin-x"))
  assert data.self_measure == model.Available
  assert string.contains(
    data.birth,
    "initial call m:init/1, spawned by <0.1.0>",
  )
  assert value(data.counters, "links") == Known(2)

  // Words are converted to bytes with the node's word size.
  assert value(data.counters, "self: state words") == Known(80)
  assert value(data.gc, "max heap") == measure.NotApplicable
  assert value(data.gc, "total heap before the last collection") == Known(4096)
  assert value(data.gc, "total heap after the last collection")
    == Missing(measure.ProcessExited)
}

pub fn a_process_the_census_does_not_list_has_no_detail_page_test() {
  let inputs =
    feeds.Inputs(
      ..base_inputs(live_page()),
      subject: Some(feeds.row_key("<0.999.0>")),
    )

  assert detail_model(inputs) == Error(Nil)
}

fn info() -> model.PanelInfo {
  panel.info(panel.Facts("x", "y", 0, "z", 1, 1, measure.Complete, None, None))
}

pub fn the_spawn_tree_has_roots_for_parents_outside_the_walk_test() {
  let page = supervision_build.build(info(), supervision())

  // `<0.1.0>` has no parent, and `<0.4.0>`'s parent was not scanned.
  assert list.map(page.roots, fn(node) { node.label }) == ["<0.1.0>", "<0.4.0>"]

  let assert [first, ..] = page.roots

  assert first.kind == model.Supervisor
  assert list.map(first.children, fn(node) { node.label })
    == ["<0.2.0>", "<0.3.0>"]
  assert list.map(first.children, fn(node) { node.kind })
    == [model.Leaf, model.Leaf]
  assert page.omitted == 0
  assert page.caveat == supervision_build.caveat
}

pub fn a_huge_tree_is_cut_and_the_rest_is_counted_test() {
  let wide =
    list.map(harness_numbers(supervision_build.max_nodes + 50), fn(n) {
      wire.SpawnEdge(
        "<0." <> string.inspect(n) <> ".0>",
        "",
        "",
        "m:run/1",
        wire.Unlabelled,
      )
    })
  let page =
    supervision_build.build(
      info(),
      wire.SupervisionSnapshot(
        coverage: wire.SupervisionCoverage(
          450,
          450,
          wire.SupervisionFinished,
          1,
        ),
        edges: wide,
      ),
    )

  assert supervision_build.drawn(page) == supervision_build.max_nodes
  assert page.omitted == 50
}

fn harness_numbers(n: Int) -> List(Int) {
  list.repeat(Nil, n) |> list.index_map(fn(_, index) { index + 1 })
}

pub fn the_supervision_feed_is_the_agents_walk_test() {
  let inputs =
    feeds.Inputs(
      ..base_inputs(live_page()),
      supervision: Some(Ok(supervision())),
    )
  let found = feeds.feeds_for(feeds.Supervision, inputs)

  assert list.any(found, fn(feed) {
    case feed {
      msg.FedSupervision(_) -> True
      _ -> False
    }
  })

  // A walk that failed draws nothing and invents nothing.
  assert list.all(
    feeds.feeds_for(
      feeds.Supervision,
      feeds.Inputs(..inputs, supervision: Some(Error("busy"))),
    ),
    fn(feed) {
      case feed {
        msg.FedSupervision(_) -> False
        _ -> True
      }
    },
  )
}

fn facts() -> wire.NodeFacts {
  wire.NodeFacts(
    uptime_ms: 60_000,
    creation: 3,
    emulator_flavor: "jit",
    emulator_type: "opt",
    erts_version: "17.0.5",
    otp_release: "29",
    schedulers: 8,
    schedulers_online: 8,
    dirty_cpu: 8,
    dirty_cpu_online: 8,
    dirty_io: 10,
    word_size: 8,
  )
}

fn with_system(carriers: wire.Carriers) -> observation.Observation {
  Observation(
    ..fixture.observation(1, 3000),
    system: Ok(wire.SystemSnapshot(facts(), carriers)),
  )
}

fn strip_of(found: List(msg.Feed)) -> model.StripModel {
  let assert Ok(strip) =
    list.find_map(found, fn(feed) {
      case feed {
        msg.FedStrip(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  strip
}

pub fn the_strip_has_the_nodes_uptime_and_creation_once_facts_are_read_test() {
  let page = live_page()
  let without = strip_of(feeds.feeds_for(feeds.Overview, base_inputs(page)))
  let with =
    strip_of(feeds.feeds_for(
      feeds.Overview,
      feeds.Inputs(..base_inputs(page), observations: [
        with_system(wire.CarriersUnavailable("no instrument")),
      ]),
    ))

  // The pong's age is the agent's, so without facts the uptime is a word.
  assert without.uptime_ms == Missing(measure.UnsupportedOnRuntime)

  // The facts were read at 3 000 ms and it is now 10 000 ms.
  assert with.uptime_ms == Known(67_000)
  assert with.incarnation.creation == 3
}

pub fn the_memory_page_lists_allocator_carriers_or_says_why_not_test() {
  let page = live_page()
  let panel = fn(carriers) {
    let assert Ok(data) =
      list.find_map(
        feeds.feeds_for(
          feeds.Memory,
          feeds.Inputs(..base_inputs(page), observations: [
            with_system(carriers),
          ]),
        ),
        fn(feed) {
          case feed {
            msg.FedMemory(data) -> Ok(data)
            _ -> Error(Nil)
          }
        },
      )

    data.allocators
  }

  let read =
    panel(
      wire.CarriersRead([
        wire.CarrierRow(
          "binary_alloc",
          wire.NotInCarrierPool,
          4,
          1_000_000,
          600_000,
          0,
        ),
      ]),
    )
  let assert [row] = read.body

  assert row.label == "binary_alloc"
  assert row.value == Known(1_000_000)
  assert row.used == Known(600_000)
  assert string.contains(row.note, "4 carriers")

  let refused =
    panel(wire.CarriersUnavailable("the instrument module is missing"))

  assert refused.body == []
  assert refused.info.coverage.outcome
    == measure.Refused("the instrument module is missing")
}

pub fn the_owners_remainder_is_the_totals_minus_the_listed_rows_test() {
  let listed = fixture.observation(1, 3000)
  let observed =
    Observation(
      ..listed,
      totals: Ok(wire.CensusTotals(50, 9_000_000, 0, 0, 100_000, 3, 1)),
    )
  let assert Ok(page) =
    list.find_map(feeds.feeds_for(feeds.Owners, base_with(observed)), fn(feed) {
      case feed {
        msg.FedOwners(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  // 50 processes in all, two listed; the heap is the totals' words in bytes
  // less the listed rows' own.
  assert page.remainder
    == model.Remainder(
      procs: Known(48),
      heap_cap: Known(100_000 * 8 - { 5000 / 16 * 8 + 4000 / 16 * 8 }),
    )
}

fn base_with(observed: observation.Observation) -> feeds.Inputs {
  feeds.Inputs(..base_inputs(live_page()), observations: [observed])
}

pub fn a_stack_probe_asks_for_twice_the_samples_its_duration_allows_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned(page)
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(policy.Sampling, [token], ["*"], 10_000, 50))
  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))

  // 50 Hz for 10 s over one target is 500 samples; the budget is 1 000, so
  // reaching the deadline is not also reaching the budget.
  assert list.any(fixture.drain(rig.seen, 50), fn(request) {
    case request {
      wire.Extended(wire.AskStartStacks(_, 50, 10_000, 1000)) -> True
      _ -> False
    }
  })
}

pub fn a_supervisor_is_recognised_by_its_initial_call_or_its_name_test() {
  let edge = fn(child, parent, name, call) {
    wire.SpawnEdge(child, parent, name, call, wire.Unlabelled)
  }
  let page =
    supervision_build.build(
      info(),
      wire.SupervisionSnapshot(
        coverage: wire.SupervisionCoverage(3, 3, wire.SupervisionFinished, 1),
        edges: [
          edge("<0.1.0>", "", "kernel_sup", "proc_lib:init_p/5"),
          edge("<0.2.0>", "<0.1.0>", "", "supervisor:init/1"),
          edge("<0.3.0>", "<0.1.0>", "", "m:run/1"),
        ],
      ),
    )
  let assert [root] = page.roots

  assert root.kind == model.Supervisor
  assert list.map(root.children, fn(node) { node.kind })
    == [model.Supervisor, model.Leaf]
}
