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
  )
}

/// What the actor receives.
pub opaque type Message {
  Decide(principal: Principal, request: Request, reply: Subject(Decided))
  Apply(
    authorized: policy.Authorized(Command),
    follow: seam.Follow,
    outcome: exec.Outcome,
    reply: Subject(Reply),
  )
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
      ))
      |> actor.selecting(
        process.new_selector()
        |> process.select(subject)
        |> process.select_map(watcher, TargetGone)
        |> process.select_map(sink, Polled),
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
    Apply(authorized, follow, outcome, reply) -> {
      let #(state, answer) = apply(state, authorized, follow, outcome)

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

    Poll -> actor.continue(poll_probes(state))

    Polled(pulled) -> actor.continue(finish_poll(state, pulled))

    // The hub reported the target gone: every pin is dead from here on, and
    // so is every probe the agent was running.
    TargetGone(hub.TargetLost(reason)) -> {
      audit.append(
        state.config.audit,
        audit.Host(state.config.clock(), audit.PinsInvalidated(reason)),
      )

      actor.continue(
        State(
          ..state,
          gate: gate.target_lost(state.gate, reason, state.config.clock()),
          probes: list.map(state.probes, fn(probe) {
            case probe_book.is_running(probe) {
              True ->
                probe_book.finish_lost(probe, reason, state.config.clock())
              False -> probe
            }
          }),
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
      run_decision(state, decision, follow)
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
      run_decision(State(..state, gate: next), decision, seam.NoFollow)
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
) -> #(State, Decided) {
  case decision.result {
    Error(refusal) -> #(state, Answered(seam.Rejected(refusal_text(refusal))))
    Ok(authorized) -> #(
      state,
      Execute(authorized, follow, fn(id) { kind_of_probe(state.probes, id) }),
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
    seam.AddCheckpoint(name) -> {
      let newest =
        list.first(hub.latest(state.config.hub)) |> option.from_result
      let checkpoint = capture.Checkpoint(name, agent_ns(state, now), now)

      #(
        State(..state, marks: [marks.take(checkpoint, newest), ..state.marks]),
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
  _deadline_ms: Int,
  now: Int,
) -> List(ProbeRecord) {
  case command {
    policy.StartProbe(spec:) -> [
      probe_book.started(
        probe_id,
        spec.kind,
        spec.modules,
        now,
        spec.duration_ms,
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
    | exec.PollRefused(_)
    | exec.PollPending -> Nil
    exec.Polled(_) | exec.PolledStacks(_) ->
      exec.release_probe(remote, probe.id, probe.kind)
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
    Execute(authorized, follow, kind_of) -> {
      let outcome = exec.run(service.remote, authorized, kind_of)

      process.call(service.subject, 30_000, fn(reply) {
        Apply(authorized, follow, outcome, reply)
      })
    }
  }
}
