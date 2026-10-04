import fixture
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/audit
import pickglass/capture_file
import pickglass/hub
import pickglass/remote
import pickglass/seam
import pickglass/service
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/wire
import simplifile

fn counters(token: String) -> seam.Request {
  seam.PlanProbe(policy.Counters, [token], ["lists"], 30_000)
}

fn pinned_token(page: seam.Page) -> String {
  let assert seam.PinIssued(token, _) = page.submit(seam.PinProcess("<0.5.0>"))

  token
}

fn plan_id(reply: seam.Reply) -> String {
  let assert seam.PlanReady(id, _) = reply

  id
}

fn rejected(reply: seam.Reply) -> String {
  let assert seam.Rejected(reason) = reply

  reason
}

fn mentions(lines: List(String), part: String) -> Bool {
  list.any(lines, fn(line) { string.contains(line, part) })
}

pub fn a_confirmed_plan_starts_the_probe_on_its_pins_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned_token(page)
  let id = plan_id(page.submit(counters(token)))

  assert page.submit(seam.ConfirmPlan(id)) == seam.ProbeStarted("7", 3)

  let requests = fixture.drain(rig.seen, 50)

  // The probe's targets are the pins, and never every process.
  assert list.contains(requests, wire.AskPin("<0.5.0>"))
  assert list.contains(
    requests,
    wire.AskStartCounters(
      "lists",
      "_",
      wire.PinnedProcesses([fixture.pin_token(1)]),
      30_000,
    ),
  )
  assert !list.any(requests, fn(request) {
    case request {
      wire.AskStartCounters(_, _, wire.AllProcesses, _) -> True
      _ -> False
    }
  })
}

pub fn a_plan_confirms_only_once_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.submit(counters(pinned_token(page))))

  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))

  // The replay finds no plan and reaches the agent with nothing.
  let replay = rejected(page.submit(seam.ConfirmPlan(id)))

  assert string.contains(replay, "no such plan")

  let starts =
    fixture.drain(rig.seen, 50)
    |> list.filter(fn(request) {
      case request {
        wire.AskStartCounters(..) -> True
        _ -> False
      }
    })

  assert list.length(starts) == 1
  assert mentions(harness.trail(rig), "confirm by p")
    || mentions(harness.trail(rig), "confirm by alice names no plan")
}

pub fn another_principal_cannot_confirm_the_plan_test() {
  let rig = harness.live(fixture.healthy, None)
  let alice = harness.page(rig, "alice", harness.all)
  let bob = harness.page(rig, "bob", harness.all)
  let id = plan_id(alice.submit(counters(pinned_token(alice))))

  let refused = rejected(bob.submit(seam.ConfirmPlan(id)))

  assert string.contains(refused, "another principal")
  assert mentions(harness.trail(rig), "bob")

  // The plan is still alice's to confirm.
  let assert seam.ProbeStarted(..) = alice.submit(seam.ConfirmPlan(id))
}

pub fn a_probe_needs_pinned_targets_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)

  // No targets at all: the viewer offers no probe over every process.
  let none =
    rejected(
      page.submit(seam.PlanProbe(policy.Counters, [], ["lists"], 30_000)),
    )

  assert string.contains(none, "invalid spec")

  // A token of the right boot that the agent never issued.
  let forged = rejected(page.submit(counters("pgtestboot1:99")))

  assert string.contains(forged, "pin not revalidated")

  // A token of another boot.
  let other = rejected(page.submit(counters("otherboot:1")))

  assert string.contains(other, "pin not revalidated")
}

pub fn a_page_without_the_capability_is_denied_and_audited_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "weak", [policy.Observe])
  let token = pinned_token(page)

  let denied = rejected(page.submit(counters(token)))

  assert string.contains(denied, "missing capability profile")
  assert string.contains(
    rejected(page.submit(seam.PlanTargetedGc(token))),
    "missing capability perturb",
  )
  assert string.contains(
    rejected(page.submit(seam.Detach)),
    "missing capability administer",
  )
  assert mentions(harness.trail(rig), "denied, missing capability profile")
}

pub fn malformed_requests_are_refused_before_the_gate_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)

  assert rejected(page.submit(seam.UnpinProcess("not a token")))
    == "malformed pin token"
  assert string.contains(
    rejected(page.submit(seam.Checkpoint(""))),
    "checkpoint name",
  )
  assert string.contains(rejected(page.submit(seam.ReadAudit(0))), "audit read")
  assert mentions(harness.trail(rig), "request from alice refused")
}

pub fn a_probe_kind_the_agent_cannot_run_is_refused_in_words_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned_token(page)
  let id =
    plan_id(
      page.submit(seam.PlanProbe(policy.CallTree, [token], ["lists"], 10_000)),
    )

  assert string.contains(
    rejected(page.submit(seam.ConfirmPlan(id))),
    "the agent has no call_tree probe",
  )
}

pub fn a_stale_pin_refusal_kills_the_pin_test() {
  let script = fn(request) {
    case request {
      wire.AskStartCounters(..) ->
        Error(remote.Refusal("stale_pin", "the process exited"))
      other -> fixture.healthy(other)
    }
  }
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned_token(page)
  let id = plan_id(page.submit(counters(token)))

  assert string.contains(
    rejected(page.submit(seam.ConfirmPlan(id))),
    "stale_pin",
  )

  // The pin is evidence now, and a new plan against it is denied.
  assert string.contains(
    rejected(page.submit(counters(token))),
    "pin not revalidated",
  )

  let assert [pin] = page.pins()

  assert pin.status == seam.PinGone("stale_pin")
}

pub fn losing_the_target_kills_every_pin_test() {
  let script = fn(request) {
    case request {
      wire.AskPin(text) -> Ok(wire.Pinned(fixture.pin_token(1), text))
      _ -> Error(remote.TimedOut)
    }
  }
  let rig = harness.live(script, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned_token(page)
  let updates = process.new_subject()

  let assert Ok(Nil) = page.subscribe(updates)

  // Three passes with no answer make the target lost.
  list.each([1, 2, 3], fn(_) {
    hub.tick(rig.hub)
    let _ = process.receive(updates, 300)
  })
  let _ = process.receive(updates, 300)

  assert hub.status(rig.hub).health == hub.Lost
  assert string.contains(
    rejected(page.submit(counters(token))),
    "pin not revalidated",
  )
  assert mentions(harness.trail(rig), "pins invalidated")
}

pub fn a_pin_can_be_released_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)
  let token = pinned_token(page)

  assert page.submit(seam.UnpinProcess(token)) == seam.Done("pin released")
  assert page.pins() == []
}

pub fn subscribing_needs_observe_and_is_audited_test() {
  let rig = harness.live(fixture.healthy, None)
  let nobody = harness.page(rig, "nobody", [])
  let updates = process.new_subject()

  assert nobody.subscribe(updates) |> result_is_error
  assert mentions(harness.trail(rig), "denied, missing capability observe")
  assert hub.status(rig.hub).subscribers == 0
}

fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

pub fn a_viewed_capture_has_no_agent_to_command_test() {
  let rig = harness.replay([fixture.observation(0, 1000)], None)
  let page = harness.page(rig, "viewer", [policy.Observe, policy.Export])

  assert string.contains(
    rejected(page.submit(seam.PinProcess("<0.1.0>"))),
    "no target",
  )
  assert list.length(page.latest()) == 1
}

pub fn a_checkpoint_and_a_save_write_a_verifiable_capture_test() {
  let dir = "build/service_test_out"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let facts = capture_facts()
  let rig =
    harness.replay(
      [fixture.observation(0, 1000), fixture.observation(1, 3000)],
      Some(service.Saver(directory: dir, facts:, cadence_ms: 2000)),
    )
  let page = harness.page(rig, "alice", harness.all)

  assert page.submit(seam.Checkpoint("before"))
    == seam.Done("checkpoint recorded")

  let assert seam.CaptureSaved(path) = page.submit(seam.SaveCapture)
  let assert Ok(loaded) = capture_file.read(path)

  assert loaded.digest == capture_file.DigestVerified
  assert list.any(loaded.capture.records, fn(record) {
    case record {
      capture.CheckpointRecord(capture.Checkpoint("before", ..)) -> True
      _ -> False
    }
  })
  assert list.any(loaded.capture.records, fn(record) {
    case record {
      capture.AuditRecord(_) -> True
      _ -> False
    }
  })
  let _ = simplifile.delete(path)
}

fn capture_facts() {
  import_facts()
}

import pickglass/capture_build

fn import_facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 1,
    boot: fixture.boot(),
    role: "test",
    workload: "",
    top_k: 10,
    deadline_ms: 1000,
    os_start: identity.UnreadableStart,
    clock: option.None,
  )
}

pub fn the_audit_page_reads_back_entries_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)
  let _ = pinned_token(page)
  let entries = page.audit(10)

  assert entries != []
  assert list.any(entries, fn(entry) {
    case entry {
      audit.Decision(policy.AuditEntry(command: "pin_process pid=<0.5.0>", ..)) ->
        True
      _ -> False
    }
  })
  let _ = identity.unknown_boot
}

pub fn a_stalled_agent_request_does_not_block_other_pages_test() {
  // The agent takes a second and a half to answer a pin of one process and
  // answers everything else at once.
  let rig =
    harness.live(
      fn(request) {
        case request {
          wire.AskPin("<0.9.0>") -> process.sleep(1500)
          _ -> Nil
        }

        fixture.healthy(request)
      },
      None,
    )
  let slow = harness.page(rig, "alice", harness.all)
  let other = harness.page(rig, "bob", harness.all)
  let done = process.new_subject()

  process.spawn(fn() {
    process.send(done, slow.submit(seam.PinProcess("<0.9.0>")))
  })

  // Let the slow request reach the agent, then read from another page. The
  // read must come back long before the stalled request does.
  process.sleep(200)

  let started = clock_ms()

  assert other.pins() == []
  assert clock_ms() - started < 500

  let assert Ok(seam.PinIssued(..)) = process.receive(done, 5000)

  // The finished request is recorded: the other page now sees the pin.
  assert list.length(other.pins()) == 1
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

fn clock_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

pub fn a_probe_is_recorded_with_the_duration_the_agent_ran_test() {
  // The agent cuts the probe to twelve seconds and says so in its reply.
  let rig =
    harness.live(
      fn(request) {
        case request {
          wire.AskStartCounters(..) -> Ok(wire.CountersStarted(7, 3, 12_000))
          other -> fixture.healthy(other)
        }
      },
      None,
    )
  let page = harness.page(rig, "alice", harness.all)
  let id = plan_id(page.submit(counters(pinned_token(page))))
  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))
  let assert [probe] = page.probes()

  assert probe.duration_ms == 12_000
}
