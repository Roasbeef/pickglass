//// The authority gate: the only place a command is admitted.
////
//// Every action a page can ask for reaches the target through `policy`.
//// `policy.authorize` admits the direct commands, and `policy.plan` then
//// `policy.confirm` admit probes and targeted GC. Both return an opaque
//// `Authorized(Command)` that nothing but `policy` can construct, and the
//// executor (`exec`) accepts nothing else. This module is the state those
//// decisions need and the core does not keep:
////
//// - **The pin table.** `policy` demands a `LivePin` for any command that
////   names a target, and `identity.check_pin` hands one out for a token of
////   the current agent boot. A token whose text has the right boot id but
////   that the agent never issued must still be refused, so the gate holds
////   the tokens the agent really issued and builds a `LivePin` only for a
////   token in that table whose pin is still live. A pin whose process died
////   or whose target went away stays in the table as evidence and as a
////   refusal.
//// - **The plan store.** Plans are single-use here (`plans`). A confirm
////   removes the plan when the confirming principal is the one that
////   planned, whatever the outcome, so an expired, changed or replayed
////   confirm finds nothing. A confirm by another principal leaves the plan
////   for its owner.
//// - **The audit trail.** Every decision returns the entries to record,
////   the `policy` entry plus a host entry where `policy` has none to give
////   (a confirm that names no plan).
////
//// Everything here is a pure function of a `Gate` value and the clock the
//// caller passes in, so the service actor owns the value and the property
//// that no plan confirms twice can be tested without a process.
////
//// ## Flow
////
//// - `authorize` for direct commands.
//// - `plan`, then `confirm` or `cancel`, for probes and targeted GC.
//// - `record_pin`, `release_pin`, `invalidate_pin` and `target_lost` keep
////   the pin table in step with what the agent reports.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import pickglass/audit
import pickglass/plans
import pickglass_core/identity.{type BootId, type LivePin, type PinToken}
import pickglass_core/policy.{
  type Authorized, type Command, type Denial, type Estimate, type Plan,
  type Principal,
}

/// Whether the viewer has a target to act on.
pub type Target {
  /// An agent is attached and answering.
  Attached

  /// A capture file is being viewed. There is no target, so no command
  /// names a pin that can be revalidated.
  Detached

  /// The target was attached and has been lost.
  Lost(reason: String)
}

/// Where a pin stands.
pub type PinState {
  /// The agent issued it and has not reported it dead.
  Live

  /// The process died or the target went away. The pin stays as evidence.
  Gone(reason: String, at_ms: Int)
}

/// One pin the agent issued.
pub type Pin {
  Pin(token: PinToken, pid_text: String, state: PinState, pinned_at_ms: Int)
}

/// Why a gate refused, beyond what `policy` denies.
pub type Refusal {
  /// `policy` denied it; the entry says why.
  Denied(Denial)

  /// The confirm named a plan that does not exist, was already confirmed,
  /// or was swept.
  UnknownPlan

  /// `plans.capacity` plans are already pending.
  TooManyPlans
}

/// A direct decision and the entries to record.
pub type Decision {
  Decision(
    result: Result(Authorized(Command), Refusal),
    entries: List(audit.Entry),
  )
}

/// A planning decision and the entries to record. A plan is returned with
/// the id the page holds.
pub type Planned {
  Planned(result: Result(#(String, Plan), Refusal), entries: List(audit.Entry))
}

/// The gate's state.
pub opaque type Gate {
  Gate(
    boot: BootId,
    target: Target,
    pins: Dict(String, Pin),
    plans: plans.Store,
  )
}

/// A gate for an attach whose agent has this boot id.
///
/// ## Examples
///
/// ```gleam
/// gate.new(boot, gate.Attached)
/// ```
pub fn new(boot: BootId, target: Target) -> Gate {
  Gate(boot:, target:, pins: dict.new(), plans: plans.new())
}

/// The estimate the operator is shown for a command, and the one
/// `policy.confirm` recomputes to detect a plan whose scope moved. It is the
/// viewer's own bound: the agent has no estimate request. A counters probe
/// is bounded by the agent's event budget, and a targeted GC is one event.
///
/// ## Examples
///
/// ```gleam
/// gate.estimate_for(policy.TargetedGc(token))
/// // -> Estimate(events_low: 1, events_high: 1, bytes_high: 0, wall_ms: 50)
/// ```
pub fn estimate_for(command: Command) -> Estimate {
  case command {
    policy.StartProbe(spec:) -> {
      let seconds = int.max(1, spec.duration_ms / 1000)
      let targets = list.length(spec.targets)
      let events = int.min(200_000, seconds * 1000 * targets)

      policy.Estimate(
        events_low: 0,
        events_high: events,
        bytes_high: events * 128,
        wall_ms: spec.duration_ms,
      )
    }
    policy.TargetedGc(_) ->
      policy.Estimate(events_low: 1, events_high: 1, bytes_high: 0, wall_ms: 50)

    policy.ReadCensus(_)
    | policy.ReadOwners
    | policy.ReadMemory
    | policy.ReadSupervision
    | policy.ReadAudit(_)
    | policy.PinProcess(_)
    | policy.UnpinProcess(_)
    | policy.ReadProcess(_)
    | policy.StopProbe(_)
    | policy.SelfMeasure(_)
    | policy.ExportCapture(..)
    | policy.Detach ->
      policy.Estimate(events_low: 0, events_high: 0, bytes_high: 0, wall_ms: 0)
  }
}

// The pins of a command that the agent issued this boot and that are still
// live, as the proofs `policy` demands. A token the table does not hold, or
// holds as gone, yields no proof, and `policy` then denies the command with
// `TargetNotRevalidated`.
fn revalidated(gate: Gate, command: Command) -> List(LivePin) {
  case gate.target {
    Attached ->
      policy.command_pins(command)
      |> list.filter_map(fn(token) {
        case dict.get(gate.pins, identity.pin_to_string(token)) {
          Ok(Pin(state: Live, ..)) ->
            identity.check_pin(token, gate.boot) |> result.replace_error(Nil)
          Ok(Pin(state: Gone(..), ..)) | Error(Nil) -> Error(Nil)
        }
      })
    Detached | Lost(_) -> []
  }
}

fn refusal_of(audited: policy.Audited(a)) -> Result(a, Refusal) {
  result.map_error(audited.result, Denied)
}

/// Admit a direct command.
///
/// ## Examples
///
/// ```gleam
/// let decision = gate.authorize(gate, principal, policy.ReadOwners, now)
/// ```
pub fn authorize(
  gate: Gate,
  principal: Principal,
  command: Command,
  now_ms: Int,
) -> Decision {
  let audited =
    policy.authorize(principal, command, revalidated(gate, command), now_ms)

  Decision(result: refusal_of(audited), entries: [audit.Decision(audited.entry)])
}

/// Plan a probe or targeted GC and hold the plan under `plan_id`, which the
/// caller generated.
///
/// ## Examples
///
/// ```gleam
/// let #(gate, planned) = gate.plan(gate, principal, command, "id", now)
/// ```
pub fn plan(
  gate: Gate,
  principal: Principal,
  command: Command,
  plan_id: String,
  now_ms: Int,
) -> #(Gate, Planned) {
  let audited =
    policy.plan(
      principal,
      command,
      revalidated(gate, command),
      estimate_for(command),
      now_ms,
    )
  let entries = [audit.Decision(audited.entry)]

  case audited.result {
    Error(denial) -> #(gate, Planned(Error(Denied(denial)), entries))
    Ok(plan) ->
      case plans.put(gate.plans, plan_id, plan, now_ms) {
        Error(Nil) -> #(gate, Planned(Error(TooManyPlans), entries))
        Ok(store) -> #(
          Gate(..gate, plans: store),
          Planned(Ok(#(plan_id, plan)), entries),
        )
      }
  }
}

/// Confirm a plan by id.
///
/// The plan is removed from the store when the confirming principal is the
/// one that planned it, whatever `policy` decides, so a plan is confirmed at
/// most once and an expired or changed one cannot be retried. A confirm by
/// another principal is denied by `policy` and leaves the plan for its
/// owner. An id that names no plan is `UnknownPlan`, which is what a
/// replayed confirm gets.
///
/// ## Examples
///
/// ```gleam
/// let #(gate, decision) = gate.confirm(gate, principal, "id", now)
/// let #(_, replay) = gate.confirm(gate, principal, "id", now)
/// // replay.result == Error(gate.UnknownPlan)
/// ```
pub fn confirm(
  gate: Gate,
  principal: Principal,
  plan_id: String,
  now_ms: Int,
) -> #(Gate, Decision) {
  case plans.peek(gate.plans, plan_id) {
    Error(Nil) -> #(
      gate,
      Decision(Error(UnknownPlan), [
        audit.Host(now_ms, audit.PlanUnknown(principal.id.text)),
      ]),
    )
    Ok(plan) -> {
      let command = policy.plan_command(plan)
      let audited =
        policy.confirm(
          plan,
          principal,
          revalidated(gate, command),
          estimate_for(command),
          now_ms,
        )
      let remaining = case policy.plan_principal(plan) == principal.id {
        True -> remove_plan(gate.plans, plan_id)
        False -> gate.plans
      }

      #(
        Gate(..gate, plans: remaining),
        Decision(refusal_of(audited), [audit.Decision(audited.entry)]),
      )
    }
  }
}

/// Withdraw a plan its owner no longer wants. Another principal's plan is
/// left alone.
pub fn cancel(gate: Gate, principal: Principal, plan_id: String) -> Gate {
  case plans.peek(gate.plans, plan_id) {
    Ok(plan) ->
      case policy.plan_principal(plan) == principal.id {
        True -> Gate(..gate, plans: remove_plan(gate.plans, plan_id))
        False -> gate
      }
    Error(Nil) -> gate
  }
}

fn remove_plan(store: plans.Store, plan_id: String) -> plans.Store {
  case plans.take(store, plan_id) {
    Ok(#(store, _)) -> store
    Error(Nil) -> store
  }
}

/// The plans a principal has pending, as `(id, plan)`.
pub fn pending(
  gate: Gate,
  principal: policy.PrincipalId,
  now_ms: Int,
) -> List(#(String, Plan)) {
  plans.pending(gate.plans, principal, now_ms)
}

/// Record a pin the agent issued. A token of another boot is ignored: it
/// cannot have come from this agent.
pub fn record_pin(
  gate: Gate,
  token: PinToken,
  pid_text: String,
  now_ms: Int,
) -> Gate {
  case identity.pin_boot(token) == gate.boot {
    False -> gate
    True ->
      Gate(
        ..gate,
        pins: dict.insert(
          gate.pins,
          identity.pin_to_string(token),
          Pin(token:, pid_text:, state: Live, pinned_at_ms: now_ms),
        ),
      )
  }
}

/// Forget a pin the operator released.
pub fn release_pin(gate: Gate, token: PinToken) -> Gate {
  Gate(..gate, pins: dict.delete(gate.pins, identity.pin_to_string(token)))
}

/// Mark one pin gone, keeping it as evidence. This is what a refusal such as
/// `stale_pin` from the agent means.
pub fn invalidate_pin(
  gate: Gate,
  token: PinToken,
  reason: String,
  now_ms: Int,
) -> Gate {
  Gate(
    ..gate,
    pins: dict.upsert(gate.pins, identity.pin_to_string(token), fn(held) {
      case held {
        Some(pin) -> Pin(..pin, state: Gone(reason:, at_ms: now_ms))
        None ->
          Pin(
            token:,
            pid_text: "",
            state: Gone(reason:, at_ms: now_ms),
            pinned_at_ms: now_ms,
          )
      }
    }),
  )
}

/// The target went away: every live pin is gone and the gate is `Lost`.
pub fn target_lost(gate: Gate, reason: String, now_ms: Int) -> Gate {
  Gate(
    ..gate,
    target: Lost(reason),
    pins: dict.map_values(gate.pins, fn(_, pin) {
      case pin.state {
        Live -> Pin(..pin, state: Gone(reason:, at_ms: now_ms))
        Gone(..) -> pin
      }
    }),
  )
}

/// The pins, oldest first.
pub fn pins(gate: Gate) -> List(Pin) {
  dict.values(gate.pins)
  |> list.sort(fn(a, b) { int.compare(a.pinned_at_ms, b.pinned_at_ms) })
}

/// Whether the gate has a target.
pub fn target(gate: Gate) -> Target {
  gate.target
}

/// The agent boot id the gate revalidates pins against.
pub fn boot(gate: Gate) -> BootId {
  gate.boot
}
