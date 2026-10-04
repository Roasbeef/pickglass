//// The stack sampling process: one gen_server per probe that polls
//// `process_info(P, current_stacktrace)` for its targets and aggregates the
//// answers as it goes.
////
//// Sampling is polling, and the method is stated in every reply: a sample is
//// taken at the reduction safe point a `process_info` signal is handled at,
//// so a process inside a long non-yielding built-in is under-sampled, and
//// the result says where processes were when asked, not how long they spent
//// there. The achieved rate is measured and reported next to the requested
//// one, because a timer that fires late or a target that is slow to answer
//// both lower it.
////
//// The sampler is its own process for three reasons. The agent never waits
//// on a target, and `process_info` on a target is a signal that may be
//// answered late. A probe's aggregate can hold thousands of stacks, and a
//// heap cap on the sampler contains that where the agent has none. And the
//// reply to a read is built by the process that holds the data, so the agent
//// never copies a probe's table.
////
//// A sampler ends sampling by itself, at its deadline, at its sample budget
//// or when every target has exited, and then keeps its result until the
//// agent reads it, stops it or drops it. It monitors the agent and exits
//// when the agent does, so an agent killed outright leaves no sampler.
////
//// ## Flow
////
//// `start` spawns the sampler with its heap capped. `init` measures the
//// node's backtrace depth and sends the sampler its first `Tick`.
//// `handle_info` takes every message: `Tick` runs `sample`, which takes one
//// round, checks the deadline and the budget, and arms the next `Tick`; a
//// read or a stop request is answered with a snapshot; the agent's death
//// ends the sampler. `finish` records why sampling ended and tells the agent.

import pickglass_agent/internal/ffi_gen_server.{
  type Next, Noreply, Normal, SpawnOpt, Stop,
}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{
  type Atom, type Pid, type Reference, type Term,
}
import pickglass_agent/internal/seq
import pickglass_agent/owner
import pickglass_agent/reply
import pickglass_agent/stacks.{type Aggregate, type Stop as StopReason}

/// The deepest stack the depth measurement can see. A node whose
/// `backtrace_depth` is larger reports this, which is a lower bound.
pub const depth_probe = 256

/// What the sampler needs to run one probe.
pub type Config {
  Config(
    /// The agent, which is told when sampling ends and whose death ends the
    /// sampler.
    agent: Pid,
    /// The probe's id, quoted in the notice to the agent.
    id: Int,
    /// The processes to sample.
    targets: List(Pid),
    /// Rounds per second, each round sampling every live target once.
    rate_hz: Int,
    /// How long to sample, in milliseconds.
    duration_ms: Int,
    /// The most samples to take across all targets.
    max_samples: Int,
  )
}

/// The sampler's state.
pub type State {
  State(
    config: Config,
    agent_monitor: Reference,
    started_ms: Int,
    ended_ms: Int,
    interval_ms: Int,
    targets: List(Pid),
    targets_gone: Int,
    depth_limit: Int,
    rounds: Int,
    aggregate: Aggregate,
    stop: StopReason,
  )
}

type Notice {
  Tick
}

// The tags of the messages the agent sends a sampler, and the one it sends
// the agent.
type Tag {
  PickglassSamplerRead
  PickglassSamplerStop
  PickglassStacksFinished
}

type Event {
  Round
  Read(reply_to: Pid, request: Reference)
  StopRequested(reply_to: Pid, request: Reference)
  AgentDown
  Ignored
}

// What a snapshot is for. A `Peek` leaves the probe as it is; a `Halt` ends a
// probe that is still sampling.
type Ask {
  Peek
  Halt
}

/// Start a sampler for one probe. Returns the sampler's pid. It is not
/// linked, so its crash reaches the agent as a monitor message; the caller
/// monitors it.
///
/// ## Examples
///
/// ```gleam
/// start(Config(agent: self(), id: 1, targets: [pid], rate_hz: 100, duration_ms: 5000, max_samples: 10_000), 4_000_000)
/// // -> Ok(sampler_pid)
/// ```
pub fn start(config: Config, heap_words: Int) -> Result(Pid, Nil) {
  let started =
    ffi_gen_server.start_unlinked(
      ffi_term.atom("pickglass_agent@sampler"),
      ffi_term.coerce(config),
      [SpawnOpt([ffi_proc.heap_limit(heap_words)])],
    )

  case
    ffi_term.is_tuple(started)
    && ffi_term.tuple_size(started) == 2
    && ffi_term.element(1, started) == ffi_term.coerce(ffi_term.atom("ok"))
  {
    True -> Ok(ffi_term.coerce(ffi_term.element(2, started)))
    False -> Error(Nil)
  }
}

/// Ask a sampler for a snapshot of its probe so far. The sampler replies to
/// `reply_to` itself.
///
/// ## Examples
///
/// ```gleam
/// read(sampler, viewer, request)
/// ```
pub fn read(sampler: Pid, reply_to: Pid, request: Reference) -> Nil {
  ffi_proc.send(
    sampler,
    ffi_term.coerce(#(PickglassSamplerRead, reply_to, request)),
  )
}

/// Ask a sampler to stop, reply with its final snapshot and exit.
///
/// ## Examples
///
/// ```gleam
/// stop(sampler, viewer, request)
/// ```
pub fn stop(sampler: Pid, reply_to: Pid, request: Reference) -> Nil {
  ffi_proc.send(
    sampler,
    ffi_term.coerce(#(PickglassSamplerStop, reply_to, request)),
  )
}

/// The tag of the message a sampler sends the agent when sampling ends, as
/// `{Tag, ProbeId}`. The agent matches on it in `server.classify`.
pub fn finished_tag() -> Atom {
  ffi_term.coerce(PickglassStacksFinished)
}

/// The `gen_server` init callback. Measures the backtrace depth, arms the
/// first round and monitors the agent.
pub fn init(config: Config) -> Result(State, Nil) {
  owner.claim_self()

  let now = ffi_proc.now_ms()

  ffi_proc.send(ffi_proc.self(), ffi_term.coerce(Tick))

  Ok(State(
    config: config,
    agent_monitor: ffi_proc.monitor(ffi_proc.Process, config.agent),
    started_ms: now,
    ended_ms: 0,
    interval_ms: interval_ms(config.rate_hz),
    targets: config.targets,
    targets_gone: 0,
    depth_limit: depth_limit(),
    rounds: 0,
    aggregate: stacks.new(),
    stop: stacks.Sampling,
  ))
}

// Rounds per second as the gap between rounds, at least a millisecond since
// the timer has no finer grain.
fn interval_ms(rate_hz: Int) -> Int {
  case 1000 / rate_hz {
    0 -> 1
    gap -> gap
  }
}

/// The `gen_server` callback for every message.
pub fn handle_info(message: Term, state: State) -> Next(State) {
  case classify(message, state) {
    Round -> sample(state)
    Read(reply_to, request) -> {
      snapshot(state, reply_to, request, Peek)

      Noreply(state)
    }
    StopRequested(reply_to, request) -> {
      snapshot(state, reply_to, request, Halt)

      Stop(Normal, state)
    }
    AgentDown -> Stop(Normal, state)
    Ignored -> Noreply(state)
  }
}

fn classify(message: Term, state: State) -> Event {
  case message == ffi_term.coerce(Tick) {
    True -> Round
    False -> classify_tuple(message, state)
  }
}

fn classify_tuple(message: Term, state: State) -> Event {
  case ffi_term.is_tuple(message) {
    False -> Ignored
    True ->
      case ffi_term.tuple_size(message) {
        // `{pickglass_sampler_read | pickglass_sampler_stop, ReplyTo, Ref}`.
        3 -> classify_request(message)
        // `{'DOWN', Ref, process, Pid, Reason}` for the agent.
        5 ->
          case
            ffi_term.element(1, message)
            == ffi_term.coerce(ffi_term.atom("DOWN"))
            && ffi_term.element(2, message)
            == ffi_term.coerce(state.agent_monitor)
          {
            True -> AgentDown
            False -> Ignored
          }
        _ -> Ignored
      }
  }
}

fn classify_request(message: Term) -> Event {
  case
    ffi_term.is_pid(ffi_term.element(2, message))
    && ffi_term.is_reference(ffi_term.element(3, message))
  {
    False -> Ignored
    True -> {
      let reply_to: Pid = ffi_term.coerce(ffi_term.element(2, message))
      let request: Reference = ffi_term.coerce(ffi_term.element(3, message))
      let tag = ffi_term.element(1, message)

      case
        tag == ffi_term.coerce(PickglassSamplerRead),
        tag == ffi_term.coerce(PickglassSamplerStop)
      {
        True, _ -> Read(reply_to, request)
        _, True -> StopRequested(reply_to, request)
        False, False -> Ignored
      }
    }
  }
}

// One round: every live target is sampled once, unless the deadline has
// passed or the budget is spent. After a round the next one is armed for its
// slot on the schedule, so a round that ran long is followed by a shorter
// wait and the achieved rate stays as close to the requested one as the VM
// allows.
fn sample(state: State) -> Next(State) {
  case state.stop {
    stacks.Sampling -> {
      let now = ffi_proc.now_ms()

      case now >= state.started_ms + state.config.duration_ms {
        True -> Noreply(finish(state, stacks.DeadlineReached))
        False -> Noreply(next_round(take_round(state)))
      }
    }
    // A stray tick after sampling ended is ignored.
    _ -> Noreply(state)
  }
}

fn take_round(state: State) -> State {
  let sampled = sample_targets(state.targets, State(..state, targets: []))

  State(..sampled, rounds: sampled.rounds + 1)
}

// Walks the targets in order. A target that exited is dropped and counted; a
// target still alive stays for the next round. The budget is checked before
// each sample, so it is exact and not rounded up to a whole round.
fn sample_targets(remaining: List(Pid), state: State) -> State {
  case remaining {
    [] -> State(..state, targets: seq.reverse(state.targets))
    [target, ..rest] ->
      case state.aggregate.samples >= state.config.max_samples {
        True ->
          // The budget is spent: the unvisited targets stay for the record.
          State(
            ..state,
            targets: seq.reverse(state.targets) |> seq.append(remaining),
          )
        False -> sample_targets(rest, sample_one(state, target))
      }
  }
}

fn sample_one(state: State, target: Pid) -> State {
  case read_stack(target) {
    Error(Nil) -> State(..state, targets_gone: state.targets_gone + 1)
    Ok(#(status, stack)) ->
      State(
        ..state,
        targets: [target, ..state.targets],
        aggregate: stacks.record(
          state.aggregate,
          status,
          stack,
          state.depth_limit,
        ),
      )
  }
}

// After a round: end sampling if the budget is spent or no target is left,
// otherwise arm the next round.
fn next_round(state: State) -> State {
  case state.aggregate.samples >= state.config.max_samples, state.targets {
    True, _ -> finish(state, stacks.SampleBudget)
    _, [] -> finish(state, stacks.TargetsGone)
    False, _ -> {
      let now = ffi_proc.now_ms()
      let due = state.started_ms + state.rounds * state.interval_ms
      let last = state.started_ms + state.config.duration_ms
      let wait = case due > last {
        True -> last - now
        False -> due - now
      }

      ffi_proc.send_after(
        case wait < 0 {
          True -> 0
          False -> wait
        },
        ffi_proc.self(),
        ffi_term.coerce(Tick),
      )

      state
    }
  }
}

// Records why sampling ended and tells the agent, so its running-probe count
// is right and its next read can say `finished`.
fn finish(state: State, why: StopReason) -> State {
  ffi_proc.send(
    state.config.agent,
    ffi_term.coerce(#(PickglassStacksFinished, state.config.id)),
  )

  State(..state, stop: why, ended_ms: ffi_proc.now_ms())
}

// `process_info(Pid, [current_stacktrace, status])` answers
// `[{current_stacktrace, Stack}, {status, Status}]`, or the atom `undefined`
// for a process that exited.
fn read_stack(target: Pid) -> Result(#(Atom, Term), Nil) {
  let answer =
    ffi_proc.process_info(target, [ffi_proc.CurrentStacktrace, ffi_proc.Status])

  case ffi_term.is_list(answer) {
    False -> Error(Nil)
    True -> {
      let found: List(Term) = ffi_term.coerce(answer)

      case found {
        [stack, status] ->
          case
            ffi_term.is_tuple(stack)
            && ffi_term.tuple_size(stack) == 2
            && ffi_term.is_tuple(status)
            && ffi_term.tuple_size(status) == 2
            && ffi_term.is_atom(ffi_term.element(2, status))
          {
            True ->
              Ok(#(
                ffi_term.coerce(ffi_term.element(2, status)),
                ffi_term.element(2, stack),
              ))
            False -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    }
  }
}

// Builds the snapshot reply and sends it. A probe still sampling when it is
// halted is `stopped`; one that already ended on its own keeps the reason it
// ended with and reads as `finished`.
fn snapshot(state: State, reply_to: Pid, request: Reference, ask: Ask) -> Nil {
  let #(shown, phase) = case ask, state.stop {
    Halt, stacks.Sampling -> #(
      State(..state, stop: stacks.Stopped, ended_ms: ffi_proc.now_ms()),
      "stopped",
    )
    _, stacks.Sampling -> #(state, "running")
    _, _ -> #(state, "finished")
  }

  reply.send(
    reply_to,
    request,
    reply.stacks(
      state.config.id,
      phase,
      shown.stop,
      meter(shown),
      stacks.build(shown.aggregate),
    ),
  )
}

fn meter(state: State) -> reply.Meter {
  let end = case state.stop {
    stacks.Sampling -> ffi_proc.now_ms()
    _ -> state.ended_ms
  }
  let elapsed = end - state.started_ms
  let basis = case elapsed < 1 {
    True -> 1
    False -> elapsed
  }

  reply.Meter(
    requested_hz: state.config.rate_hz,
    achieved_millihz: state.rounds * 1_000_000 / basis,
    rounds: state.rounds,
    samples: state.aggregate.samples,
    elapsed_ms: elapsed,
    depth_limit: state.depth_limit,
    at_depth_limit: state.aggregate.at_depth_limit,
    targets_gone: state.targets_gone,
    dropped_samples: state.aggregate.dropped,
    distinct_stacks: state.aggregate.distinct,
  )
}

/// The node's `backtrace_depth`, found by asking for the stack of a process
/// that is `depth_probe` levels deep and counting how many frames the VM
/// returns. Nothing is changed or read from the system flag, which is global.
///
/// Two things keep the frames alive. Each level takes the larger of the inner
/// answer and zero, so the call is not a tail call. And each level goes
/// through `lists:foldl`, because the VM collapses consecutive frames of the
/// same function in a stack trace, and the compiler inlines local functions
/// that call each other: a function that calls itself, or two that call each
/// other, would report one frame and the measurement would read as a shallow
/// limit. Alternating a closure with `foldl` leaves frames of two different
/// functions on the stack.
///
/// ## Examples
///
/// ```gleam
/// depth_limit()
/// // -> 8
/// ```
pub fn depth_limit() -> Int {
  climb(depth_probe)
}

fn climb(remaining: Int) -> Int {
  case remaining {
    0 -> own_stack_length()
    _ -> fold_once(fn(_, _) { larger(climb(remaining - 1), 0) }, 0, [0])
  }
}

@external(erlang, "lists", "foldl")
fn fold_once(step: fn(Int, Int) -> Int, initial: Int, items: List(Int)) -> Int

@external(erlang, "erlang", "max")
fn larger(first: Int, second: Int) -> Int

fn own_stack_length() -> Int {
  let answer =
    ffi_proc.process_info(ffi_proc.self(), [ffi_proc.CurrentStacktrace])
  let found: List(Term) = ffi_term.coerce(answer)

  case found {
    [entry] -> seq.length(ffi_term.coerce(ffi_term.element(2, entry)))
    _ -> 0
  }
}
