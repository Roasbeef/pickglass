//// A one-click profile over processes that exit between the plan and the
//// start: the survivors are sampled, the others are named, and a plan with no
//// survivor is refused in words.
////
//// The fake agent keeps the one rule the real one does: a pin whose process
//// exited is gone, so a stack probe told to drop gone pins samples the live
//// ones and names the rest, and refuses with `stale_pin` when none is live.

import fixture
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/audit
import pickglass/exec
import pickglass/probe_book
import pickglass/remote
import pickglass/seam
import pickglass_core/identity
import pickglass_core/wire
import qcheck

// The serial of the pin issued for `<0.N.0>` is N, as in the flow tests.
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

fn pid(n: Int) -> String {
  "<0." <> int.to_string(n) <> ".0>"
}

// A fake agent whose processes numbered in `dead` have exited by the time the
// probe starts. Pinning still succeeds, because they were alive when the plan
// was made.
fn agent(
  dead: List(Int),
) -> fn(wire.Request) -> Result(wire.Reply, remote.Failure) {
  fn(request) {
    case request {
      wire.AskPin(text) -> {
        let assert Ok(token) = identity.pin(fixture.boot(), serial_of(text))

        Ok(wire.Pinned(token, text))
      }
      wire.Extended(wire.AskStartStacks(
        tokens,
        _,
        duration,
        _,
        wire.DropMissing,
      )) -> {
        let serials = list.map(tokens, identity.pin_serial)
        let #(gone, live) =
          list.partition(serials, fn(serial) { list.contains(dead, serial) })

        case live {
          [] -> Error(remote.Refusal("stale_pin", "none of the pins exist"))
          _ ->
            Ok(wire.StacksStarted(
              11,
              list.length(live),
              100,
              duration,
              8000,
              gone,
            ))
        }
      }
      wire.Extended(wire.AskStartStacks(..)) ->
        Error(remote.Refusal("stale_pin", "the viewer must ask to drop"))
      wire.Extended(wire.AskReadStacks(11))
      | wire.Extended(wire.AskStopStacks(11)) ->
        Ok(wire.StacksReport(finished()))
      other -> fixture.healthy(other)
    }
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

fn ask(pids: List(String)) -> seam.ProfileRequest {
  seam.PlanProfile(
    pids:,
    chosen: "the busiest 4",
    duration_ms: 10_000,
    rate_hz: 100,
  )
}

fn plan_id(reply: seam.Reply) -> String {
  let assert seam.PlanReady(id, _) = reply

  id
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

fn four() -> List(String) {
  [pid(1), pid(2), pid(3), pid(4)]
}

pub fn every_process_alive_starts_exactly_as_before_test() {
  let rig = harness.live(agent([]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("11", 4)

  let assert [record] = page.probes()
  assert record.left_out == []
  assert record.processes == Some(4)
}

pub fn a_dead_process_is_left_out_and_named_test() {
  let rig = harness.live(agent([2, 4]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))
  let _ = fixture.drain(rig.seen, 50)

  // The probe runs over the two that survive, and the reply names the other
  // two in the order the plan had them.
  assert page.submit(seam.ConfirmPlan(id))
    == seam.ProbeStartedWithout("11", 2, [pid(2), pid(4)])

  // The command asked about all four, the processes the operator confirmed.
  let started =
    list.filter(fixture.drain(rig.seen, 50), fn(request) {
      case request {
        wire.Extended(wire.AskStartStacks(..)) -> True
        _ -> False
      }
    })
  let assert [wire.Extended(wire.AskStartStacks(tokens, ..))] = started
  assert list.map(tokens, identity.pin_serial) == [1, 2, 3, 4]

  // The record keeps who was left out, and the finished result says so.
  let assert [record] = page.probes()
  assert record.left_out == [pid(2), pid(4)]
  assert record.processes == Some(2)
}

pub fn the_result_and_the_audit_trail_name_what_was_dropped_test() {
  let rig = harness.live(agent([3]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))
  let assert seam.ProbeStartedWithout(..) = page.submit(seam.ConfirmPlan(id))
  let sentence = probe_book.left_out_sentence(3, [pid(3)])

  assert sentence
    == "1 of 4 selected processes exited before the probe started and were left out: <0.3.0>"

  let trail = list.map(page.audit(100), audit.describe)
  assert list.any(trail, string.contains(_, sentence))

  // The pin of the gone process is dead, so nothing can name it again.
  let assert Ok(card) =
    list.find(page.pins(), fn(card) { card.pid_text == pid(3) })
  assert card.status != seam.PinLive
}

pub fn only_the_pins_the_profile_took_and_still_has_are_released_test() {
  let rig = harness.live(agent([2]), None)
  let page = harness.page(rig, "alice", harness.all)

  // The operator pinned <0.2.0> first, and it is the process that dies. The
  // profile never owned that pin, and the agent no longer has it.
  let assert seam.PinIssued(_, _) = page.submit(seam.PinProcess(pid(2)))
  let id = plan_id(page.profile(ask(four())))
  let assert seam.ProbeStartedWithout("11", 3, [only]) =
    page.submit(seam.ConfirmPlan(id))
  assert only == pid(2)

  // The probe ends: the profile gives back the pins it took and still has.
  let requests = fixture.drain(rig.seen, 2500)
  assert unpinned(requests) == [1, 3, 4]
}

pub fn a_dropped_pin_of_the_profile_is_not_released_to_the_agent_test() {
  let rig = harness.live(agent([4]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))
  let assert seam.ProbeStartedWithout(..) = page.submit(seam.ConfirmPlan(id))

  assert unpinned(fixture.drain(rig.seen, 2500)) == [1, 2, 3]
}

pub fn the_final_note_of_a_dropped_probe_reaches_the_result_test() {
  let rig = harness.live(agent([2]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))
  let assert seam.ProbeStartedWithout(..) = page.submit(seam.ConfirmPlan(id))
  let _ = fixture.drain(rig.seen, 2500)

  let assert [record] = page.probes()
  let assert probe_book.Finished(notes:, ..) = record.state

  assert list.contains(notes, probe_book.left_out_sentence(3, [pid(2)]))
}

pub fn no_survivor_refuses_in_words_and_marks_the_pins_gone_test() {
  let rig = harness.live(agent([1, 2, 3, 4]), None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.profile(ask(four())))

  assert page.submit(seam.ConfirmPlan(id)) == seam.TargetsExited(four())
  assert page.probes() == []
  assert list.all(page.pins(), fn(card) { card.status != seam.PinLive })

  // The same plan cannot be confirmed again; the operator plans afresh.
  let assert seam.Rejected(_) = page.submit(seam.ConfirmPlan(id))
}

pub fn the_all_exited_sentence_is_not_a_bare_error_code_test() {
  let one = seam.all_exited_sentence([pid(7)])
  let many = seam.all_exited_sentence(four())

  assert one
    == "The selected process <0.7.0> exited before the probe started, so nothing was sampled"
  assert string.starts_with(many, "All 4 selected processes exited")
  assert !string.contains(one, "stale_pin")
  assert !string.contains(many, "stale_pin")
}

pub fn a_stale_pin_on_another_kind_of_probe_stays_a_refusal_test() {
  let rig =
    harness.live(
      fn(request) {
        case request {
          wire.Extended(wire.AskStartCalltrace(..)) ->
            Error(remote.Refusal("stale_pin", "the process exited"))
          other -> agent([])(other)
        }
      },
      None,
    )
  let page = harness.page(rig, "alice", harness.all)
  let id =
    plan_id(
      page.profile(
        seam.PlanCallTrace(
          pids: [pid(1)],
          chosen: "one",
          duration_ms: 5000,
          modules: ["lists"],
        ),
      ),
    )

  // Only a stack probe is told to drop, so a call trace keeps the agent's
  // own refusal rather than the all-exited words.
  let assert seam.Rejected(_) = page.submit(seam.ConfirmPlan(id))
}

// The dropped set is always a subset of the plan, in the plan's order, whatever
// serials the agent names.
pub fn survivor_selection_never_widens_the_plan_test() {
  qcheck.run(
    qcheck.default_config(),
    qcheck.tuple2(
      qcheck.generic_list(qcheck.bounded_int(0, 40), qcheck.bounded_int(0, 16)),
      qcheck.generic_list(qcheck.bounded_int(0, 60), qcheck.bounded_int(0, 20)),
    ),
    fn(generated) {
      let #(serials, claimed) = generated
      let planned = serials |> list.unique |> list.map(fixture.pin_token)
      let named = exec.planned_among(planned, claimed)

      // Every token named is in the plan and was claimed by the agent.
      assert list.all(named, fn(token) { list.contains(planned, token) })
      assert list.all(named, fn(token) {
        list.contains(claimed, identity.pin_serial(token))
      })

      // Nothing in the plan the agent claimed is missed, and order holds.
      assert named
        == list.filter(planned, fn(token) {
          list.contains(claimed, identity.pin_serial(token))
        })
      assert list.length(named) <= list.length(planned)
    },
  )
}

// What the plan said to sample is the survivors plus the left out, for any
// split of the plan.
pub fn survivors_and_left_out_make_up_the_plan_test() {
  qcheck.run(
    qcheck.default_config() |> qcheck.with_test_count(25),
    qcheck.generic_list(qcheck.bounded_int(1, 16), qcheck.bounded_int(1, 16)),
    fn(dead) {
      let rig = harness.live(agent(dead), None)
      let page = harness.page(rig, "alice", harness.all)
      let numbers = fixture.numbers(16) |> list.map(fn(n) { n })
      let id = plan_id(page.profile(ask(list.map(numbers, pid))))
      let dead_in_plan = list.filter(numbers, fn(n) { list.contains(dead, n) })

      case page.submit(seam.ConfirmPlan(id)) {
        seam.ProbeStarted(_, sampled) -> {
          assert dead_in_plan == []
          assert sampled == 16
        }
        seam.ProbeStartedWithout(_, sampled, left_out) -> {
          assert left_out == list.map(dead_in_plan, pid)
          assert sampled + list.length(left_out) == 16
          assert sampled > 0
        }
        seam.TargetsExited(left_out) -> {
          assert left_out == list.map(numbers, pid)
          assert list.length(dead_in_plan) == 16
        }
        _ -> panic as "a confirmed profile either started or was refused"
      }
    },
  )
}
