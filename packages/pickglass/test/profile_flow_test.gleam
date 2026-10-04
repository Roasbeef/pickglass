//// The one-click profile in the service: what it pins, what it plans, and
//// when it lets the pins go.

import fixture
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import harness
import pickglass/remote
import pickglass/seam
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/wire

// The serial of the pin issued for `<0.N.0>` is N, so a test can tell which
// process a token names.
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

fn script(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskPin("<0.666.0>") ->
      Error(remote.Refusal("no_such_process", "no live local process"))
    wire.AskPin(text) -> {
      let serial = serial_of(text)
      let assert Ok(token) = identity.pin(fixture.boot(), serial)

      Ok(wire.Pinned(token, text))
    }
    wire.Extended(wire.AskStartStacks(..)) ->
      Ok(wire.StacksStarted(11, 2, 100, 10_000, 8000))
    other -> fixture.healthy(other)
  }
}

fn pins_of(requests: List(wire.Request)) -> List(String) {
  list.filter_map(requests, fn(request) {
    case request {
      wire.AskPin(text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
}

fn unpinned(requests: List(wire.Request)) -> List(Int) {
  list.filter_map(requests, fn(request) {
    case request {
      wire.AskUnpin(token) -> Ok(identity.pin_serial(token))
      _ -> Error(Nil)
    }
  })
  |> list.sort(int.compare)
}

fn ask(pids: List(String)) -> seam.ProfileRequest {
  seam.PlanProfile(
    pids:,
    chosen: "chosen for the test",
    duration_ms: 10_000,
    rate_hz: 100,
  )
}

fn plan_id(reply: seam.Reply) -> String {
  let assert seam.PlanReady(id, _) = reply

  id
}

pub fn a_profile_pins_then_plans_and_starts_nothing_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let requests = fixture.drain(rig.seen, 50)

  assert pins_of(requests) == ["<0.1.0>", "<0.2.0>"]
  assert !list.any(requests, fn(request) {
    case request {
      wire.Extended(wire.AskStartStacks(..)) -> True
      _ -> False
    }
  })

  // The plan names exactly the pins it took, at the rate asked.
  let assert [#(held_id, held_plan)] = page.plans()
  assert held_id == id
  let assert policy.StartProbe(spec:) = policy.plan_command(held_plan)
  assert list.length(spec.targets) == 2
  assert spec.rate_hz == 100
  assert spec.duration_ms == 10_000

  let assert [note] = page.profile_notes()
  assert note.plan_id == id
  assert note.chosen == "chosen for the test"
}

pub fn confirming_starts_one_stack_probe_over_the_pins_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let _ = fixture.drain(rig.seen, 50)

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("11", 2)

  let requests = fixture.drain(rig.seen, 50)
  let assert [
    wire.Extended(wire.AskStartStacks(tokens, rate, duration, samples)),
  ] =
    list.filter(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartStacks(..)) -> True
        _ -> False
      }
    })

  assert list.length(tokens) == 2
  assert rate == 100
  assert duration == 10_000
  assert samples == 2 * 100 * 10 * 2
}

// A plan nobody confirms is released with its pins, a second after the plan
// is cancelled.
pub fn a_cancelled_plan_releases_what_it_pinned_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let _ = fixture.drain(rig.seen, 50)

  let _ = page.submit(seam.CancelPlan(id))

  assert unpinned(fixture.drain(rig.seen, 2500)) == [1, 2]
}

// A pin the operator held before the profile is the operator's: the profile
// uses it and never releases it.
pub fn a_pin_the_operator_held_is_not_released_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.PinIssued(_, _) = page.submit(seam.PinProcess("<0.1.0>"))
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let requests = fixture.drain(rig.seen, 50)

  // Only the process that was not pinned is pinned for the profile.
  assert pins_of(requests) == ["<0.1.0>", "<0.2.0>"]
  let _ = page.submit(seam.CancelPlan(id))

  assert unpinned(fixture.drain(rig.seen, 2500)) == [2]
}

pub fn a_process_that_cannot_be_pinned_is_left_out_and_said_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let _ = plan_id(page.profile(ask(["<0.1.0>", "<0.666.0>"])))
  let assert [note] = page.profile_notes()

  assert string.contains(note.chosen, "1 could not be pinned and are left out")

  let assert [#(_, held_plan)] = page.plans()
  let assert policy.StartProbe(spec:) = policy.plan_command(held_plan)

  assert list.length(spec.targets) == 1
}

pub fn a_profile_of_nothing_pinnable_plans_nothing_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.Rejected(reason) = page.profile(ask(["<0.666.0>"]))

  assert string.contains(reason, "none of the 1 processes could be pinned")
  assert page.plans() == []
  assert page.profile_notes() == []
}

pub fn a_profile_takes_at_most_the_agents_limit_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let many =
    list.map(fixture.numbers(17), fn(n) { "<0." <> int.to_string(n) <> ".0>" })
  let assert seam.Rejected(reason) = page.profile(ask(many))

  assert string.contains(reason, "at most 16")
  assert pins_of(fixture.drain(rig.seen, 50)) == []
}

// Pinning needs observe and the plan needs profile, each decided by the gate.
pub fn a_principal_without_profile_pins_but_plans_nothing_and_releases_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "bob", [policy.Observe])
  let assert seam.Rejected(_) = page.profile(ask(["<0.1.0>"]))
  let requests = fixture.drain(rig.seen, 50)

  // What it pinned for the refused plan is given back at once.
  assert pins_of(requests) == ["<0.1.0>"]
  assert unpinned(requests) == [1]
  assert page.plans() == []
}

pub fn planning_again_replaces_the_plan_and_keeps_the_pins_test() {
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let first = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let _ = fixture.drain(rig.seen, 50)
  let second =
    plan_id(page.profile(seam.ReplanProfile(first, 30_000, seam.ByStacks(250))))
  let requests = fixture.drain(rig.seen, 50)

  // The old plan is gone, the new one has the new settings, and no pin was
  // released or taken again in between.
  assert first != second
  assert unpinned(requests) == []
  assert pins_of(requests) == []
  let assert [#(held, held_plan)] = page.plans()
  assert held == second
  let assert policy.StartProbe(spec:) = policy.plan_command(held_plan)
  assert spec.duration_ms == 30_000
  assert spec.rate_hz == 250

  let assert [note] = page.profile_notes()
  assert note.plan_id == second
  assert note.duration_ms == 30_000

  // Planning a plan that is gone changes nothing.
  assert page.profile(seam.ReplanProfile(first, 10_000, seam.ByStacks(50)))
    == seam.Rejected("that profile plan is no longer pending")
  let assert [_] = page.plans()
}

// When the probe ends the pins it took are released, and only then.
pub fn a_finished_probe_releases_its_pins_test() {
  let rig = harness.live(running_then_done, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(["<0.1.0>", "<0.2.0>"])))
  let assert seam.ProbeStarted(_, _) = page.submit(seam.ConfirmPlan(id))
  let requests = fixture.drain(rig.seen, 2500)

  assert unpinned(requests) == [1, 2]
  let _ = None
}

fn running_then_done(
  request: wire.Request,
) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskReadStacks(11))
    | wire.Extended(wire.AskStopStacks(11)) -> Ok(wire.StacksReport(finished()))
    other -> script(other)
  }
}

fn finished() -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 11,
    state: wire.ProbeFinished,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: 100,
      achieved_millihz: 98_000,
      rounds: 980,
      samples: 1960,
      elapsed_ms: 10_000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 1,
      truncated_samples: 0,
    ),
    frames: [wire.StackFrame("m", "f", 0, wire.NoLocation)],
    stacks: [wire.SampledStack(1960, "running", [0])],
  )
}
