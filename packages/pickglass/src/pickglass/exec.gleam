//// The executor: the one module that turns an authorized command into
//// traffic on the agent link.
////
//// `run` takes an `Authorized(Command)`, which only `policy.authorize` and
//// `policy.confirm` can produce, so a forged event or a direct HTTP request
//// that skipped the gate cannot reach this module with anything to run. The
//// case over `Command` is exhaustive with no catch-all: adding a command to
//// `policy` fails this build until its execution is decided here.
////
//// Three kinds of command never reach the agent. Reads of the census,
//// owners and memory are answered from the hub's ring, because a page never
//// triggers a collection. An export is a write of the viewer's own data and
//// belongs to the service. Both come back as `NotAnAgentCommand`.
////
//// Two commands the policy models have no wire request yet: targeted GC and
//// self-measure, and every probe kind but counters. They come back as
//// `Unsupported` with the reason, never as a silent success.
////
//// A probe's targets are always the pins its plan named. `wire.AllProcesses`
//// is never constructed here: the agent supports a probe over every
//// process, and the viewer does not offer it.

import gleam/int
import gleam/list
import gleam/string
import pickglass/remote.{type Failure, type Remote}
import pickglass_core/identity.{type PinToken}
import pickglass_core/policy.{type Authorized, type Command}
import pickglass_core/wire

/// How long a request for a pin or a probe waits for the agent, in
/// milliseconds.
pub const ask_deadline_ms = 10_000

/// What running a command produced.
pub type Outcome {
  /// The agent issued a pin.
  PinIssued(token: PinToken, pid_text: String)

  /// The pin was released.
  PinReleased

  /// A counters probe started.
  ProbeStarted(probe_id: Int, matched: Int, deadline_ms: Int)

  /// A counters probe stopped, with its last reading.
  ProbeStopped(snapshot: wire.CountersSnapshot)

  /// The agent was told to detach.
  DetachRequested

  /// The command is a read the hub answers or an export the service writes.
  NotAnAgentCommand

  /// The agent has no request for this yet.
  Unsupported(reason: String)

  /// The agent did not answer, or refused.
  Failed(failure: Failure)

  /// The agent answered with a reply this command does not expect.
  Unexpected(reply: String)
}

/// Run an authorized command against the remote.
///
/// ## Examples
///
/// ```gleam
/// exec.run(remote, authorized)
/// // -> PinIssued(token, "<0.123.0>")
/// ```
pub fn run(remote: Remote, authorized: Authorized(Command)) -> Outcome {
  case policy.authorized_command(authorized) {
    policy.PinProcess(pid_text:) -> pin(remote, pid_text)
    policy.UnpinProcess(token:) -> unpin(remote, token)
    policy.StartProbe(spec:) -> start_probe(remote, spec)
    policy.StopProbe(probe_id:) -> stop_probe(remote, probe_id)
    policy.Detach -> detach(remote)

    policy.TargetedGc(_) ->
      Unsupported("the agent has no targeted garbage collection yet")
    policy.SelfMeasure(_) ->
      Unsupported("the agent has no self-measure request yet")
    policy.ReadProcess(_) ->
      Unsupported("the agent has no process detail request yet")
    policy.ReadSupervision ->
      Unsupported("the agent has no supervision walk yet")

    policy.ReadCensus(_)
    | policy.ReadOwners
    | policy.ReadMemory
    | policy.ReadAudit(_)
    | policy.ExportCapture(..)
    | policy.Checkpoint(_) -> NotAnAgentCommand
  }
}

fn pin(remote: Remote, pid_text: String) -> Outcome {
  case remote.ask(wire.AskPin(pid_text), ask_deadline_ms) {
    Ok(wire.Pinned(token, text)) -> PinIssued(token, text)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn unpin(remote: Remote, token: PinToken) -> Outcome {
  case remote.ask(wire.AskUnpin(token), ask_deadline_ms) {
    Ok(wire.Unpinned(_)) -> PinReleased
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

// The agent traces one module per request, and a probe names its processes
// by pin. Any other shape is refused here, with the reason, rather than
// narrowed silently.
fn start_probe(remote: Remote, spec: policy.ProbeSpec) -> Outcome {
  case spec.kind, spec.modules {
    policy.Counters, [module] ->
      case
        remote.ask(
          wire.AskStartCounters(
            module,
            "_",
            wire.PinnedProcesses(spec.targets),
            spec.duration_ms,
          ),
          ask_deadline_ms,
        )
      {
        Ok(wire.CountersStarted(probe_id, matched, deadline)) ->
          ProbeStarted(probe_id, matched, deadline)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
    policy.Counters, modules ->
      Unsupported(
        "the agent traces one module per probe; the plan named "
        <> int.to_string(list.length(modules)),
      )
    policy.Sampling, _ | policy.CallTree, _ | policy.SchedulingGc, _ ->
      Unsupported(
        "the agent has only counters probes yet; "
        <> policy.probe_code(spec.kind)
        <> " is not available",
      )
  }
}

fn stop_probe(remote: Remote, probe_id: String) -> Outcome {
  case int.parse(probe_id) {
    Error(Nil) -> Unsupported("a probe id is the integer the agent issued")
    Ok(id) ->
      case remote.ask(wire.AskStopCounters(id), ask_deadline_ms) {
        Ok(wire.CountersReport(snapshot)) -> ProbeStopped(snapshot)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
  }
}

/// What asking a running counters probe how it is doing gave.
pub type Poll {
  /// The agent's snapshot, whose state says whether the probe has ended.
  Polled(snapshot: wire.CountersSnapshot)

  /// The agent no longer has the probe, or refused; the text says why.
  PollRefused(reason: String)

  /// The agent did not answer in time. Ask again later.
  PollPending
}

/// Ask the agent how a probe the viewer started is doing. This is the one
/// agent request made outside `run`: it reads the result of a probe an
/// authorized command already started, and changes nothing in the target.
///
/// ## Examples
///
/// ```gleam
/// exec.poll_counters(remote, "7")
/// ```
pub fn poll_counters(remote: Remote, probe_id: String) -> Poll {
  case int.parse(probe_id) {
    Error(Nil) -> PollRefused("a probe id is the integer the agent issued")
    Ok(id) ->
      case remote.ask(wire.AskReadCounters(id), ask_deadline_ms) {
        Ok(wire.CountersReport(snapshot)) -> Polled(snapshot)
        Ok(other) -> PollRefused(string.inspect(other))
        Error(remote.TimedOut) -> PollPending
        Error(failure) -> PollRefused(remote.describe(failure))
      }
  }
}

/// Tell the agent to let go of an ended probe whose result the viewer has
/// taken. It is a release of the viewer's own earlier request, and its
/// answer changes nothing the viewer holds.
///
/// ## Examples
///
/// ```gleam
/// exec.release_counters(remote, "7")
/// ```
pub fn release_counters(remote: Remote, probe_id: String) -> Nil {
  case int.parse(probe_id) {
    Error(Nil) -> Nil
    Ok(id) -> {
      let _ = remote.ask(wire.AskStopCounters(id), ask_deadline_ms)

      Nil
    }
  }
}

fn detach(remote: Remote) -> Outcome {
  remote.detach()

  DetachRequested
}
