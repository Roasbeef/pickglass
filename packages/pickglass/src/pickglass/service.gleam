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
//// The service never waits on the agent. A command is decided here and then
//// run by the process that submitted it (the page's feeder), which blocks
//// only itself; the outcome comes back to the service as a second message
//// that applies it to the state. A running probe is polled by a weft task the
//// service starts and collects, in the manner of the hub's passes. So a stall
//// in the agent leaves every other page's reads, which are quick calls to
//// this actor, unaffected. The census and the other reads of the target never
//// pass through here; the hub serves them from its ring.
////
//// A one-click profile is the one request that is several commands. The
//// service composes it (`profile`): the pins the profile needs are taken one
//// command at a time through the gate, the stack probe is planned over them,
//// and the plan waits for Confirm like any other. What it pinned is recorded
//// as `Held` against the plan, and released when the plan is cancelled or
//// lapses, when the probe fails to start, and when the probe ends, unless the
//// operator had pinned the process already.
////
//// The service watches the hub for `TargetLost`. When the target is gone it
//// marks every pin dead, so a later probe naming one is denied by the gate
//// before it reaches the link, and closes every running probe as lost.
////
//// The service also keeps what the viewer must not lose when the agent
//// forgets it. A probe the agent accepted is recorded (`probe_book`); once a
//// second the service asks the agent whether each running probe has ended,
//// and when one has, takes its result into a profile before the agent
//// discards it. Checkpoints are kept with a copy of the observation they are
//// compared against (`marks`), exports wait here as one-time downloads
//// (`downloads`), and the capture files of the save directory are listed and
//// read here so the compare page can offer them.
////
//// ## Flow
////
//// - `start` creates the actor; `page_for` builds the `Page` a principal's
////   socket receives.
//// - `Decide` runs `handle_request`: intent, gate, and either an answer or
////   an authorized command for the submitter to run.
//// - `Apply` takes the outcome of that command into the state (`apply`).
//// - `Poll` starts a weft run over the running probes; `Polled` applies
////   what it found.
//// - `Subscribe` authorizes the read and registers the subscriber with the
////   hub.
//// - `profile` composes a one-click profile in the submitter's process, and
////   `Hold`, `Claim` and `sweep_held` keep what it pinned until it is done.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import pickglass/audit.{type Log}
import pickglass/capture_build
import pickglass/capture_file
import pickglass/downloads
import pickglass/exec
import pickglass/gate.{type Gate}
import pickglass/hub.{type Hub}
import pickglass/marks.{type Mark}
import pickglass/probe_book.{type ProbeRecord}
import pickglass/remote.{type Remote}
import pickglass/seam.{type Reply, type Request}
import pickglass/secret
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/policy.{type Command, type Principal}
import pickglass_core/wire
import simplifile
import weft
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
    /// The checkpoints a replayed capture already holds, oldest first.
    marks: List(Mark),
    /// The probes a replayed capture already holds, newest first.
    probes: List(ProbeRecord),
  )
}

/// How often the service asks the agent whether a running probe has ended,
/// in milliseconds.
pub const poll_ms = 1000

/// A handle to the service.
pub type Service {
  Service(
    subject: Subject(Message),
    hub: Hub,
    audit: Log,
    mode: seam.Mode,
    /// The agent link, which a submitter's process runs its command on.
    remote: Remote,
  )
}

/// What deciding a request produced.
pub opaque type Decided {
  /// The service answered without the agent.
  Answered(Reply)

  /// The request is an authorized command. The submitter runs it, then
  /// sends the outcome back with `Apply`.
  Execute(
    authorized: policy.Authorized(Command),
    follow: seam.Follow,
    /// Which kind of probe an id names, as of the decision.
    kind_of: fn(String) -> Option(policy.ProbeKind),
    /// The plan a confirm acted on, so the outcome can be tied to what a
    /// profile pinned for it.
    plan_id: Option(String),
  )
}

/// Where a one-click profile stands, which says when its pins are released.
pub type Stage {
  /// The plan is waiting for Confirm. The pins are released when the plan is
  /// cancelled, replaced or lapses.
  Planned

  /// The plan was confirmed and the agent has not yet answered the start.
  Starting

  /// The probe is running. The pins are released when it ends.
  Sampling(probe_id: String)
}

/// What a one-click profile holds on the target: the pins it took for itself
/// (never one the operator had already pinned), the processes it chose and
/// how, and what the plan was for.
pub type Held {
  Held(
    plan_id: String,
    principal: Principal,
    /// Pin tokens as text, in the order they were taken.
    taken: List(String),
    /// Every process the profile chose, for planning it again.
    pids: List(String),
    chosen: String,
    duration_ms: Int,
    method: seam.ProfileMethod,
    stage: Stage,
  )
}

/// Which pending profile plans a claim takes.
pub type Which {
  /// Every pending profile plan of the principal.
  AnyPlan

  /// The one with this plan id.
  ThisPlan(plan_id: String)
}

/// What the actor receives.
pub opaque type Message {
  Decide(principal: Principal, request: Request, reply: Subject(Decided))
  Apply(
    authorized: policy.Authorized(Command),
    follow: seam.Follow,
    plan_id: Option(String),
    outcome: exec.Outcome,
    reply: Subject(Reply),
  )
  Hold(held: Held, reply: Subject(Nil))
  Claim(principal: policy.PrincipalId, which: Which, reply: Subject(List(Held)))
  Notes(principal: policy.PrincipalId, reply: Subject(List(seam.ProfileNote)))
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
  Checkpoints(reply: Subject(List(Mark)))
  Probes(reply: Subject(List(ProbeRecord)))
  Results(reply: Subject(List(seam.ProcessResult)))
  Captures(principal: Principal, reply: Subject(List(String)))
  ReadCapture(
    principal: Principal,
    name: String,
    reply: Subject(Result(capture_file.Loaded, String)),
  )
  TakeDownload(
    ticket: String,
    reply: Subject(Result(downloads.Download, downloads.Refusal)),
  )
  Poll
  Polled(weft.Pulled(#(String, exec.Poll), String))
  Released(weft.Pulled(#(policy.Authorized(Command), exec.Outcome), String))
  TargetGone(hub.Update)
}

type State {
  State(
    config: Config,
    remote: Remote,
    gate: Gate,
    /// Checkpoints with their baselines, newest first.
    marks: List(Mark),
    /// Probes, newest first.
    probes: List(ProbeRecord),
    /// Collections and self-measures, newest first, at most `max_results`.
    results: List(seam.ProcessResult),
    downloads: downloads.Registry,
    sink: Subject(weft.Pulled(#(String, exec.Poll), String)),
    polling: Polling,
    /// What one-click profiles hold on the target, newest first.
    held: List(Held),
    /// Where the outcomes of the pin releases arrive.
    release_sink: Subject(
      weft.Pulled(#(policy.Authorized(Command), exec.Outcome), String),
    ),
  )
}

// Whether a weft run over the running probes is in flight. A tick that finds
// one running does nothing, so a slow agent is asked once, not once a second.
type Polling {
  PollIdle
  PollRunning
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
      let sink = process.new_subject()
      let release_sink = process.new_subject()

      hub.watch(config.hub, watcher)

      actor.initialised(State(
        config:,
        remote:,
        gate: gate.new(boot, target),
        marks: list.reverse(config.marks),
        probes: config.probes,
        results: [],
        downloads: downloads.new(),
        sink:,
        polling: PollIdle,
        held: [],
        release_sink:,
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(watcher, TargetGone)
        |> process.select_map(sink, Polled)
        |> process.select_map(release_sink, Released),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: poll_ms, sending: Poll)

  case actor.start(builder) {
    Ok(started) ->
      Ok(Service(
        subject: started.data,
        hub: config.hub,
        audit: config.audit,
        mode: config.mode,
        remote:,
      ))
    Error(_) -> Error("the service did not start")
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Decide(principal, request, reply) -> {
      let #(state, decided) = handle_request(state, principal, request)

      process.send(reply, decided)

      actor.continue(state)
    }

    // The submitter ran the command; its outcome changes the state here, in
    // the one process that owns the gate and the records.
    Apply(authorized, follow, plan_id, outcome, reply) -> {
      let #(state, answer) = apply(state, authorized, follow, outcome)

      process.send(reply, answer)

      actor.continue(settle(state, plan_id, outcome))
    }

    Hold(held, reply) -> {
      process.send(reply, Nil)

      actor.continue(State(..state, held: [held, ..state.held]))
    }

    // A claim hands the submitter the pending profile plans it asked for and
    // cancels their plans, so the pins they took pass to the plan that
    // replaces them and are not released in between.
    Claim(principal, which, reply) -> {
      let #(claimed, rest) =
        list.partition(state.held, fn(held) {
          held.principal.id == principal
          && held.stage == Planned
          && claims(which, held)
        })

      process.send(reply, claimed)

      actor.continue(
        State(
          ..state,
          held: rest,
          gate: list.fold(claimed, state.gate, fn(current, held) {
            gate.cancel(current, held.principal, held.plan_id)
          }),
        ),
      )
    }

    Notes(principal, reply) -> {
      process.send(
        reply,
        list.filter_map(state.held, fn(held) {
          case held.principal.id == principal, held.stage {
            True, Planned ->
              Ok(seam.ProfileNote(
                plan_id: held.plan_id,
                chosen: held.chosen,
                duration_ms: held.duration_ms,
                method: held.method,
                processes: list.length(held.pids),
              ))
            _, _ -> Error(Nil)
          }
        }),
      )

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
      process.send(reply, list.reverse(state.marks))

      actor.continue(state)
    }

    Results(reply) -> {
      process.send(reply, state.results)

      actor.continue(state)
    }

    Probes(reply) -> {
      process.send(reply, state.probes)

      actor.continue(state)
    }

    Captures(principal, reply) -> {
      process.send(reply, case observe_allowed(state, principal) {
        True -> capture_names(state)
        False -> []
      })

      actor.continue(state)
    }

    ReadCapture(principal, name, reply) -> {
      process.send(reply, case observe_allowed(state, principal) {
        True -> read_capture(state, name)
        False -> Error("this principal may not observe")
      })

      actor.continue(state)
    }

    TakeDownload(ticket, reply) -> {
      let #(registry, outcome) =
        downloads.take(state.downloads, ticket, state.config.clock())

      process.send(reply, outcome)

      actor.continue(State(..state, downloads: registry))
    }

    Poll -> actor.continue(poll_probes(sweep_held(state)))

    // A pin the service released for a finished profile. The outcome is what
    // an operator's own release would have produced, so it is applied the
    // same way; there is no submitter waiting on the answer.
    Released(weft.PulledOutcome(weft.Completed(_, #(authorized, outcome)))) -> {
      let #(state, _) = apply(state, authorized, seam.NoFollow, outcome)

      actor.continue(state)
    }

    Released(_) -> actor.continue(state)

    Polled(pulled) -> actor.continue(finish_poll(state, pulled))

    // The hub reported the target gone.
    TargetGone(hub.TargetLost(reason)) ->
      actor.continue(lose_target(state, reason))
    TargetGone(hub.Observed(_)) -> actor.continue(state)
  }
}

// Every pin is dead from here on, and so is every probe the agent was
// running: a later command naming a pin is denied by the gate before it
// reaches the link.
fn lose_target(state: State, reason: String) -> State {
  let now = state.config.clock()

  audit.append(
    state.config.audit,
    audit.Host(now, audit.PinsInvalidated(reason)),
  )

  State(
    ..state,
    held: [],
    gate: gate.target_lost(state.gate, reason, now),
    probes: list.map(state.probes, fn(probe) {
      case probe_book.is_running(probe) {
        True -> probe_book.finish_lost(probe, reason, now)
        False -> probe
      }
    }),
  )
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
) -> #(State, Decided) {
  let now = state.config.clock()

  case seam.intent(request) {
    Error(reason) -> {
      audit.append(
        state.config.audit,
        audit.Host(now, audit.RequestMalformed(principal.id.text, reason)),
      )

      #(state, Answered(seam.Rejected(reason)))
    }

    Ok(seam.Run(command, follow)) -> {
      let decision = gate.authorize(state.gate, principal, command, now)

      audit.append_all(state.config.audit, decision.entries)
      run_decision(state, decision, follow, None)
    }

    Ok(seam.Plan(command)) -> {
      let #(next, planned) =
        gate.plan(state.gate, principal, command, secret.token(16), now)

      audit.append_all(state.config.audit, planned.entries)

      case planned.result {
        Ok(#(id, plan)) -> #(
          State(..state, gate: next),
          Answered(seam.PlanReady(id, plan)),
        )
        Error(refusal) -> #(
          state,
          Answered(seam.Rejected(refusal_text(refusal))),
        )
      }
    }

    Ok(seam.Confirm(plan_id)) -> {
      let #(next, decision) = gate.confirm(state.gate, principal, plan_id, now)

      audit.append_all(state.config.audit, decision.entries)

      // A confirmed plan consumes itself, so a profile that was confirmed
      // must stop looking like one that lapsed.
      let held = case decision.result {
        Ok(_) -> advance(state.held, plan_id)
        Error(_) -> state.held
      }

      run_decision(
        State(..state, gate: next, held:),
        decision,
        seam.NoFollow,
        Some(plan_id),
      )
    }

    Ok(seam.Cancel(plan_id)) -> #(
      State(..state, gate: gate.cancel(state.gate, principal, plan_id)),
      Answered(seam.Done("plan cancelled")),
    )
  }
}

fn run_decision(
  state: State,
  decision: gate.Decision,
  follow: seam.Follow,
  plan_id: Option(String),
) -> #(State, Decided) {
  case decision.result {
    Error(refusal) -> #(state, Answered(seam.Rejected(refusal_text(refusal))))
    Ok(authorized) -> #(
      state,
      Execute(
        authorized,
        follow,
        fn(id) { kind_of_probe(state.probes, id) },
        plan_id,
      ),
    )
  }
}

// What a command's outcome does to the viewer's own records. The command ran
// in the submitter's process; this runs in the service, so two outcomes are
// applied one after the other.
fn apply(
  state: State,
  authorized: policy.Authorized(Command),
  follow: seam.Follow,
  outcome: exec.Outcome,
) -> #(State, Reply) {
  let command = policy.authorized_command(authorized)
  let now = state.config.clock()

  case outcome {
    exec.PinIssued(token, pid_text) -> #(
      State(..state, gate: gate.record_pin(state.gate, token, pid_text, now)),
      seam.PinIssued(identity.pin_to_string(token), pid_text),
    )

    exec.PinReleased -> #(
      State(..state, gate: release(state.gate, command)),
      seam.Done("pin released"),
    )

    exec.ProbeStarted(probe_id, matched, deadline_ms) -> #(
      keep_probes(
        State(
          ..state,
          probes: record_started(
            state.probes,
            command,
            probe_id,
            matched,
            deadline_ms,
            now,
          ),
        ),
      ),
      seam.ProbeStarted(int.to_string(probe_id), matched),
    )

    exec.ProbeStopped(snapshot) -> #(
      State(..state, probes: close_probe(state.probes, snapshot, now)),
      seam.ProbeStopped(snapshot),
    )

    exec.Collected(snapshot) -> #(
      remember(state, seam.GcRan(snapshot, now)),
      seam.Collected(snapshot),
    )
    exec.Measured(snapshot) -> #(
      remember(state, seam.SelfMeasured(snapshot, now)),
      seam.Measured(snapshot),
    )
    exec.ProcessRead(detail) -> #(state, seam.ProcessRead(detail))
    exec.SupervisionRead(snapshot) -> #(state, seam.SupervisionRead(snapshot))

    exec.StacksStopped(snapshot) -> #(
      State(..state, probes: close_stacks(state.probes, snapshot, now)),
      seam.StacksStopped(snapshot),
    )

    exec.CalltraceStopped(snapshot) -> #(
      State(..state, probes: close_calltrace(state.probes, snapshot, now)),
      seam.CalltraceStopped(snapshot),
    )

    exec.EventsStopped(snapshot) -> #(
      State(..state, probes: close_events(state.probes, snapshot, now)),
      seam.EventsStopped(snapshot),
    )

    // The agent is told to go, and nothing the viewer holds is valid against
    // it from here. Waiting for the hub to notice would leave three passes
    // in which commands pass the gate and each wait out the agent's deadline.
    exec.DetachRequested -> #(
      lose_target(state, "detached"),
      seam.Done("detached"),
    )

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
    seam.AddCheckpoint(name) -> {
      let newest =
        list.first(hub.latest(state.config.hub)) |> option.from_result
      let checkpoint = capture.Checkpoint(name, agent_ns(state, now), now)

      let all = [marks.take(checkpoint, newest), ..state.marks]

      note_dropped(state, "checkpoints", list.length(all) - max_marks)

      #(
        State(..state, marks: list.take(all, max_marks)),
        seam.Done("checkpoint recorded"),
      )
    }
    seam.StoreDownload(download) -> {
      let ticket = secret.token(16)

      #(
        State(
          ..state,
          downloads: downloads.put(state.downloads, ticket, download, now),
        ),
        seam.DownloadReady(ticket),
      )
    }
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
    list.reverse(list.map(state.marks, fn(mark) { mark.checkpoint })),
    audit.tail(state.config.audit, audit.capacity),
    state.probes,
  ))

  let path = saver.directory <> "/" <> id <> ".pgcap"

  capture_file.write(path, header, records)
  |> result.replace(path)
}

// A checkpoint's place on the agent's clock, from the clock record a ping
// produced: the agent's reading then, plus the viewer's time since. Without a
// record it is zero, and a reader uses the checkpoint's `system_ms`.
fn agent_ns(state: State, now: Int) -> Int {
  case state.config.saver {
    Some(saver) ->
      case saver.facts.clock {
        Some(clock) ->
          clock.agent_monotonic_ns
          + { now - clock.viewer_system_ms }
          * 1_000_000
        None -> 0
      }
    None -> 0
  }
}

// ----------------------------------------------------------------- probes

// A probe the agent accepted is recorded from the plan that started it.
fn record_started(
  probes: List(ProbeRecord),
  command: Command,
  probe_id: Int,
  matched: Int,
  deadline_ms: Int,
  now: Int,
) -> List(ProbeRecord) {
  case command {
    policy.StartProbe(spec:) -> [
      probe_book.started(
        probe_id,
        spec.kind,
        spec.modules,
        now,
        deadline_ms,
        matched,
      ),
      ..probes
    ]
    _ -> probes
  }
}

// The operator's stop returns the probe's last snapshot; the record that
// named it is closed with it.
/// How many collection and self-measure results the service keeps.
pub const max_results = 20

/// How many finished probes the service keeps. A running probe is never
/// dropped.
pub const max_probes = 50

/// How many checkpoints the service keeps.
pub const max_marks = 50

// Finished probes hold profiles, and every page copies the list out on each
// update, so the list is bounded and what was let go is said in the audit
// trail.
fn keep_probes(state: State) -> State {
  let #(kept, dropped) = probe_book.bound(state.probes, max_probes)

  note_dropped(state, "probes", dropped)

  State(..state, probes: kept)
}

fn note_dropped(state: State, what: String, count: Int) -> Nil {
  case count > 0 {
    True ->
      audit.append(
        state.config.audit,
        audit.Host(state.config.clock(), audit.RecordsDropped(what:, count:)),
      )
    False -> Nil
  }
}

fn remember(state: State, result: seam.ProcessResult) -> State {
  State(..state, results: list.take([result, ..state.results], max_results))
}

fn close_stacks(
  probes: List(ProbeRecord),
  snapshot: wire.StacksSnapshot,
  now: Int,
) -> List(ProbeRecord) {
  list.map(probes, fn(probe) {
    case
      probe.id == int.to_string(snapshot.probe_id),
      probe_book.is_running(probe)
    {
      True, True -> probe_book.finish_stacks(probe, snapshot, now)
      _, _ -> probe
    }
  })
}

fn close_calltrace(
  probes: List(ProbeRecord),
  snapshot: wire.CalltraceSnapshot,
  now: Int,
) -> List(ProbeRecord) {
  list.map(probes, fn(probe) {
    case
      probe.id == int.to_string(snapshot.probe_id),
      probe_book.is_running(probe)
    {
      True, True -> probe_book.finish_calltrace(probe, snapshot, now)
      _, _ -> probe
    }
  })
}

fn close_events(
  probes: List(ProbeRecord),
  snapshot: wire.EventsSnapshot,
  now: Int,
) -> List(ProbeRecord) {
  list.map(probes, fn(probe) {
    case
      probe.id == int.to_string(snapshot.probe_id),
      probe_book.is_running(probe)
    {
      True, True -> probe_book.finish_events(probe, snapshot, now)
      _, _ -> probe
    }
  })
}

fn close_probe(
  probes: List(ProbeRecord),
  snapshot: wire.CountersSnapshot,
  now: Int,
) -> List(ProbeRecord) {
  list.map(probes, fn(probe) {
    case
      probe.id == int.to_string(snapshot.probe_id),
      probe_book.is_running(probe)
    {
      True, True -> probe_book.finish_counters(probe, snapshot, now)
      _, _ -> probe
    }
  })
}

// Once a second the running probes are asked whether they have ended. The
// agent keeps an ended probe's snapshot only until it is read or stopped, so
// a probe that has ended is taken into a profile now and the agent is told
// to release it. A probe the agent no longer knows is closed as lost, and one
// that merely did not answer is asked again next time.
//
// The asking is a weft run with one task per probe, so a probe the agent is
// slow to answer delays neither the others nor this actor. The run's tasks
// make the requests; their outcomes come back as `Polled` and are applied
// here.
fn poll_probes(state: State) -> State {
  let running = list.filter(state.probes, probe_book.is_running)

  case state.polling, running {
    PollRunning, _ | PollIdle, [] -> state
    PollIdle, _ -> {
      let remote = state.remote
      let tasks =
        list.map(running, fn(probe) {
          fn() { Ok(#(probe.id, poll_one(remote, probe))) }
        })

      let _ =
        weft.new(tasks)
        |> weft.deadline(poll_deadline_ms)
        |> weft.start_relayed(to: state.sink)

      State(..state, polling: PollRunning)
    }
  }
}

/// How long a round of probe polls may take, in milliseconds. Each ask is
/// bounded by `exec.ask_deadline_ms`; the deadline is the backstop.
pub const poll_deadline_ms = 20_000

// One probe's ask, and the release of its result on the agent when it ended.
fn poll_one(remote: Remote, probe: ProbeRecord) -> exec.Poll {
  let answer = exec.poll_probe(remote, probe.id, probe.kind)

  case answer {
    exec.Polled(wire.CountersSnapshot(state: wire.ProbeRunning, ..))
    | exec.PolledStacks(wire.StacksSnapshot(state: wire.ProbeRunning, ..))
    | exec.PolledCalltrace(wire.CalltraceSnapshot(state: wire.ProbeRunning, ..))
    | exec.PolledEvents(wire.EventsSnapshot(state: wire.ProbeRunning, ..))
    | exec.PollRefused(_)
    | exec.PollPending -> Nil
    exec.Polled(_)
    | exec.PolledStacks(_)
    | exec.PolledCalltrace(_)
    | exec.PolledEvents(_) -> exec.release_probe(remote, probe.id, probe.kind)
  }

  answer
}

fn finish_poll(
  state: State,
  pulled: weft.Pulled(#(String, exec.Poll), String),
) -> State {
  case pulled {
    weft.PulledOutcome(weft.Completed(_, #(id, answer))) ->
      State(..state, probes: apply_poll(state, id, answer))

    // A task that failed or was cut off found nothing; the next round asks
    // again.
    weft.PulledOutcome(_) -> state

    // The run is over; the next tick may start another.
    weft.AllDelivered | weft.RunLost(_) -> State(..state, polling: PollIdle)

    weft.NotYet -> state
  }
}

// A probe the operator stopped while the round was in flight is already
// closed, and the poll's reading of it is dropped.
fn apply_poll(
  state: State,
  id: String,
  answer: exec.Poll,
) -> List(ProbeRecord) {
  let now = state.config.clock()

  list.map(state.probes, fn(probe) {
    case probe.id == id, probe_book.is_running(probe) {
      True, True ->
        case answer {
          exec.Polled(snapshot) ->
            case snapshot.state {
              wire.ProbeRunning -> probe
              wire.ProbeFinished | wire.ProbeStopped ->
                probe_book.finish_counters(probe, snapshot, now)
            }
          exec.PolledStacks(snapshot) ->
            case snapshot.state {
              wire.ProbeRunning -> probe
              wire.ProbeFinished | wire.ProbeStopped ->
                probe_book.finish_stacks(probe, snapshot, now)
            }
          exec.PolledCalltrace(snapshot) ->
            case snapshot.state {
              wire.ProbeRunning -> probe
              wire.ProbeFinished | wire.ProbeStopped ->
                probe_book.finish_calltrace(probe, snapshot, now)
            }
          exec.PolledEvents(snapshot) ->
            case snapshot.state {
              wire.ProbeRunning -> probe
              wire.ProbeFinished | wire.ProbeStopped ->
                probe_book.finish_events(probe, snapshot, now)
            }
          exec.PollRefused(reason) -> probe_book.finish_lost(probe, reason, now)
          exec.PollPending -> probe
        }
      _, _ -> probe
    }
  })
}

fn kind_of_probe(
  probes: List(ProbeRecord),
  id: String,
) -> Option(policy.ProbeKind) {
  case list.find(probes, fn(probe) { probe.id == id }) {
    Ok(probe) -> Some(probe.kind)
    Error(Nil) -> None
  }
}

// --------------------------------------------------------------- captures

// A principal may list and read capture files only when it may observe,
// which is the same question a page's subscription asks.
fn observe_allowed(state: State, principal: Principal) -> Bool {
  let decision =
    gate.authorize(
      state.gate,
      principal,
      policy.ReadCensus(200),
      state.config.clock(),
    )

  audit.append_all(state.config.audit, decision.entries)

  result.is_ok(decision.result)
}

// The capture files of the save directory, newest first by modification
// time. Only `.pgcap` files are offered.
fn capture_names(state: State) -> List(String) {
  case state.config.saver {
    None -> []
    Some(saver) ->
      case simplifile.read_directory(saver.directory) {
        Error(_) -> []
        Ok(names) ->
          names
          |> list.filter(fn(name) { string.ends_with(name, ".pgcap") })
          |> list.map(fn(name) { #(name, modified(saver.directory, name)) })
          |> list.sort(fn(a, b) {
            case int.compare(b.1, a.1) {
              order.Eq -> string.compare(a.0, b.0)
              other -> other
            }
          })
          |> list.map(fn(entry) { entry.0 })
      }
  }
}

fn modified(directory: String, name: String) -> Int {
  case simplifile.file_info(directory <> "/" <> name) {
    Ok(info) -> info.mtime_seconds
    Error(_) -> 0
  }
}

// A name is read only if it is one the listing offers, so a name that is a
// path, or names a file outside the directory, reads nothing.
fn read_capture(
  state: State,
  name: String,
) -> Result(capture_file.Loaded, String) {
  case state.config.saver, list.contains(capture_names(state), name) {
    Some(saver), True -> capture_file.read(saver.directory <> "/" <> name)
    _, _ -> Error("that is not a capture file the viewer offers")
  }
}

// ------------------------------------------------------- one-click profiles

fn claims(which: Which, held: Held) -> Bool {
  case which {
    AnyPlan -> True
    ThisPlan(plan_id:) -> held.plan_id == plan_id
  }
}

// The plan was confirmed: its profile is starting, and no longer waits on
// the plan the confirm consumed.
fn advance(held: List(Held), plan_id: String) -> List(Held) {
  list.map(held, fn(entry) {
    case entry.plan_id == plan_id && entry.stage == Planned {
      True -> Held(..entry, stage: Starting)
      False -> entry
    }
  })
}

// What starting the probe produced. A probe the agent accepted is the
// profile's from here on. Any other outcome means no probe is running, so the
// profile goes back to waiting on a plan that no longer exists, and the next
// sweep releases what it pinned.
fn settle(
  state: State,
  plan_id: Option(String),
  outcome: exec.Outcome,
) -> State {
  case plan_id {
    None -> state
    Some(id) ->
      State(
        ..state,
        held: list.map(state.held, fn(entry) {
          case entry.plan_id == id && entry.stage == Starting {
            False -> entry
            True ->
              case outcome {
                exec.ProbeStarted(probe_id, ..) ->
                  Held(..entry, stage: Sampling(int.to_string(probe_id)))
                _ -> Held(..entry, stage: Planned)
              }
          }
        }),
      )
  }
}

// Whether a profile still needs its pins: while its plan can be confirmed,
// while the start is in flight, and while its probe runs.
fn needs_pins(state: State, held: Held, now: Int) -> Bool {
  case held.stage {
    Planned ->
      list.any(gate.pending(state.gate, held.principal.id, now), fn(entry) {
        entry.0 == held.plan_id
      })
    Starting -> True
    Sampling(probe_id:) ->
      case list.find(state.probes, fn(probe) { probe.id == probe_id }) {
        Ok(probe) -> probe_book.is_running(probe)
        Error(Nil) -> False
      }
  }
}

// Once a second, the profiles that no longer need their pins give them up.
fn sweep_held(state: State) -> State {
  let now = state.config.clock()
  let #(keep, done) =
    list.partition(state.held, fn(held) { needs_pins(state, held, now) })

  case done {
    [] -> state
    _ -> release_pins(State(..state, held: keep), done, now)
  }
}

/// How long a round of pin releases may take, in milliseconds.
pub const release_deadline_ms = 20_000

// Each pin goes through the gate as the operator's own release would, so it
// is allowed and audited like one. The agent is asked in a weft run, so a
// slow agent holds up neither this actor nor the other pages, and the
// outcomes come back as `Released`.
fn release_pins(state: State, done: List(Held), now: Int) -> State {
  let remote = state.remote

  let tasks =
    list.flat_map(done, fn(held) {
      list.filter_map(held.taken, fn(text) {
        use token <- result.try(
          identity.parse_pin(text) |> result.replace_error(Nil),
        )
        let decision =
          gate.authorize(
            state.gate,
            held.principal,
            policy.UnpinProcess(token),
            now,
          )

        audit.append_all(state.config.audit, decision.entries)

        case decision.result {
          Ok(authorized) ->
            Ok(fn() {
              Ok(#(authorized, exec.run(remote, authorized, fn(_) { None })))
            })
          Error(_) -> Error(Nil)
        }
      })
    })

  case tasks {
    [] -> state
    _ -> {
      let _ =
        weft.new(tasks)
        |> weft.deadline(release_deadline_ms)
        |> weft.start_relayed(to: state.release_sink)

      state
    }
  }
}

/// Plan a one-click profile, or plan an earlier one again.
///
/// This runs in the caller's process, like `submit`, and waits on the agent
/// only there. It pins the processes that are not pinned, one command each
/// through the gate, plans one stack probe over them, and records what it
/// pinned against the plan so the service releases it later. A process that
/// cannot be pinned (it exited, or the agent's pin table is full) is left out
/// and the plan's sentence says so; if none can be pinned nothing is planned.
///
/// ## Examples
///
/// ```gleam
/// service.profile(
///   service,
///   principal,
///   seam.PlanProfile(["<0.91.0>"], "<0.91.0>", 10_000, 100),
/// )
/// // -> seam.PlanReady(id, plan)
/// ```
pub fn profile(
  service: Service,
  principal: Principal,
  request: seam.ProfileRequest,
) -> Reply {
  case request {
    seam.PlanProfile(pids:, chosen:, duration_ms:, rate_hz:) ->
      plan_fresh(
        service,
        principal,
        pids,
        chosen,
        duration_ms,
        seam.ByStacks(rate_hz),
      )

    seam.PlanCallTrace(pids:, chosen:, duration_ms:, modules:) ->
      plan_fresh(
        service,
        principal,
        pids,
        chosen,
        duration_ms,
        seam.ByCalls(modules),
      )

    seam.PlanRecording(pids:, chosen:, duration_ms:) ->
      plan_fresh(service, principal, pids, chosen, duration_ms, seam.ByEvents)

    seam.ReplanProfile(plan_id:, duration_ms:, method:) ->
      case replannable(service, principal, plan_id, method) {
        Error(reason) -> seam.Rejected(reason)
        Ok(Nil) ->
          case claim(service, principal, ThisPlan(plan_id)) {
            [held, ..] ->
              plan_profile(
                service,
                principal,
                held.pids,
                held.chosen,
                duration_ms,
                method,
                held.taken,
              )
            [] -> seam.Rejected("that profile plan is no longer pending")
          }
      }
  }
}

// A new profile replaces every plan the principal has pending, taking over
// the pins they held so none is released in between.
fn plan_fresh(
  service: Service,
  principal: Principal,
  pids: List(String),
  chosen: String,
  duration_ms: Int,
  method: seam.ProfileMethod,
) -> Reply {
  let claimed = claim(service, principal, AnyPlan)

  plan_profile(
    service,
    principal,
    pids,
    chosen,
    duration_ms,
    method,
    list.flat_map(claimed, fn(held) { held.taken }),
  )
}

// Whether a pending plan can be planned again by another method. The check is
// made before the plan is claimed, because a claim cancels it: a call trace
// takes fewer processes than a stack probe, and a swap the agent would refuse
// must leave the plan the operator has in place.
fn replannable(
  service: Service,
  principal: Principal,
  plan_id: String,
  method: seam.ProfileMethod,
) -> Result(Nil, String) {
  let notes =
    process.call(service.subject, 5000, fn(reply) { Notes(principal.id, reply) })

  case list.find(notes, fn(note) { note.plan_id == plan_id }), method {
    Error(Nil), _ -> Error("that profile plan is no longer pending")
    Ok(note), seam.ByCalls(_) if note.processes > seam.trace_limit ->
      Error(
        "a call trace takes at most "
        <> int.to_string(seam.trace_limit)
        <> " processes and this profile chose "
        <> int.to_string(note.processes),
      )
    Ok(_), _ -> Ok(Nil)
  }
}

fn claim(service: Service, principal: Principal, which: Which) -> List(Held) {
  process.call(service.subject, 5000, fn(reply) {
    Claim(principal.id, which, reply)
  })
}

// `inherited` are pins an earlier pending plan of this principal took and
// handed over, which this plan now holds whether or not it uses them.
fn plan_profile(
  service: Service,
  principal: Principal,
  pids: List(String),
  chosen: String,
  duration_ms: Int,
  method: seam.ProfileMethod,
  inherited: List(String),
) -> Reply {
  let wanted = list.unique(pids)
  let limit = case method {
    seam.ByStacks(_) -> seam.profile_limit
    seam.ByCalls(_) -> seam.trace_limit
    seam.ByEvents -> seam.recording_limit
  }

  case list.length(wanted) {
    0 -> {
      release_now(service, principal, inherited)

      seam.Rejected("no process to profile")
    }
    count if count > limit -> {
      release_now(service, principal, inherited)

      seam.Rejected(
        "a "
        <> case method {
          seam.ByStacks(_) -> "profile"
          seam.ByCalls(_) -> "call trace"
          seam.ByEvents -> "recording"
        }
        <> " takes at most "
        <> int.to_string(limit)
        <> " processes",
      )
    }
    _ -> {
      let cards = process.call(service.subject, 5000, fn(reply) { Pins(reply) })
      let pinned =
        list.fold(
          wanted,
          Pinning(targets: [], taken: inherited, left_out: []),
          fn(so_far, pid) { pin_one(service, principal, cards, so_far, pid) },
        )

      case list.reverse(pinned.targets) {
        [] -> {
          release_now(service, principal, pinned.taken)

          seam.Rejected(
            "none of the "
            <> int.to_string(list.length(wanted))
            <> " processes could be pinned: "
            <> string.join(list.reverse(pinned.left_out), "; "),
          )
        }
        targets ->
          plan_over(
            service,
            principal,
            targets,
            pinned,
            wanted,
            chosen,
            duration_ms,
            method,
          )
      }
    }
  }
}

// What pinning the chosen processes has done so far: the tokens to plan
// over, the tokens this profile took for itself and must release, and the
// reasons any process was left out.
type Pinning {
  Pinning(targets: List(String), taken: List(String), left_out: List(String))
}

fn pin_one(
  service: Service,
  principal: Principal,
  cards: List(seam.PinCard),
  so_far: Pinning,
  pid: String,
) -> Pinning {
  let held =
    list.find(cards, fn(card) {
      card.pid_text == pid && card.status == seam.PinLive
    })

  case held {
    // Already pinned, by the operator or by a plan this one replaced. A pin
    // of the second kind is in `taken` already; one of the first never is.
    Ok(card) -> Pinning(..so_far, targets: [card.token, ..so_far.targets])
    Error(Nil) ->
      case submit(service, principal, seam.PinProcess(pid)) {
        seam.PinIssued(token, _) ->
          Pinning(..so_far, targets: [token, ..so_far.targets], taken: [
            token,
            ..so_far.taken
          ])
        seam.Rejected(reason) ->
          Pinning(..so_far, left_out: [pid <> ": " <> reason, ..so_far.left_out])
        _ ->
          Pinning(..so_far, left_out: [
            pid <> ": the viewer did not pin it",
            ..so_far.left_out
          ])
      }
  }
}

fn plan_over(
  service: Service,
  principal: Principal,
  targets: List(String),
  pinned: Pinning,
  wanted: List(String),
  chosen: String,
  duration_ms: Int,
  method: seam.ProfileMethod,
) -> Reply {
  let planned =
    submit(service, principal, case method {
      seam.ByStacks(rate_hz) ->
        seam.PlanProbe(policy.Sampling, targets, [], duration_ms, rate_hz)
      seam.ByCalls(modules) ->
        seam.PlanProbe(policy.CallTree, targets, modules, duration_ms, 0)
      seam.ByEvents ->
        seam.PlanProbe(policy.SchedulingGc, targets, [], duration_ms, 0)
    })

  case planned {
    seam.PlanReady(plan_id, _) -> {
      let sentence = case list.length(pinned.left_out) {
        0 -> chosen
        n ->
          chosen
          <> " ("
          <> int.to_string(n)
          <> " could not be pinned and are left out)"
      }

      process.call(service.subject, 5000, fn(reply) {
        Hold(
          Held(
            plan_id:,
            principal:,
            taken: pinned.taken,
            pids: wanted,
            chosen: sentence,
            duration_ms:,
            method:,
            stage: Planned,
          ),
          reply,
        )
      })

      planned
    }
    refused -> {
      release_now(service, principal, pinned.taken)

      refused
    }
  }
}

// A profile that planned nothing gives its pins back at once, in the
// caller's process, so a refused request leaves the agent's pin table as it
// was.
fn release_now(
  service: Service,
  principal: Principal,
  tokens: List(String),
) -> Nil {
  list.each(tokens, fn(token) {
    let _ = submit(service, principal, seam.UnpinProcess(token))

    Nil
  })
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
    submit: fn(request) { submit(service, principal, request) },
    profile: fn(request) { profile(service, principal, request) },
    profile_notes: fn() {
      process.call(service.subject, 5000, fn(reply) {
        Notes(principal.id, reply)
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
    probes: fn() {
      process.call(service.subject, 5000, fn(reply) { Probes(reply) })
    },
    results: fn() {
      process.call(service.subject, 5000, fn(reply) { Results(reply) })
    },
    captures: fn() {
      process.call(service.subject, 5000, fn(reply) {
        Captures(principal, reply)
      })
    },
    read_capture: fn(name) {
      process.call(service.subject, 30_000, fn(reply) {
        ReadCapture(principal, name, reply)
      })
    },
    audit: fn(count) {
      case submit(service, principal, seam.ReadAudit(count)) {
        seam.AuditTail(entries) -> entries
        _ -> []
      }
    },
    pins: fn() {
      process.call(service.subject, 5000, fn(reply) { Pins(reply) })
    },
  )
}

/// Take a one-time download. The ticket is consumed by the attempt, whether
/// or not a file comes back.
///
/// ## Examples
///
/// ```gleam
/// service.take_download(service, ticket)
/// ```
pub fn take_download(
  service: Service,
  ticket: String,
) -> Result(downloads.Download, downloads.Refusal) {
  process.call(service.subject, 5000, fn(reply) { TakeDownload(ticket, reply) })
}

// A request is decided by the service, run on the agent link by this
// process when the decision is a command, and its outcome applied by the
// service. Only this process waits on the agent.
fn submit(service: Service, principal: Principal, request: Request) -> Reply {
  let decided =
    process.call(service.subject, 30_000, fn(reply) {
      Decide(principal, request, reply)
    })

  case decided {
    Answered(reply) -> reply
    Execute(authorized, follow, kind_of, plan_id) -> {
      let outcome = exec.run(service.remote, authorized, kind_of)

      process.call(service.subject, 30_000, fn(reply) {
        Apply(authorized, follow, plan_id, outcome, reply)
      })
    }
  }
}
