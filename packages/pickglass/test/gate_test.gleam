import fixture
import gleam/list
import gleam/option.{None}
import pickglass/audit
import pickglass/gate
import pickglass_core/policy
import qcheck

const now = 1000

fn alice() -> policy.Principal {
  fixture.principal("alice", [policy.Observe, policy.Profile, policy.Perturb])
}

fn probe(token: policy.PrincipalId) -> policy.Command {
  let _ = token

  policy.StartProbe(policy.ProbeSpec(
    kind: policy.Counters,
    targets: [fixture.pin_token(1)],
    modules: ["lists"],
    duration_ms: 10_000,
  ))
}

fn armed() -> gate.Gate {
  gate.record_pin(
    gate.new(fixture.boot(), gate.Attached),
    fixture.pin_token(1),
    "<0.5.0>",
    0,
  )
}

fn planned(g: gate.Gate, id: String) -> gate.Gate {
  let #(g, outcome) = gate.plan(g, alice(), probe(alice().id), id, now)

  assert outcome.result != Error(gate.UnknownPlan)

  g
}

fn allowed(decision: gate.Decision) -> Bool {
  case decision.result {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn a_plan_confirms_once_test() {
  let g = planned(armed(), "p1")
  let #(g, first) = gate.confirm(g, alice(), "p1", now + 1)
  let #(_, second) = gate.confirm(g, alice(), "p1", now + 2)

  assert allowed(first)
  assert second.result == Error(gate.UnknownPlan)
  assert second.entries == [audit.Host(now + 2, audit.PlanUnknown("alice"))]
}

// However many times a plan is confirmed, at most one confirm is allowed,
// and every attempt leaves an entry.
pub fn at_most_one_confirm_succeeds_test() {
  use attempts <- qcheck.given(qcheck.bounded_int(1, 8))

  let #(_, decisions) =
    list.fold(
      fixture.numbers(attempts),
      #(planned(armed(), "p"), []),
      fn(state, n) {
        let #(g, decisions) = state
        let #(g, decision) = gate.confirm(g, alice(), "p", now + n)

        #(g, [decision, ..decisions])
      },
    )

  assert list.count(decisions, allowed) == 1
  assert list.all(decisions, fn(d) { d.entries != [] })
}

pub fn an_expired_plan_is_consumed_by_the_attempt_test() {
  let g = planned(armed(), "p1")
  let late = now + policy.plan_ttl_ms + 1
  let #(g, expired) = gate.confirm(g, alice(), "p1", late)
  let #(_, again) = gate.confirm(g, alice(), "p1", late)

  assert expired.result == Error(gate.Denied(policy.PlanExpired))
  assert again.result == Error(gate.UnknownPlan)
}

pub fn another_principal_leaves_the_plan_to_its_owner_test() {
  let bob = fixture.principal("bob", policy.all_capabilities)
  let g = planned(armed(), "p1")
  let #(g, refused) = gate.confirm(g, bob, "p1", now + 1)
  let #(_, owner) = gate.confirm(g, alice(), "p1", now + 2)

  assert refused.result == Error(gate.Denied(policy.WrongPrincipal))
  assert allowed(owner)
}

pub fn cancel_removes_only_the_owners_plan_test() {
  let bob = fixture.principal("bob", policy.all_capabilities)
  let g = planned(armed(), "p1")
  let g = gate.cancel(g, bob, "p1")
  let #(g, still) = gate.confirm(g, alice(), "p1", now + 1)

  assert allowed(still)

  let g = planned(g, "p2")
  let g = gate.cancel(g, alice(), "p2")
  let #(_, gone) = gate.confirm(g, alice(), "p2", now + 1)

  assert gone.result == Error(gate.UnknownPlan)
}

pub fn pending_plans_are_per_principal_test() {
  let g = planned(armed(), "p1")

  assert list.length(gate.pending(g, alice().id, now)) == 1
  assert gate.pending(g, policy.PrincipalId("bob"), now) == []
  assert gate.pending(g, alice().id, now + policy.plan_ttl_ms + 1) == []
}

pub fn the_plan_store_is_bounded_test() {
  let full =
    list.fold(fixture.numbers(32), armed(), fn(g, n) {
      planned(g, "plan" <> string_of(n))
    })
  let #(_, outcome) = gate.plan(full, alice(), probe(alice().id), "extra", now)

  assert outcome.result == Error(gate.TooManyPlans)
}

fn string_of(n: Int) -> String {
  case n {
    _ if n < 10 -> "0" <> digit(n)
    _ -> digit(n / 10) <> digit(n % 10)
  }
}

fn digit(n: Int) -> String {
  case n {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    _ -> "9"
  }
}

pub fn a_pin_the_agent_never_issued_is_not_revalidated_test() {
  let g = gate.new(fixture.boot(), gate.Attached)
  let #(_, outcome) = gate.plan(g, alice(), probe(alice().id), "p", now)

  assert outcome.result
    == Error(gate.Denied(policy.TargetNotRevalidated(fixture.pin_token(1))))
}

pub fn a_detached_gate_revalidates_nothing_test() {
  let g =
    gate.record_pin(
      gate.new(fixture.boot(), gate.Detached),
      fixture.pin_token(1),
      "<0.5.0>",
      0,
    )
  let #(_, outcome) = gate.plan(g, alice(), probe(alice().id), "p", now)

  assert outcome.result
    == Error(gate.Denied(policy.TargetNotRevalidated(fixture.pin_token(1))))
}

pub fn a_token_of_another_boot_is_not_recorded_test() {
  let assert Ok(other) = pickglass_core_identity_boot("otherboot")
  let assert Ok(token) = pickglass_core_identity_pin(other, 1)
  let g =
    gate.record_pin(
      gate.new(fixture.boot(), gate.Attached),
      token,
      "<0.1.0>",
      0,
    )

  assert gate.pins(g) == []
}

import pickglass_core/identity

fn pickglass_core_identity_boot(text: String) {
  identity.boot_id(text)
}

fn pickglass_core_identity_pin(boot, serial) {
  identity.pin(boot, serial)
}

pub fn losing_the_target_marks_pins_gone_and_denies_test() {
  let g = gate.target_lost(armed(), "gone", now)
  let #(_, outcome) = gate.plan(g, alice(), probe(alice().id), "p", now)

  assert outcome.result
    == Error(gate.Denied(policy.TargetNotRevalidated(fixture.pin_token(1))))

  let assert [pin] = gate.pins(g)

  assert pin.state == gate.Gone("gone", now)
  assert gate.target(g) == gate.Lost("gone")
  let _ = None
}

pub fn every_decision_returns_an_entry_test() {
  let g = armed()
  let direct = gate.authorize(g, alice(), policy.ReadOwners, now)
  let denied =
    gate.authorize(g, fixture.principal("x", []), policy.ReadOwners, now)
  let needs_plan = gate.authorize(g, alice(), probe(alice().id), now)

  assert list.length(direct.entries) == 1
  assert list.length(denied.entries) == 1
  assert needs_plan.result == Error(gate.Denied(policy.PlanRequired))
  assert list.length(needs_plan.entries) == 1
}
