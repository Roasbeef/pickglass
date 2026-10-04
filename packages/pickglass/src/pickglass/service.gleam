//// The service: the one actor that decides, executes and records.
////
//// A page's `submit` closure sends its request here, with the principal the
//// socket was admitted with. The service turns the request into an intent
//// (`seam.intent`), asks the gate (`gate`), runs an authorized command
//// (`exec`) or answers it from the viewer's own data, and appends every
//// entry the gate returned to the audit log. Because one actor owns the gate
//// value, two confirms of one plan are processed one after the other and the
//// second finds nothing: the plan store's single-use rule needs no lock.
////
//// Commands run inside the service, so a slow agent delays the next request
//// by at most `exec.ask_deadline_ms`. The census and the other reads never
//// pass through here; the hub serves them from its ring.
////
//// The service watches the hub for `TargetLost`. When the target is gone it
//// marks every pin dead, so a later probe naming one is denied by the gate
//// before it reaches the link.
////
//// ## Flow
////
//// - `start` creates the actor; `page_for` builds the `Page` a principal's
////   socket receives.
//// - `Submit` runs `handle_request`: intent, gate, `execute`, reply.
//// - `Subscribe` authorizes the read and registers the subscriber with the
////   hub.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import pickglass/audit.{type Log}
import pickglass/capture_build
import pickglass/capture_file
import pickglass/exec
import pickglass/gate.{type Gate}
import pickglass/hub.{type Hub}
import pickglass/remote.{type Remote}
import pickglass/seam.{type Reply, type Request}
import pickglass/secret
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/policy.{type Command, type Principal}
import weft/actor

/// Where captures are saved and what their headers say.
pub type Saver {
  Saver(directory: String, facts: capture_build.Facts, cadence_ms: Int)
}

/// What the service is built from.
pub type Config {
  Config(
    /// The target, or `None` when a capture file is being viewed.
    remote: Option(Remote),
    hub: Hub,
    audit: Log,
    /// Wall-clock milliseconds.
    clock: fn() -> Int,
    mode: seam.Mode,
    /// `None` when saving is not offered.
    saver: Option(Saver),
  )
}

/// A handle to the service.
pub type Service {
  Service(subject: Subject(Message), hub: Hub, audit: Log, mode: seam.Mode)
}

/// What the actor receives.
pub opaque type Message {
  Submit(principal: Principal, request: Request, reply: Subject(Reply))
  Subscribe(
    principal: Principal,
    subscriber: Subject(hub.Update),
    reply: Subject(Result(Nil, String)),
  )
  Plans(
    principal: policy.PrincipalId,
    reply: Subject(List(#(String, policy.Plan))),
  )
  Pins(reply: Subject(List(seam.PinCard)))
  Checkpoints(reply: Subject(List(capture.Checkpoint)))
  TargetGone(hub.Update)
}

type State {
  State(
    config: Config,
    remote: Remote,
    gate: Gate,
    checkpoints: List(capture.Checkpoint),
  )
}

/// Start the service.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(service) = service.start(config)
/// ```
pub fn start(config: Config) -> Result(Service, String) {
  use boot <- result.try(case config.remote {
    Some(remote) -> Ok(remote.boot)
    None ->
      identity.boot_id("viewing")
      |> result.replace_error("the placeholder boot id is malformed")
  })

  let remote = option.unwrap(config.remote, remote.none(boot))
  let target = case config.remote {
    Some(_) -> gate.Attached
    None -> gate.Detached
  }
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      let watcher = process.new_subject()

      hub.watch(config.hub, watcher)

      actor.initialised(
        State(config:, remote:, gate: gate.new(boot, target), checkpoints: []),
      )
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(watcher, TargetGone),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)

  case actor.start(builder) {
    Ok(started) ->
      Ok(Service(
        subject: started.data,
        hub: config.hub,
        audit: config.audit,
        mode: config.mode,
      ))
    Error(_) -> Error("the service did not start")
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Submit(principal, request, reply) -> {
      let #(state, answer) = handle_request(state, principal, request)

      process.send(reply, answer)

      actor.continue(state)
    }

    Subscribe(principal, subscriber, reply) -> {
      let now = state.config.clock()
      let decision =
        gate.authorize(state.gate, principal, policy.ReadCensus(200), now)

      audit.append_all(state.config.audit, decision.entries)

      case decision.result {
        Ok(_) -> {
          hub.subscribe(state.config.hub, subscriber)
          process.send(reply, Ok(Nil))
        }
        Error(refusal) -> process.send(reply, Error(refusal_text(refusal)))
      }

      actor.continue(state)
    }

    Plans(principal, reply) -> {
      process.send(
        reply,
        gate.pending(state.gate, principal, state.config.clock()),
      )

      actor.continue(state)
    }

    Pins(reply) -> {
      process.send(reply, list.map(gate.pins(state.gate), pin_card))

      actor.continue(state)
    }

    Checkpoints(reply) -> {
      process.send(reply, list.reverse(state.checkpoints))

      actor.continue(state)
    }

    // The hub reported the target gone: every pin is dead from here on.
    TargetGone(hub.TargetLost(reason)) -> {
      audit.append(
        state.config.audit,
        audit.Host(state.config.clock(), audit.PinsInvalidated(reason)),
      )

      actor.continue(
        State(
          ..state,
          gate: gate.target_lost(state.gate, reason, state.config.clock()),
        ),
      )
    }
    TargetGone(hub.Observed(_)) -> actor.continue(state)
  }
}

fn pin_card(pin: gate.Pin) -> seam.PinCard {
  seam.PinCard(
    token: identity.pin_to_string(pin.token),
    pid_text: pin.pid_text,
    status: case pin.state {
      gate.Live -> seam.PinLive
      gate.Gone(reason:, ..) -> seam.PinGone(reason)
    },
    pinned_at_ms: pin.pinned_at_ms,
  )
}

fn refusal_text(refusal: gate.Refusal) -> String {
  case refusal {
    gate.Denied(denial) -> policy.denial_text(denial)
    gate.UnknownPlan ->
      "no such plan: it was already confirmed, cancelled or expired"
    gate.TooManyPlans -> "too many plans are pending; confirm or cancel one"
  }
}

// ---------------------------------------------------------------- requests

fn handle_request(
  state: State,
  principal: Principal,
  request: Request,
) -> #(State, Reply) {
  let now = state.config.clock()

  case seam.intent(request) {
    Error(reason) -> {
      audit.append(
        state.config.audit,
        audit.Host(now, audit.RequestMalformed(principal.id.text, reason)),
      )

      #(state, seam.Rejected(reason))
    }

    Ok(seam.Run(command, follow)) -> {
      let decision = gate.authorize(state.gate, principal, command, now)

      audit.append_all(state.config.audit, decision.entries)
      run_decision(state, decision, follow)
    }

    Ok(seam.Plan(command)) -> {
      let #(next, planned) =
        gate.plan(state.gate, principal, command, secret.token(16), now)

      audit.append_all(state.config.audit, planned.entries)

      case planned.result {
        Ok(#(id, plan)) -> #(
          State(..state, gate: next),
          seam.PlanReady(id, plan),
        )
        Error(refusal) -> #(state, seam.Rejected(refusal_text(refusal)))
      }
    }

    Ok(seam.Confirm(plan_id)) -> {
      let #(next, decision) = gate.confirm(state.gate, principal, plan_id, now)

      audit.append_all(state.config.audit, decision.entries)
      run_decision(State(..state, gate: next), decision, seam.NoFollow)
    }

    Ok(seam.Cancel(plan_id)) -> #(
      State(..state, gate: gate.cancel(state.gate, principal, plan_id)),
      seam.Done("plan cancelled"),
    )
  }
}

fn run_decision(
  state: State,
  decision: gate.Decision,
  follow: seam.Follow,
) -> #(State, Reply) {
  case decision.result {
    Error(refusal) -> #(state, seam.Rejected(refusal_text(refusal)))
    Ok(authorized) -> execute(state, authorized, follow)
  }
}

fn execute(
  state: State,
  authorized: policy.Authorized(Command),
  follow: seam.Follow,
) -> #(State, Reply) {
  let command = policy.authorized_command(authorized)
  let now = state.config.clock()

  case exec.run(state.remote, authorized) {
    exec.PinIssued(token, pid_text) -> #(
      State(..state, gate: gate.record_pin(state.gate, token, pid_text, now)),
      seam.PinIssued(identity.pin_to_string(token), pid_text),
    )

    exec.PinReleased -> #(
      State(..state, gate: release(state.gate, command)),
      seam.Done("pin released"),
    )

    exec.ProbeStarted(probe_id, matched, _) -> #(
      state,
      seam.ProbeStarted(int.to_string(probe_id), matched),
    )

    exec.ProbeStopped(snapshot) -> #(state, seam.ProbeStopped(snapshot))

    exec.DetachRequested -> #(state, seam.Done("detached"))

    exec.NotAnAgentCommand -> follow_up(state, follow, now)

    exec.Unsupported(reason) -> #(state, seam.Rejected(reason))

    exec.Failed(failure) -> #(
      invalidate_if_dead(state, command, failure, now),
      seam.Rejected(remote.describe(failure)),
    )

    exec.Unexpected(reply) -> #(
      state,
      seam.Rejected("the agent answered with something unexpected: " <> reply),
    )
  }
}

fn release(gate: Gate, command: Command) -> Gate {
  case command {
    policy.UnpinProcess(token) -> gate.release_pin(gate, token)
    _ -> gate
  }
}

// A refusal that says the pinned process is gone makes the command's pins
// dead, so the next attempt is denied before it reaches the agent.
fn invalidate_if_dead(
  state: State,
  command: Command,
  failure: remote.Failure,
  now: Int,
) -> State {
  case failure {
    remote.Refusal(code, _) if code == "stale_pin" || code == "target_gone" -> {
      audit.append(
        state.config.audit,
        audit.Host(now, audit.PinsInvalidated("the agent reported " <> code)),
      )

      State(
        ..state,
        gate: list.fold(
          policy.command_pins(command),
          state.gate,
          fn(gate, token) { gate.invalidate_pin(gate, token, code, now) },
        ),
      )
    }
    remote.Refusal(..) | remote.TimedOut -> state
  }
}

fn follow_up(state: State, follow: seam.Follow, now: Int) -> #(State, Reply) {
  case follow {
    seam.NoFollow -> #(state, seam.Done(""))
    seam.AddCheckpoint(name) -> #(
      State(..state, checkpoints: [
        capture.Checkpoint(name, 0, now),
        ..state.checkpoints
      ]),
      seam.Done("checkpoint recorded"),
    )
    seam.WriteCapture ->
      case save(state) {
        Ok(path) -> #(state, seam.CaptureSaved(path))
        Error(reason) -> #(state, seam.Rejected(reason))
      }
    seam.TailAudit(count) -> #(
      state,
      seam.AuditTail(audit.tail(state.config.audit, count)),
    )
  }
}

// The live window as a capture: the ring's observations, the checkpoints and
// the audit trail, written under the saver's directory.
fn save(state: State) -> Result(String, String) {
  use saver <- result.try(option.to_result(
    state.config.saver,
    "this viewer was started without a directory to save captures in",
  ))

  let id = "cap-" <> secret.token(9)
  let observations = list.reverse(hub.latest(state.config.hub))
  let cadence = case saver.cadence_ms > 0 {
    True -> measure.EveryMs(saver.cadence_ms)
    False -> measure.OneShot
  }

  use #(header, records) <- result.try(capture_build.assemble(
    saver.facts,
    id,
    observations,
    cadence,
    list.reverse(state.checkpoints),
    audit.tail(state.config.audit, audit.capacity),
  ))

  let path = saver.directory <> "/" <> id <> ".pgcap"

  capture_file.write(path, header, records)
  |> result.replace(path)
}

// -------------------------------------------------------------- the page

/// The `Page` a principal's socket hands its application. Every closure is
/// bound to `principal`, which the socket took from the session at admission.
///
/// ## Examples
///
/// ```gleam
/// let page = service.page_for(service, principal)
/// page.submit(seam.SaveCapture)
/// ```
pub fn page_for(service: Service, principal: Principal) -> seam.Page {
  seam.Page(
    principal: principal.id,
    grants: set.to_list(principal.grants),
    mode: service.mode,
    latest: fn() { hub.latest(service.hub) },
    subscribe: fn(subscriber) {
      process.call(service.subject, 5000, fn(reply) {
        Subscribe(principal, subscriber, reply)
      })
    },
    submit: fn(request) {
      process.call(service.subject, 30_000, fn(reply) {
        Submit(principal, request, reply)
      })
    },
    plans: fn() {
      process.call(service.subject, 5000, fn(reply) {
        Plans(principal.id, reply)
      })
    },
    checkpoints: fn() {
      process.call(service.subject, 5000, fn(reply) { Checkpoints(reply) })
    },
    audit: fn(count) {
      case
        process.call(service.subject, 30_000, fn(reply) {
          Submit(principal, seam.ReadAudit(count), reply)
        })
      {
        seam.AuditTail(entries) -> entries
        _ -> []
      }
    },
    pins: fn() {
      process.call(service.subject, 5000, fn(reply) { Pins(reply) })
    },
  )
}
