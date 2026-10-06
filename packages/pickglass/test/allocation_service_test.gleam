//// The allocation probe in the service: what a one-click allocation profile
//// pins and plans, what it asks the agent, what an operator's stop does, and
//// what the gate refuses before the agent is asked.

import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/exec
import pickglass/probe_book
import pickglass/remote
import pickglass/seam
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/wire

fn serial_of(text: String) -> Int {
  case string.split(text, ".") {
    [_, number, _] ->
      case int.parse(number) {
        Ok(n) -> n
        Error(Nil) -> 0
      }
    _ -> 0
  }
}

fn rows() -> List(wire.FunctionMemory) {
  [
    wire.FunctionMemory("m", "heavy", 1, 4000, 10, 500),
    wire.FunctionMemory("m", "light", 1, 30, 10, 20),
  ]
}

fn counters(state: wire.ProbeState) -> wire.CountersSnapshot {
  wire.CountersSnapshot(
    probe_id: 41,
    state:,
    matched_functions: 5,
    elapsed_ms: 2000,
    functions: 5,
    with_calls: 2,
    invalidated: 0,
    rows: [],
  )
}

fn memory(state: wire.ProbeState) -> wire.CounterMemorySnapshot {
  wire.CounterMemorySnapshot(
    probe_id: 41,
    state:,
    memory: wire.MemoryCounted(
      rows(),
      wire.MemoryTotals(read: 2, unread: 0, words: 4030),
    ),
  )
}

fn agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskPin(text) -> {
      let assert Ok(token) = identity.pin(fixture.boot(), serial_of(text))

      Ok(wire.Pinned(token, text))
    }
    wire.Extended(wire.AskStartCounterSet(..)) ->
      Ok(wire.CountersStarted(41, 5, 5000))
    wire.AskReadCounters(41) ->
      Ok(wire.CountersReport(counters(wire.ProbeRunning)))
    wire.AskStopCounters(41) ->
      Ok(wire.CountersReport(counters(wire.ProbeStopped)))
    wire.Extended(wire.AskReadCounterMemory(41)) ->
      Ok(wire.CounterMemoryReport(memory(wire.ProbeRunning)))
    other -> fixture.healthy(other)
  }
}

fn ask(pids: List(String)) -> seam.ProfileRequest {
  seam.PlanAllocation(
    pids:,
    chosen: "chosen for the test",
    duration_ms: 5000,
    modules: ["m", "n@*"],
  )
}

fn plan_id(reply: seam.Reply) -> String {
  let assert seam.PlanReady(id, _) = reply

  id
}

pub fn an_allocation_profile_plans_a_call_memory_probe_over_its_pins_test() {
  let rig = harness.live(agent, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))

  let assert [#(held_id, held_plan)] = page.plans()
  assert held_id == id

  let assert policy.StartProbe(spec:) = policy.plan_command(held_plan)
  assert spec.kind == policy.CallMemory
  assert list.length(spec.targets) == 2
  assert spec.modules == ["m", "n@*"]
  assert spec.duration_ms == 5000
  assert policy.perturbation_of(policy.plan_command(held_plan))
    == policy.Counting

  // Confirming starts one counter set that counts allocation, over the pins
  // and for the window planned.
  let _ = fixture.drain(rig.seen, 50)

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("41", 5)

  let assert [start] =
    list.filter(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskStartCounterSet(..)) -> True
        _ -> False
      }
    })
  let assert wire.Extended(wire.AskStartCounterSet(
    patterns,
    wire.PinnedProcesses(tokens),
    duration_ms,
    mode,
  )) = start

  assert patterns
    == [wire.CounterPattern("m", "_"), wire.CounterPattern("n@*", "_")]
  assert list.length(tokens) == 2
  assert duration_ms == 5000
  assert mode == wire.CountTimeAndMemory

  // The record is the probe's, with the processes the plan named.
  let assert [probe] = page.probes()

  assert probe.kind == policy.CallMemory
  assert probe.processes == Some(2)
  assert probe.duration_ms == 5000
}

// An operator's stop reads the allocation first, since the stop removes the
// probe, and closes the record with a profile of what was read.
pub fn an_operators_stop_reads_the_allocation_before_it_stops_the_probe_test() {
  let rig = harness.live(agent, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>"])))
  let assert seam.ProbeStarted(probe_id, _) = page.submit(seam.ConfirmPlan(id))
  let _ = fixture.drain(rig.seen, 50)

  let assert seam.ProbeStopped(snapshot) = page.submit(seam.StopProbe(probe_id))

  assert snapshot.probe_id == 41

  let requests =
    list.filter(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskReadCounterMemory(_)) | wire.AskStopCounters(_) ->
          True
        _ -> False
      }
    })

  assert requests
    == [wire.Extended(wire.AskReadCounterMemory(41)), wire.AskStopCounters(41)]

  let assert [probe] = page.probes()
  let assert probe_book.Finished(
    profile: Some(found),
    cost: capture.ProbeCost(counters: Some(facts), ..),
    ..,
  ) = probe.state

  assert list.length(profile.samples(found)) == 2
  assert facts.total_words == 4030
  assert facts.processes == Some(1)
}

// A read the agent refuses must not leave the probe counting: the stop is made
// whatever the read answered, and the refusal is what the operator is told.
pub fn a_refused_allocation_read_still_stops_the_probe_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskReadCounterMemory(_)) ->
        Error(remote.Refusal("no_such_probe", "no probe has that id"))
      other -> agent(other)
    }
  }
  let rig = harness.live(refusing, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>"])))
  let assert seam.ProbeStarted(probe_id, _) = page.submit(seam.ConfirmPlan(id))
  let _ = fixture.drain(rig.seen, 50)

  let assert seam.Rejected(reason) = page.submit(seam.StopProbe(probe_id))

  assert string.contains(reason, "no_such_probe")
  assert list.contains(fixture.drain(rig.seen, 50), wire.AskStopCounters(41))
}

// The limits the viewer holds an allocation probe to are refused before the
// agent is asked anything about it.
pub fn the_gate_refuses_an_allocation_plan_outside_its_limits_test() {
  let rig = harness.live(agent, None)
  let page = harness.page(rig, "alice", harness.all)
  let nine =
    list.map(fixture.numbers(9), fn(n) { "<0." <> int.to_string(n) <> ".0>" })

  let assert seam.Rejected(too_many) = page.profile(ask(nine))

  assert string.contains(too_many, "an allocation profile takes at most 8")

  let nine_modules =
    list.map(fixture.numbers(9), fn(n) { "m" <> int.to_string(n) })
  let assert seam.Rejected(modules) =
    page.profile(seam.PlanAllocation(
      pids: ["<0.1.0>"],
      chosen: "x",
      duration_ms: 5000,
      modules: nine_modules,
    ))

  assert string.contains(modules, "more than 8 modules")

  let assert seam.Rejected(none) =
    page.profile(
      seam.PlanAllocation(
        pids: ["<0.1.0>"],
        chosen: "x",
        duration_ms: 5000,
        modules: [],
      ),
    )

  assert string.contains(none, "no modules named")

  let assert seam.Rejected(long) =
    page.profile(
      seam.PlanAllocation(
        pids: ["<0.1.0>"],
        chosen: "x",
        duration_ms: 61_000,
        modules: ["m"],
      ),
    )

  assert string.contains(long, "duration outside 1..60000 ms")

  // Nothing was started, and the pins each refused plan took were given back.
  let started =
    list.any(fixture.drain(rig.seen, 2500), fn(request) {
      case request {
        wire.Extended(wire.AskStartCounterSet(..)) -> True
        _ -> False
      }
    })

  assert !started
}

// ------------------------------------------------------------------ polling

fn remote_over(
  script: fn(wire.Request) -> Result(wire.Reply, remote.Failure),
) -> remote.Remote {
  fixture.fake_remote(process.new_subject(), script)
}

pub fn a_running_probe_is_polled_for_its_counters_alone_test() {
  let answer = exec.poll_probe(remote_over(agent), "41", policy.CallMemory)

  assert answer == exec.Polled(counters(wire.ProbeRunning))
}

pub fn an_ended_probe_is_polled_for_both_readings_test() {
  let ended = fn(request) {
    case request {
      wire.AskReadCounters(41) ->
        Ok(wire.CountersReport(counters(wire.ProbeFinished)))
      wire.Extended(wire.AskReadCounterMemory(41)) ->
        Ok(wire.CounterMemoryReport(memory(wire.ProbeFinished)))
      other -> agent(other)
    }
  }

  assert exec.poll_probe(remote_over(ended), "41", policy.CallMemory)
    == exec.PolledAllocation(
      counters(wire.ProbeFinished),
      memory(wire.ProbeFinished),
    )
}

// A memory read that does not answer is asked again at the next poll, and one
// the agent refuses ends the probe as lost; neither is read as no allocation.
pub fn an_allocation_read_that_fails_is_never_read_as_none_test() {
  let with_memory = fn(answer) {
    fn(request) {
      case request {
        wire.AskReadCounters(41) ->
          Ok(wire.CountersReport(counters(wire.ProbeFinished)))
        wire.Extended(wire.AskReadCounterMemory(41)) -> answer
        other -> agent(other)
      }
    }
  }

  assert exec.poll_probe(
      remote_over(with_memory(Error(remote.TimedOut))),
      "41",
      policy.CallMemory,
    )
    == exec.PollPending

  let assert exec.PollRefused(reason) =
    exec.poll_probe(
      remote_over(
        with_memory(
          Error(remote.Refusal("no_such_probe", "no probe has that id")),
        ),
      ),
      "41",
      policy.CallMemory,
    )

  assert string.contains(reason, "no_such_probe")
}

// ------------------------------------------------------------ the record

pub fn an_agent_that_counted_no_allocation_closes_the_probe_errored_test() {
  let record = probe_book.started(41, policy.CallMemory, ["m"], 0, 5000, 5, 2)
  let closed =
    probe_book.finish_allocation(
      record,
      counters(wire.ProbeFinished),
      wire.CounterMemorySnapshot(41, wire.ProbeFinished, wire.NoMemoryCounted),
      7000,
    )
  let assert probe_book.Finished(outcome:, profile: None, ..) = closed.state

  assert outcome == measure.Errored("the agent counted no allocation")
}

// A list the agent cut at its 200 largest closes the probe as partial for the
// reason that it kept the top rows by design, and says how many it left out.
pub fn a_cut_list_closes_the_probe_partial_by_top_k_test() {
  let record = probe_book.started(41, policy.CallMemory, ["m"], 0, 5000, 5, 2)
  let closed =
    probe_book.finish_allocation(
      record,
      counters(wire.ProbeFinished),
      wire.CounterMemorySnapshot(
        41,
        wire.ProbeFinished,
        wire.MemoryCounted(
          rows(),
          wire.MemoryTotals(read: 300, unread: 2, words: 9000),
        ),
      ),
      7000,
    )
  let assert probe_book.Finished(outcome:, notes:, cost:, ..) = closed.state
  let assert Some(facts) = cost.counters

  // Every called function is read or unread, whatever the counters said.
  assert facts.called == 302
  assert outcome == measure.Partial(measure.Truncated(measure.TopKLimit))
  assert list.any(notes, string.contains(
    _,
    "298 functions with a reading are not listed",
  ))
  assert list.any(notes, string.contains(
    _,
    "2 called functions have no allocation reading",
  ))
}

// A probe that ended in error has no profile, but a capture still knows it was
// an allocation probe from what it enabled, so it is not read back as a plain
// counters probe.
pub fn an_errored_allocation_probe_reads_back_as_one_test() {
  let record = probe_book.started(41, policy.CallMemory, ["m"], 0, 5000, 5, 2)
  let closed =
    probe_book.finish_allocation(
      record,
      counters(wire.ProbeFinished),
      wire.CounterMemorySnapshot(41, wire.ProbeFinished, wire.NoMemoryCounted),
      7000,
    )
  let assert [back] = probe_book.of_records(probe_book.to_records([closed]))

  assert back.kind == policy.CallMemory
}
