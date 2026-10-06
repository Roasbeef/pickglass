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
//// Probes come in five kinds the agent runs: counters (one module with
//// the first wire release's request, several with the counter-set request),
//// counters that also count allocation, stack sampling, a call tree over
//// named modules and scheduling and collection events. A stop or a poll must
//// go to the right kind of probe, so the caller says which kind a probe id
//// belongs to.
////
//// An allocation probe is a counter set in the `time_and_memory` mode, and its
//// result is two replies: the counters and, read apart, the allocation. The
//// agent removes a probe when it is stopped, so the allocation is read first,
//// and the stop is made whether or not that read answered, because the stop is
//// what leaves nothing in the agent.
////
//// The tracing probes send the agent the viewer's own budgets (the number of
//// events and slices to keep), which the plan states, and the events probe
//// asks for the node-wide long collection and long timeslice thresholds. A
//// node older than OTP 28 refuses a probe that sets them, and the probe is
//// then asked again without, because a probe that watches nothing node-wide
//// is still the probe that was planned for the traced processes.
////
//// A probe's targets are always the pins its plan named. `wire.AllProcesses`
//// is never constructed here: the agent supports a probe over every
//// process, and the viewer does not offer it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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

  /// A probe that counts allocation stopped, with its last reading of the
  /// counters and of the allocation.
  AllocationStopped(
    counters: wire.CountersSnapshot,
    memory: wire.CounterMemorySnapshot,
  )

  /// A stack probe stopped, with what it sampled.
  StacksStopped(snapshot: wire.StacksSnapshot)

  /// A call tree probe stopped, with what it traced.
  CalltraceStopped(snapshot: wire.CalltraceSnapshot)

  /// A scheduling and collection probe stopped, with what it recorded.
  EventsStopped(snapshot: wire.EventsSnapshot)

  /// A targeted collection ran.
  Collected(snapshot: wire.CollectionSnapshot)

  /// A process measured itself.
  Measured(snapshot: wire.MeasureSnapshot)

  /// One pinned process in detail.
  ProcessRead(detail: wire.ProcessDetail)

  /// The spawn edges of the node.
  SupervisionRead(snapshot: wire.SupervisionSnapshot)

  /// The reference-counted binaries one pinned process holds.
  BinariesRead(snapshot: wire.BinariesSnapshot)

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
pub fn run(
  remote: Remote,
  authorized: Authorized(Command),
  kind_of: fn(String) -> Option(policy.ProbeKind),
) -> Outcome {
  case policy.authorized_command(authorized) {
    policy.PinProcess(pid_text:) -> pin(remote, pid_text)
    policy.UnpinProcess(token:) -> unpin(remote, token)
    policy.StartProbe(spec:) -> start_probe(remote, spec)
    policy.StopProbe(probe_id:) -> stop_probe(remote, probe_id, kind_of)
    policy.Detach -> detach(remote)

    policy.TargetedGc(token:) -> collect(remote, token)
    policy.SelfMeasure(token:) -> measure(remote, token)
    policy.ReadProcess(token:) -> read_process(remote, token)
    policy.ReadSupervision -> read_supervision(remote)
    policy.ReadBinaries(token:) -> read_binaries(remote, token)

    policy.ReadCensus(_)
    | policy.ReadOwners
    | policy.ReadEtsTables
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

// A counters probe over one module is the first release's request; several
// modules are one counter set. A stack probe samples the pinned processes at
// a fixed rate, bounded by the samples the duration allows. A probe always
// names the pins its plan named; `wire.AllProcesses` is never constructed.
fn start_probe(remote: Remote, spec: policy.ProbeSpec) -> Outcome {
  case spec.kind, spec.modules {
    policy.Counters, [module] ->
      counters_started(
        remote,
        wire.AskStartCounters(
          module,
          "_",
          wire.PinnedProcesses(spec.targets),
          spec.duration_ms,
        ),
      )
    policy.Counters, modules ->
      counters_started(
        remote,
        wire.Extended(wire.AskStartCounterSet(
          list.map(modules, fn(module) { wire.CounterPattern(module, "_") }),
          wire.PinnedProcesses(spec.targets),
          spec.duration_ms,
          wire.CountTime,
        )),
      )
    policy.CallMemory, modules ->
      counters_started(
        remote,
        wire.Extended(wire.AskStartCounterSet(
          list.map(modules, fn(module) { wire.CounterPattern(module, "_") }),
          wire.PinnedProcesses(spec.targets),
          spec.duration_ms,
          wire.CountTimeAndMemory,
        )),
      )
    policy.Sampling, _ -> stacks_started(remote, spec)
    policy.CallTree, _ -> calltrace_started(remote, spec)
    policy.SchedulingGc, _ -> events_started(remote, spec)
  }
}

// A call tree probe traces every function of each named module. The agent
// matches the patterns when it starts and refuses a set that is too broad or
// names a module it has never seen, and the refusal comes back as it is.
fn calltrace_started(remote: Remote, spec: policy.ProbeSpec) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskStartCalltrace(
        spec.targets,
        list.map(spec.modules, fn(module) { wire.CounterPattern(module, "_") }),
        spec.duration_ms,
        policy.trace_event_budget,
        policy.timeline_slice_limit,
      )),
      ask_deadline_ms,
    )
  {
    Ok(wire.CalltraceStarted(probe_id, _, matched, duration, ..)) ->
      ProbeStarted(probe_id, matched, duration)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

// An events probe asks for the two node-wide thresholds. An agent on a node
// without them refuses with `thresholds_unavailable` and arms nothing, so the
// probe is asked again with both off.
fn events_started(remote: Remote, spec: policy.ProbeSpec) -> Outcome {
  case
    events_request(remote, spec, policy.long_gc_ms, policy.long_schedule_ms)
  {
    Failed(remote.Refusal(code: "thresholds_unavailable", ..)) ->
      events_request(remote, spec, 0, 0)
    other -> other
  }
}

fn events_request(
  remote: Remote,
  spec: policy.ProbeSpec,
  long_gc_ms: Int,
  long_schedule_ms: Int,
) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskStartEvents(
        spec.targets,
        spec.duration_ms,
        policy.trace_event_budget,
        policy.timeline_slice_limit,
        long_gc_ms,
        long_schedule_ms,
      )),
      ask_deadline_ms,
    )
  {
    Ok(wire.EventsStarted(probe_id, targets, duration, ..)) ->
      ProbeStarted(probe_id, targets, duration)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn counters_started(remote: Remote, request: wire.Request) -> Outcome {
  case remote.ask(request, ask_deadline_ms) {
    Ok(wire.CountersStarted(probe_id, matched, deadline)) ->
      ProbeStarted(probe_id, matched, deadline)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn stacks_started(remote: Remote, spec: policy.ProbeSpec) -> Outcome {
  let seconds = int.max(1, spec.duration_ms / 1000)
  let targets = int.max(1, list.length(spec.targets))
  let rate = policy.sampling_rate_hz(spec.rate_hz, targets)

  // Twice the samples the duration allows, so a probe that ends at its
  // deadline never also ends at its sample budget and is not called partial.
  let samples = int.min(200_000, 2 * rate * seconds * targets)

  case
    remote.ask(
      wire.Extended(wire.AskStartStacks(
        spec.targets,
        spec.rate_hz,
        spec.duration_ms,
        samples,
      )),
      ask_deadline_ms,
    )
  {
    Ok(wire.StacksStarted(probe_id, targets, _, duration, _)) ->
      ProbeStarted(probe_id, targets, duration)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn stop_probe(
  remote: Remote,
  probe_id: String,
  kind_of: fn(String) -> Option(policy.ProbeKind),
) -> Outcome {
  case int.parse(probe_id), kind_of(probe_id) {
    Error(Nil), _ -> Unsupported("a probe id is the integer the agent issued")
    Ok(_), None -> Unsupported("the viewer has no probe " <> probe_id)
    Ok(id), Some(policy.Sampling) ->
      case remote.ask(wire.Extended(wire.AskStopStacks(id)), ask_deadline_ms) {
        Ok(wire.StacksReport(snapshot)) -> StacksStopped(snapshot)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
    Ok(id), Some(policy.CallTree) ->
      case
        remote.ask(wire.Extended(wire.AskStopCalltrace(id)), ask_deadline_ms)
      {
        Ok(wire.CalltraceReport(snapshot)) -> CalltraceStopped(snapshot)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
    Ok(id), Some(policy.SchedulingGc) ->
      case remote.ask(wire.Extended(wire.AskStopEvents(id)), ask_deadline_ms) {
        Ok(wire.EventsReport(snapshot)) -> EventsStopped(snapshot)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
    Ok(id), Some(policy.Counters) ->
      case remote.ask(wire.AskStopCounters(id), ask_deadline_ms) {
        Ok(wire.CountersReport(snapshot)) -> ProbeStopped(snapshot)
        Ok(other) -> Unexpected(string.inspect(other))
        Error(failure) -> Failed(failure)
      }
    Ok(id), Some(policy.CallMemory) -> stop_allocation(remote, id)
  }
}

// The allocation is read before the stop, which removes the probe, and the
// stop is asked whether or not the read answered: a probe the viewer could not
// read must still not be left counting. A read that failed is the outcome only
// when the stop succeeded, so a refusal of the read is never hidden behind a
// stop that worked, and a stop that failed is reported as the failure it is.
fn stop_allocation(remote: Remote, id: Int) -> Outcome {
  let memory =
    remote.ask(wire.Extended(wire.AskReadCounterMemory(id)), ask_deadline_ms)
  let stopped = remote.ask(wire.AskStopCounters(id), ask_deadline_ms)

  case stopped, memory {
    Ok(wire.CountersReport(counters)), Ok(wire.CounterMemoryReport(snapshot)) ->
      AllocationStopped(counters, snapshot)
    Ok(wire.CountersReport(_)), Ok(other) -> Unexpected(string.inspect(other))
    Ok(wire.CountersReport(_)), Error(failure) -> Failed(failure)
    Ok(other), _ -> Unexpected(string.inspect(other))
    Error(failure), _ -> Failed(failure)
  }
}

// An intrusive collection stops the target while it runs, so its deadline is
// the longest the agent allows a worker to take.
const gc_deadline_ms = 5000

fn collect(remote: Remote, token: PinToken) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskGc(token, gc_deadline_ms)),
      gc_deadline_ms + 2000,
    )
  {
    Ok(wire.CollectionReport(snapshot)) -> Collected(snapshot)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

const measure_budget_ms = 2000

fn measure(remote: Remote, token: PinToken) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskMeasure(token, measure_budget_ms)),
      measure_budget_ms + 2000,
    )
  {
    Ok(wire.MeasureReport(snapshot)) -> Measured(snapshot)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn read_process(remote: Remote, token: PinToken) -> Outcome {
  case
    remote.ask(wire.Extended(wire.AskProcessDetail(token)), ask_deadline_ms)
  {
    Ok(wire.ProcessDetailReport(detail)) -> ProcessRead(detail)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

fn read_supervision(remote: Remote) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskSupervision(200_000, 10_000)),
      ask_deadline_ms,
    )
  {
    Ok(wire.SupervisionReport(snapshot)) -> SupervisionRead(snapshot)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

// How many of a process's largest binaries the read lists. The agent counts
// every binary either way; this is how many it names.
const binaries_listed = 20

// The read builds one tuple per reference in the target and copies the list
// into the agent's worker, so it gets the worker's own two-second deadline
// with a margin for the answer to travel.
fn read_binaries(remote: Remote, token: PinToken) -> Outcome {
  case
    remote.ask(
      wire.Extended(wire.AskBinaries(token, binaries_listed)),
      binaries_deadline_ms,
    )
  {
    Ok(wire.BinariesReport(snapshot)) -> BinariesRead(snapshot)
    Ok(other) -> Unexpected(string.inspect(other))
    Error(failure) -> Failed(failure)
  }
}

const binaries_deadline_ms = 5000

/// What asking a running probe how it is doing gave.
pub type Poll {
  /// The agent's counters snapshot, whose state says whether the probe has
  /// ended.
  Polled(snapshot: wire.CountersSnapshot)

  /// The agent's stack snapshot.
  PolledStacks(snapshot: wire.StacksSnapshot)

  /// The agent's call tree snapshot.
  PolledCalltrace(snapshot: wire.CalltraceSnapshot)

  /// A probe that counts allocation has ended, with the counters and the
  /// allocation the agent holds for it. While it runs the answer is `Polled`.
  PolledAllocation(
    counters: wire.CountersSnapshot,
    memory: wire.CounterMemorySnapshot,
  )

  /// The agent's scheduling and collection snapshot.
  PolledEvents(snapshot: wire.EventsSnapshot)

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
/// exec.poll_probe(remote, "7", policy.Counters)
/// ```
pub fn poll_probe(
  remote: Remote,
  probe_id: String,
  kind: policy.ProbeKind,
) -> Poll {
  case int.parse(probe_id) {
    Error(Nil) -> PollRefused("a probe id is the integer the agent issued")
    Ok(id) ->
      case kind {
        policy.Sampling ->
          polled(
            remote.ask(wire.Extended(wire.AskReadStacks(id)), ask_deadline_ms),
            fn(reply) {
              case reply {
                wire.StacksReport(snapshot) -> Ok(PolledStacks(snapshot))
                _ -> Error(Nil)
              }
            },
          )
        policy.CallTree ->
          polled(
            remote.ask(
              wire.Extended(wire.AskReadCalltrace(id)),
              ask_deadline_ms,
            ),
            fn(reply) {
              case reply {
                wire.CalltraceReport(snapshot) -> Ok(PolledCalltrace(snapshot))
                _ -> Error(Nil)
              }
            },
          )
        policy.SchedulingGc ->
          polled(
            remote.ask(wire.Extended(wire.AskReadEvents(id)), ask_deadline_ms),
            fn(reply) {
              case reply {
                wire.EventsReport(snapshot) -> Ok(PolledEvents(snapshot))
                _ -> Error(Nil)
              }
            },
          )
        policy.Counters ->
          polled(
            remote.ask(wire.AskReadCounters(id), ask_deadline_ms),
            fn(reply) {
              case reply {
                wire.CountersReport(snapshot) -> Ok(Polled(snapshot))
                _ -> Error(Nil)
              }
            },
          )
        policy.CallMemory -> poll_allocation(remote, id)
      }
  }
}

// A running allocation probe is read for its counters alone. Once it has
// ended the allocation is read too, in the same poll, because the agent keeps
// an ended probe only until it is released and the two replies must describe
// the same moment.
fn poll_allocation(remote: Remote, id: Int) -> Poll {
  let counters =
    polled(remote.ask(wire.AskReadCounters(id), ask_deadline_ms), fn(reply) {
      case reply {
        wire.CountersReport(snapshot) -> Ok(Polled(snapshot))
        _ -> Error(Nil)
      }
    })

  case counters {
    Polled(wire.CountersSnapshot(state: wire.ProbeRunning, ..)) -> counters
    Polled(snapshot) ->
      polled(
        remote.ask(
          wire.Extended(wire.AskReadCounterMemory(id)),
          ask_deadline_ms,
        ),
        fn(reply) {
          case reply {
            wire.CounterMemoryReport(memory) ->
              Ok(PolledAllocation(snapshot, memory))
            _ -> Error(Nil)
          }
        },
      )
    PolledStacks(_)
    | PolledCalltrace(_)
    | PolledEvents(_)
    | PolledAllocation(..)
    | PollRefused(_)
    | PollPending -> counters
  }
}

fn polled(
  answer: Result(wire.Reply, Failure),
  expected: fn(wire.Reply) -> Result(Poll, Nil),
) -> Poll {
  case answer {
    Ok(reply) ->
      case expected(reply) {
        Ok(found) -> found
        Error(Nil) -> PollRefused(string.inspect(reply))
      }
    Error(remote.TimedOut) -> PollPending
    Error(failure) -> PollRefused(remote.describe(failure))
  }
}

/// Tell the agent to let go of an ended probe whose result the viewer has
/// taken. It is a release of the viewer's own earlier request, and its
/// answer changes nothing the viewer holds.
///
/// ## Examples
///
/// ```gleam
/// exec.release_probe(remote, "7", policy.Counters)
/// ```
pub fn release_probe(
  remote: Remote,
  probe_id: String,
  kind: policy.ProbeKind,
) -> Nil {
  case int.parse(probe_id) {
    Error(Nil) -> Nil
    Ok(id) -> {
      let _ = case kind {
        policy.Sampling ->
          remote.ask(wire.Extended(wire.AskStopStacks(id)), ask_deadline_ms)
        policy.CallTree ->
          remote.ask(wire.Extended(wire.AskStopCalltrace(id)), ask_deadline_ms)
        policy.SchedulingGc ->
          remote.ask(wire.Extended(wire.AskStopEvents(id)), ask_deadline_ms)
        policy.Counters | policy.CallMemory ->
          remote.ask(wire.AskStopCounters(id), ask_deadline_ms)
      }

      Nil
    }
  }
}

fn detach(remote: Remote) -> Outcome {
  remote.detach()

  DetachRequested
}
