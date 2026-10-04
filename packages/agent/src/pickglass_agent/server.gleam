//// The agent process: one long-lived registered process on the target.
////
//// The viewer pushes this package's modules into a running node and starts
//// `server` as a single process registered as `pickglass_agent`. The agent
//// owns everything that must outlive one request: the trace sessions, the pin
//// table, the `scheduler_wall_time` flag and the census workers. It exists
//// because those resources die with the process that created them, and a
//// request over distribution runs in a temporary process that ends when the
//// call returns.
////
//// This module is the documented exemption to the rule that process
//// machinery goes through weft. The agent cannot depend on weft, on
//// `gleam_otp` or on the standard library, because loading them would
//// replace the target's own copies of those modules. It uses a `gen_server`
//// for its receive loop, whose callbacks are the functions below, and keeps
//// the message set closed: `handle_info` classifies every message into one of
//// a request, a monitor `DOWN`, a `nodedown`, a timer tick or noise, and
//// drops what it does not recognise.
////
//// ## Flow
////
//// The viewer calls `start`, which decodes the start arguments and starts the
//// gen_server. `init` monitors the viewer's link process and the viewer's
//// node and arms a tick. `handle_info` then runs for every message:
//// `dispatch` answers a request, `on_down` handles a monitored process
//// ending, and `on_tick` enforces the lease and the probe deadlines. Anything
//// that ends the attach goes through `shut_down`, which destroys every
//// session and releases every flag, and then `terminate` hands the modules to
//// the janitor module.
////
//// ## Teardown
////
//// Four things end an agent: an explicit `detach`, the viewer's link process
//// dying, the viewer's node going down, and the lease expiring because the
//// viewer stopped pinging. All four reach `shut_down`. A crash in the agent
//// reaches `terminate`, which runs the same cleanup. A kill signal runs
//// neither, and the VM then destroys the sessions because the agent was
//// their sole holder.

import pickglass_agent/census
import pickglass_agent/counters.{type Probe}
import pickglass_agent/detail
import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_gen_server.{type Next, Noreply, Normal, Stop}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{
  type Atom, type Pid, type Reference, type Term,
}
import pickglass_agent/internal/ffi_trace.{type CounterMode}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/seq
import pickglass_agent/janitor
import pickglass_agent/measure
import pickglass_agent/owner
import pickglass_agent/reply.{type Failure, Failure}
import pickglass_agent/request.{type Envelope, type Token, Envelope}
import pickglass_agent/sampler
import pickglass_agent/supervision
import pickglass_agent/system

/// How often the agent looks at its lease and its probe deadlines.
const tick_ms = 250

/// The most processes the agent will pin at once.
const max_pins = 64

/// The most probes sampling or counting at once, of every kind together.
const max_running_probes = 2

/// The most stack probes sampling at once.
const max_running_stack_probes = 1

/// The most finished stack probes kept for reading. Each holds up to five
/// thousand stacks in its sampler's heap, so the bound is small.
const max_finished_stack_probes = 2

/// The heap a stack sampler may grow to, in words, before the VM kills it.
const sampler_heap_words = 4_000_000

/// How long past its deadline a sampler may keep sampling before the agent
/// kills it, in milliseconds.
const sampler_grace_ms = 2000

/// The most finished probes kept for reading.
const max_finished_probes = 8

/// The most workers at once, census and read-only probes together.
const max_workers = 4

/// The heap a census worker may grow to, in words, before the VM kills it.
const worker_heap_words = 1_000_000

/// The longest a census may walk, in milliseconds.
const census_deadline_ms = 2000

/// How long past its own deadline a worker may take to reply before the
/// agent kills it, in milliseconds. A worker stuck waiting on a process that
/// does not answer signals never reaches its own check.
const worker_grace_ms = 1000

/// The longest a single-process read may take, in milliseconds.
const read_deadline_ms = 2000

/// How the agent is configured at start.
pub type Config {
  Config(
    /// The viewer's link process. Its death ends the attach.
    viewer: Pid,
    /// An identifier the viewer generated for this attach. Pin tokens are
    /// bound to it, so a token from an earlier agent is refused.
    boot_id: String,
    /// How long the agent waits without hearing from the viewer before it
    /// tears itself down, in milliseconds.
    lease_ms: Int,
  )
}

/// A process the viewer asked the agent to watch.
pub type Pin {
  Pin(id: Int, pid: Pid, text: String, monitor: Reference)
}

/// A read-only request running in a worker process, so that a slow answer
/// never delays the agent's handling of a lost viewer. `kind` names the
/// request in the refusal the agent sends when the worker dies or overruns
/// `deadline_at_ms`.
pub type Worker {
  Worker(
    pid: Pid,
    monitor: Reference,
    reply_to: Pid,
    request: Reference,
    kind: String,
    deadline_at_ms: Int,
  )
}

/// Whether a stack probe is still sampling or has ended and waits to be read.
pub type StackPhase {
  StackSampling
  StackDone
}

/// A stack sampling probe: the sampler process, its monitor and its
/// deadline. The aggregate lives in the sampler, not here.
pub type StackProbe {
  StackProbe(
    id: Int,
    sampler: Pid,
    monitor: Reference,
    deadline_at_ms: Int,
    phase: StackPhase,
  )
}

/// Whether the agent holds the `scheduler_wall_time` flag.
pub type Scheduler {
  Collecting
  NotCollecting
}

/// The agent's state.
pub type State {
  State(
    config: Config,
    viewer_monitor: Reference,
    viewer_node: Atom,
    started_ms: Int,
    last_heard_ms: Int,
    pins: List(Pin),
    next_pin: Int,
    probes: List(Probe),
    stacks: List(StackProbe),
    next_probe: Int,
    workers: List(Worker),
    scheduler: Scheduler,
  )
}

/// The messages the agent sends itself, and the one `nodedown` notice the
/// VM sends it. Each is the atom of the same name.
type Notice {
  Tick
  Nodedown
}

/// Why an attach ended, as the viewer sees it in `detached` replies.
type Cause {
  Requested
  ViewerGone
  NodeDown
  LeaseExpired
}

type Event {
  Asked(Envelope)
  Refused(reply_to: Pid, reference: Reference, detail: String)
  Ticked
  StacksFinished(id: Int)
  Exited(monitor: Reference, reason: Term)
  NodeLost(node: Atom)
  Ignored
}

/// Start the agent. The viewer calls this over `erpc` after pushing the
/// modules. `args` is `{ViewerPid, BootId, LeaseMs}`; anything else is
/// refused. The agent is started unlinked from the caller, which is a
/// temporary process that ends when the call returns.
///
/// Returns `{ok, Pid}`, `{error, {already_started, Pid}}` when another
/// viewer is attached, or `{error, Reason}`.
///
/// ## Examples
///
/// ```gleam
/// start(coerce(#(viewer_pid, "boot-1", 30_000)))
/// // -> {ok, Pid}
/// ```
pub fn start(args: Term) -> Term {
  case decode_config(args) {
    Ok(config) ->
      ffi_gen_server.start(
        ffi_term.atom("pickglass_agent@server"),
        ffi_term.coerce(config),
      )
    Error(Nil) ->
      ffi_term.coerce(#(ffi_term.atom("error"), "bad_start_arguments"))
  }
}

fn decode_config(args: Term) -> Result(Config, Nil) {
  case
    ffi_term.is_tuple(args)
    && ffi_term.tuple_size(args) == 3
    && ffi_term.is_pid(ffi_term.element(1, args))
    && ffi_term.is_binary(ffi_term.element(2, args))
    && ffi_term.is_integer(ffi_term.element(3, args))
  {
    False -> Error(Nil)
    True ->
      Ok(Config(
        viewer: ffi_term.coerce(ffi_term.element(1, args)),
        boot_id: ffi_term.coerce(ffi_term.element(2, args)),
        lease_ms: request.clamp(
          ffi_term.coerce(ffi_term.element(3, args)),
          1000,
          600_000,
        ),
      ))
  }
}

/// The `gen_server` init callback. Watches the viewer's process and node and
/// arms the first tick.
pub fn init(config: Config) -> Result(State, Nil) {
  owner.claim_self()

  let now = ffi_proc.now_ms()
  let viewer_node = ffi_proc.node_of(config.viewer)
  let monitor = ffi_proc.monitor(ffi_proc.Process, config.viewer)

  let _ = ffi_proc.monitor_node_flag(viewer_node, ffi_term.coerce(True))
  let _ = ffi_proc.send_after(tick_ms, ffi_proc.self(), ffi_term.coerce(Tick))

  Ok(State(
    config: config,
    viewer_monitor: monitor,
    viewer_node: viewer_node,
    started_ms: now,
    last_heard_ms: now,
    pins: [],
    next_pin: 1,
    probes: [],
    stacks: [],
    next_probe: 1,
    workers: [],
    scheduler: NotCollecting,
  ))
}

/// The `gen_server` callback for every message. A message that is not one of
/// the closed set is dropped.
pub fn handle_info(message: Term, state: State) -> Next(State) {
  case classify(message) {
    Asked(envelope) ->
      dispatch(envelope, State(..state, last_heard_ms: ffi_proc.now_ms()))
    Refused(reply_to, reference, detail) -> {
      reply.send(
        reply_to,
        reference,
        reply.failure(Failure("bad_request", detail)),
      )

      Noreply(state)
    }
    Ticked -> on_tick(state)
    StacksFinished(id) -> Noreply(mark_stacks_done(state, id))
    Exited(monitor, reason) -> on_down(monitor, reason, state)
    NodeLost(node) ->
      case node == state.viewer_node {
        True -> stop(state, NodeDown)
        False -> Noreply(state)
      }
    Ignored -> Noreply(state)
  }
}

/// The `gen_server` terminate callback. Runs on every exit the VM lets the
/// agent observe, including a crash in one of the handlers above, and
/// repeats the cleanup so that a crash cannot leave a session behind. It then
/// starts the janitor that unloads the agent's modules.
pub fn terminate(_reason: Term, state: State) -> Nil {
  let _ = shut_down(state)

  janitor.unload_after_exit(ffi_proc.self())
}

fn classify(message: Term) -> Event {
  case message == ffi_term.coerce(Tick) {
    True -> Ticked
    False -> classify_tuple(message)
  }
}

fn classify_tuple(message: Term) -> Event {
  case request.decode(message) {
    request.Valid(envelope) -> Asked(envelope)
    request.Malformed(reply_to, reference, detail) ->
      Refused(reply_to, reference, detail)
    request.NotARequest -> classify_notice(message)
  }
}

fn classify_notice(message: Term) -> Event {
  case ffi_term.is_tuple(message) {
    False -> Ignored
    True ->
      case is_down(message), is_nodedown(message), is_stacks_finished(message) {
        True, _, _ ->
          Exited(
            ffi_term.coerce(ffi_term.element(2, message)),
            ffi_term.element(5, message),
          )
        False, True, _ ->
          NodeLost(ffi_term.coerce(ffi_term.element(2, message)))
        False, False, True ->
          StacksFinished(ffi_term.coerce(ffi_term.element(2, message)))
        False, False, False -> Ignored
      }
  }
}

// `{pickglass_stacks_finished, ProbeId}`, which a sampler sends when it stops
// sampling on its own.
fn is_stacks_finished(message: Term) -> Bool {
  ffi_term.tuple_size(message) == 2
  && ffi_term.element(1, message) == ffi_term.coerce(sampler.finished_tag())
  && ffi_term.is_integer(ffi_term.element(2, message))
}

// `{'DOWN', Ref, process, Pid, Reason}`.
fn is_down(message: Term) -> Bool {
  ffi_term.tuple_size(message) == 5
  && ffi_term.element(1, message) == ffi_term.coerce(ffi_term.atom("DOWN"))
  && ffi_term.is_reference(ffi_term.element(2, message))
}

// `{nodedown, Node}`.
fn is_nodedown(message: Term) -> Bool {
  ffi_term.tuple_size(message) == 2
  && ffi_term.element(1, message) == ffi_term.coerce(Nodedown)
  && ffi_term.is_atom(ffi_term.element(2, message))
}

// ----------------------------------------------------------------- requests

fn dispatch(envelope: Envelope, state: State) -> Next(State) {
  let Envelope(reply_to, reference, request) = envelope

  case request {
    request.Detach -> detach(state, reply_to, reference)
    request.Ping -> answer(state, reply_to, reference, ping(state))
    request.MemoryReport -> answer(state, reply_to, reference, memory())
    request.Census(max_scanned, top_k) ->
      census_request(state, reply_to, reference, max_scanned, top_k)
    request.ProcessDetail(token) ->
      process_detail(state, reply_to, reference, token)
    request.Supervision(max_scanned, max_edges) ->
      supervision_request(state, reply_to, reference, max_scanned, max_edges)
    request.TargetedGc(token, deadline_ms) ->
      targeted_gc(state, reply_to, reference, token, deadline_ms)
    request.SelfMeasure(token, budget_ms) ->
      self_measure(state, reply_to, reference, token, budget_ms)
    request.StartStacks(tokens, rate_hz, duration_ms, max_samples) ->
      start_stacks(
        state,
        reply_to,
        reference,
        tokens,
        rate_hz,
        duration_ms,
        max_samples,
      )
    request.ReadStacks(id) -> read_stacks(state, reply_to, reference, id)
    request.StopStacks(id) -> stop_stacks(state, reply_to, reference, id)
    request.SystemReport ->
      start_worker(state, reply_to, reference, "system", read_deadline_ms, fn() {
        reply.system(system.read())
      })
    request.Pin(text) -> pin(state, reply_to, reference, text)
    request.Unpin(token) -> unpin(state, reply_to, reference, token)
    request.Scheduler(action) -> scheduler(state, reply_to, reference, action)
    request.StartCounters(patterns, targets, deadline_ms, mode) ->
      start_counters(
        state,
        reply_to,
        reference,
        patterns,
        targets,
        deadline_ms,
        mode,
      )
    request.ReadCounters(id) -> read_counters(state, reply_to, reference, id)
    request.StopCounters(id) -> stop_counters(state, reply_to, reference, id)
  }
}

fn answer(
  state: State,
  to: Pid,
  reference: Reference,
  body: Term,
) -> Next(State) {
  reply.send(to, reference, body)

  Noreply(state)
}

fn refuse(
  state: State,
  to: Pid,
  reference: Reference,
  code: String,
  detail: String,
) -> Next(State) {
  answer(state, to, reference, reply.failure(Failure(code, detail)))
}

fn ping(state: State) -> Term {
  reply.pong(
    state.config.boot_id,
    ffi_term.atom_name(ffi_vm.node_name()),
    ffi_vm.otp_release(),
    ffi_proc.now_ms() - state.started_ms,
    seq.length(state.pins),
    running_count(state.probes) + sampling_count(state.stacks),
  )
}

fn memory() -> Term {
  reply.memory(
    seq.map(ffi_vm.memory(), fn(entry) {
      #(ffi_term.atom_name(entry.0), entry.1)
    }),
    ffi_vm.word_size(),
    ffi_vm.process_count(),
    ffi_vm.otp_release(),
    ffi_vm.erts_version(),
    ffi_vm.schedulers_online(),
  )
}

// A census runs in a worker so that a long walk never delays the agent's
// handling of a lost viewer. The worker replies to the requester itself; the
// agent only watches it, so that a worker killed by its heap cap or by its
// deadline still produces an answer.
fn census_request(
  state: State,
  reply_to: Pid,
  reference: Reference,
  max_scanned: Int,
  top_k: Int,
) -> Next(State) {
  let budget = census.Budget(max_scanned, top_k, census_deadline_ms)

  start_worker(state, reply_to, reference, "census", census_deadline_ms, fn() {
    reply.census(census.run(budget))
  })
}

// Spawns a worker that computes one reply body and sends it to the
// requester. The worker is monitored, capped in heap, and given a deadline
// the tick enforces, so every way it can fail ends in a reply.
fn start_worker(
  state: State,
  reply_to: Pid,
  reference: Reference,
  kind: String,
  deadline_ms: Int,
  compute: fn() -> Term,
) -> Next(State) {
  start_process(state, reply_to, reference, kind, deadline_ms, fn() {
    let #(pid, monitor) =
      ffi_proc.spawn_opt(
        fn() {
          owner.claim_self()
          reply.send(reply_to, reference, compute())
        },
        [ffi_proc.Monitor, ffi_proc.heap_limit(worker_heap_words)],
      )

    Ok(#(pid, monitor))
  })
}

// Registers a process the agent started for one request, whatever way it
// was started. `launch` returns the process and a monitor on it, or `Error`
// when it could not be started. The agent keeps the process in `workers` so
// that its deadline, its abnormal exit and the agent's own teardown all end
// in a reply or a kill.
fn start_process(
  state: State,
  reply_to: Pid,
  reference: Reference,
  kind: String,
  deadline_ms: Int,
  launch: fn() -> Result(#(Pid, Reference), Nil),
) -> Next(State) {
  case seq.length(state.workers) >= max_workers {
    True ->
      refuse(
        state,
        reply_to,
        reference,
        "busy",
        "the agent is already running as many reads as it allows",
      )
    False ->
      case launch() {
        Error(Nil) ->
          refuse(
            state,
            reply_to,
            reference,
            "start_failed",
            "the agent could not start a process for " <> kind,
          )
        Ok(#(pid, monitor)) -> {
          let deadline_at = ffi_proc.now_ms() + deadline_ms + worker_grace_ms

          Noreply(
            State(..state, workers: [
              Worker(pid, monitor, reply_to, reference, kind, deadline_at),
              ..state.workers
            ]),
          )
        }
      }
  }
}

// A targeted collection runs in a worker for the same reason a detail read
// does: the collection is a signal to a process that may be slow to handle
// it. The worker reads the heap, collects and waits, and reads again; the
// collection call blocks until the target has collected, so the deadline is
// the worker's. A target that never gets to it is a `deadline` refusal.
fn targeted_gc(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
  deadline_ms: Int,
) -> Next(State) {
  case find_pin(state, token) {
    Error(Nil) -> refuse_stale_pin(state, reply_to, reference)
    Ok(entry) ->
      start_worker(state, reply_to, reference, "gc", deadline_ms, fn() {
        collect(entry.pid)
      })
  }
}

fn collect(pid: Pid) -> Term {
  let started = ffi_proc.now_ms()
  let before = detail.read_heap(pid)

  case before {
    Error(Nil) -> collected(pid, "target_gone", started, before, Error(Nil))
    Ok(_) -> {
      let outcome = case
        ffi_proc.garbage_collect(pid, [ffi_proc.Type(ffi_proc.Major)])
      {
        True -> "completed"
        False -> "target_gone"
      }

      collected(pid, outcome, started, before, detail.read_heap(pid))
    }
  }
}

fn collected(
  pid: Pid,
  outcome: String,
  started: Int,
  before: Result(detail.Heap, Nil),
  after: Result(detail.Heap, Nil),
) -> Term {
  reply.collection(
    ffi_term.pid_text(pid),
    outcome,
    ffi_proc.now_ms() - started,
    before,
    after,
  )
}

// A self-measurement runs in a helper gen_server, because the reply is a
// message and the agent has nothing to receive it with that does not also
// block its own teardown.
fn self_measure(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
  budget_ms: Int,
) -> Next(State) {
  case find_pin(state, token) {
    Error(Nil) -> refuse_stale_pin(state, reply_to, reference)
    Ok(entry) ->
      start_process(state, reply_to, reference, "measure", budget_ms, fn() {
        case
          measure.start(
            measure.Config(entry.pid, reply_to, reference, budget_ms),
            worker_heap_words,
          )
        {
          Ok(pid) -> Ok(#(pid, ffi_proc.monitor(ffi_proc.Process, pid)))
          Error(Nil) -> Error(Nil)
        }
      })
  }
}

fn supervision_request(
  state: State,
  reply_to: Pid,
  reference: Reference,
  max_scanned: Int,
  max_edges: Int,
) -> Next(State) {
  let budget = supervision.Budget(max_scanned, max_edges, census_deadline_ms)

  start_worker(
    state,
    reply_to,
    reference,
    "supervision",
    census_deadline_ms,
    fn() { reply.supervision(supervision.run(budget)) },
  )
}

fn process_detail(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
) -> Next(State) {
  case find_pin(state, token) {
    Error(Nil) -> refuse_stale_pin(state, reply_to, reference)
    Ok(entry) ->
      start_worker(
        state,
        reply_to,
        reference,
        "process_detail",
        read_deadline_ms,
        fn() {
          case detail.read(entry.pid) {
            Ok(found) -> reply.process_detail(found)
            Error(Nil) -> reply.failure(target_gone())
          }
        },
      )
  }
}

fn target_gone() -> Failure {
  Failure("target_gone", "the process exited or could not be read")
}

fn refuse_stale_pin(
  state: State,
  to: Pid,
  reference: Reference,
) -> Next(State) {
  refuse(
    state,
    to,
    reference,
    "stale_pin",
    "that pin does not exist or belongs to an earlier agent",
  )
}

fn pin(
  state: State,
  reply_to: Pid,
  reference: Reference,
  text: String,
) -> Next(State) {
  case resolve_pid(text) {
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "no_such_process",
        "no live local process has that identifier",
      )
    Ok(pid) ->
      case find_pin_by_pid(state.pins, pid) {
        Ok(existing) ->
          answer(state, reply_to, reference, pinned(state, existing))
        Error(Nil) -> add_pin(state, reply_to, reference, pid, text)
      }
  }
}

fn add_pin(
  state: State,
  reply_to: Pid,
  reference: Reference,
  pid: Pid,
  text: String,
) -> Next(State) {
  case seq.length(state.pins) >= max_pins {
    True ->
      refuse(
        state,
        reply_to,
        reference,
        "pin_table_full",
        "the pin table is full",
      )
    False -> {
      let entry =
        Pin(
          id: state.next_pin,
          pid: pid,
          text: text,
          monitor: ffi_proc.monitor(ffi_proc.Process, pid),
        )

      answer(
        State(
          ..state,
          pins: [entry, ..state.pins],
          next_pin: state.next_pin + 1,
        ),
        reply_to,
        reference,
        pinned(state, entry),
      )
    }
  }
}

fn pinned(state: State, entry: Pin) -> Term {
  reply.pinned(state.config.boot_id, entry.id, entry.text)
}

// The text came from outside, so the conversion goes through the catching
// call. A pid of another node, or one that has exited, is not a target.
fn resolve_pid(text: String) -> Result(Pid, Nil) {
  use pid <- fallible.then(
    ffi_safe.call(ffi_safe.Erlang, ffi_safe.ListToPid, [
      ffi_term.coerce(ffi_term.charlist(text)),
    ]),
  )

  case ffi_term.is_pid(pid) {
    False -> Error(Nil)
    True -> {
      let local: Pid = ffi_term.coerce(pid)

      case
        ffi_proc.node_of(local) == ffi_vm.node_name()
        && ffi_proc.is_alive(local)
      {
        True -> Ok(local)
        False -> Error(Nil)
      }
    }
  }
}

fn find_pin_by_pid(pins: List(Pin), pid: Pid) -> Result(Pin, Nil) {
  case pins {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.pid == pid {
        True -> Ok(entry)
        False -> find_pin_by_pid(rest, pid)
      }
  }
}

fn find_pin(state: State, token: Token) -> Result(Pin, Nil) {
  case token.boot_id == state.config.boot_id {
    False -> Error(Nil)
    True -> find_pin_by_id(state.pins, token.pin_id)
  }
}

fn find_pin_by_id(pins: List(Pin), id: Int) -> Result(Pin, Nil) {
  case pins {
    [] -> Error(Nil)
    [entry, ..rest] ->
      case entry.id == id {
        True -> Ok(entry)
        False -> find_pin_by_id(rest, id)
      }
  }
}

fn unpin(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
) -> Next(State) {
  case find_pin(state, token) {
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "stale_pin",
        "that pin does not exist or belongs to an earlier agent",
      )
    Ok(entry) -> {
      let _ = ffi_proc.demonitor(entry.monitor, [ffi_proc.Flush])

      answer(
        State(
          ..state,
          pins: seq.filter(state.pins, fn(other) { other.id != entry.id }),
        ),
        reply_to,
        reference,
        reply.unpinned(entry.id),
      )
    }
  }
}

fn scheduler(
  state: State,
  reply_to: Pid,
  reference: Reference,
  action: request.SchedulerAction,
) -> Next(State) {
  let next = case action {
    request.SchedulerOn -> switch_scheduler(state, Collecting)
    request.SchedulerOff -> switch_scheduler(state, NotCollecting)
    request.SchedulerRead -> state
  }

  answer(next, reply_to, reference, scheduler_reply(next))
}

fn switch_scheduler(state: State, wanted: Scheduler) -> State {
  case state.scheduler, wanted {
    NotCollecting, Collecting -> {
      ffi_vm.enable_scheduler_wall_time()

      State(..state, scheduler: Collecting)
    }
    Collecting, NotCollecting -> {
      ffi_vm.disable_scheduler_wall_time()

      State(..state, scheduler: NotCollecting)
    }
    Collecting, Collecting -> state
    NotCollecting, NotCollecting -> state
  }
}

fn scheduler_reply(state: State) -> Term {
  let readings = ffi_vm.scheduler_wall_time()
  let rows = case ffi_term.is_atom(readings) {
    True -> []
    False -> ffi_term.coerce(readings)
  }

  reply.scheduler(
    case state.scheduler {
      Collecting -> "collecting"
      NotCollecting -> "not_collecting"
    },
    rows,
  )
}

// ----------------------------------------------------------------- counters

fn start_counters(
  state: State,
  reply_to: Pid,
  reference: Reference,
  patterns: List(request.Pattern),
  targets: request.Targets,
  deadline_ms: Int,
  mode: CounterMode,
) -> Next(State) {
  let started = {
    use _ <- fallible.then(check_probe_room(state))
    use resolved <- fallible.then(resolve_patterns(patterns, []))
    use selection <- fallible.then(select(state, targets))
    use probe <- fallible.then(start_probe(
      state,
      resolved,
      mode,
      selection,
      deadline_ms,
    ))

    Ok(probe)
  }

  case started {
    Error(failure) -> answer(state, reply_to, reference, reply.failure(failure))
    Ok(probe) ->
      answer(
        State(
          ..state,
          probes: [probe, ..state.probes],
          next_probe: state.next_probe + 1,
        ),
        reply_to,
        reference,
        reply.counters_started(probe.id, probe.matched, deadline_ms),
      )
  }
}

fn start_probe(
  state: State,
  patterns: List(counters.Pattern),
  mode: CounterMode,
  selection: counters.Selection,
  deadline_ms: Int,
) -> Result(Probe, Failure) {
  case
    counters.start(
      state.next_probe,
      ffi_proc.self(),
      patterns,
      mode,
      selection,
      deadline_ms,
    )
  {
    Ok(probe) -> Ok(probe)
    Error(counters.Refusal(code, detail)) -> Error(Failure(code, detail))
  }
}

fn check_probe_room(state: State) -> Result(Nil, Failure) {
  case
    running_count(state.probes) + sampling_count(state.stacks)
    >= max_running_probes
  {
    True -> Error(Failure("probe_limit", "two probes are already running"))
    False -> Ok(Nil)
  }
}

// Every name in the set resolves to an atom the node already has, or the
// whole request is refused: an unknown name is never turned into a new atom.
fn resolve_patterns(
  patterns: List(request.Pattern),
  acc: List(counters.Pattern),
) -> Result(List(counters.Pattern), Failure) {
  case patterns {
    [] -> Ok(seq.reverse(acc))
    [pattern, ..rest] -> {
      use module <- fallible.then(resolve_name(pattern.module, "unknown_module"))
      use function <- fallible.then(resolve_name(
        pattern.function,
        "unknown_function",
      ))

      resolve_patterns(rest, [counters.Pattern(module, function), ..acc])
    }
  }
}

// A name from a request resolves only to an atom the node already has. An
// unknown name is a refusal, never a new atom.
fn resolve_name(name: String, code: String) -> Result(Atom, Failure) {
  case ffi_safe.existing_atom(name) {
    Ok(atom) -> Ok(atom)
    Error(Nil) -> Error(Failure(code, "the node has no such name loaded"))
  }
}

fn select(
  state: State,
  targets: request.Targets,
) -> Result(counters.Selection, Failure) {
  case targets {
    request.AllProcesses -> Ok(counters.EveryProcess)
    request.PinnedProcesses(tokens) -> {
      use pids <- fallible.then(pids_of(state, tokens, []))

      Ok(counters.TheseProcesses(pids))
    }
  }
}

fn pids_of(
  state: State,
  tokens: List(Token),
  acc: List(Pid),
) -> Result(List(Pid), Failure) {
  case tokens {
    [] -> Ok(seq.reverse(acc))
    [token, ..rest] ->
      case find_pin(state, token) {
        Ok(entry) -> pids_of(state, rest, [entry.pid, ..acc])
        Error(Nil) ->
          Error(Failure(
            "stale_pin",
            "a target's pin does not exist or the process exited",
          ))
      }
  }
}

fn find_probe(probes: List(Probe), id: Int) -> Result(Probe, Nil) {
  case probes {
    [] -> Error(Nil)
    [probe, ..rest] ->
      case probe.id == id {
        True -> Ok(probe)
        False -> find_probe(rest, id)
      }
  }
}

fn read_counters(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_probe(state.probes, id) {
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "no_such_probe",
        "no probe has that id",
      )
    Ok(probe) ->
      answer(state, reply_to, reference, probe_reply(probe, snapshot_of(probe)))
  }
}

fn stop_counters(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_probe(state.probes, id) {
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "no_such_probe",
        "no probe has that id",
      )
    Ok(probe) -> {
      let finished = counters.finish(probe)

      answer(
        State(
          ..state,
          probes: seq.filter(state.probes, fn(other) { other.id != id }),
        ),
        reply_to,
        reference,
        probe_reply(finished, snapshot_of(finished)),
      )
    }
  }
}

// A running probe is read in place; a finished one already holds its
// snapshot. The state name tells the viewer which.
fn snapshot_of(probe: Probe) -> counters.Snapshot {
  case probe.phase {
    counters.Running(session) ->
      counters.collect(session, probe.patterns, probe.mode)
    counters.Finished(snapshot) -> snapshot
  }
}

fn probe_reply(probe: Probe, snapshot: counters.Snapshot) -> Term {
  reply.counters(
    probe.id,
    case probe.phase {
      counters.Running(_) -> "running"
      counters.Finished(_) -> "finished"
    },
    probe.matched,
    ffi_proc.now_ms() - probe.started_ms,
    snapshot,
  )
}

fn running_count(probes: List(Probe)) -> Int {
  seq.length(seq.filter(probes, is_running))
}

fn is_running(probe: Probe) -> Bool {
  case probe.phase {
    counters.Running(_) -> True
    counters.Finished(_) -> False
  }
}

// -------------------------------------------------------------------- stacks

fn start_stacks(
  state: State,
  reply_to: Pid,
  reference: Reference,
  tokens: List(Token),
  rate_hz: Int,
  duration_ms: Int,
  max_samples: Int,
) -> Next(State) {
  let started = {
    use _ <- fallible.then(check_probe_room(state))
    use _ <- fallible.then(check_stack_room(state))
    use pids <- fallible.then(pids_of(state, tokens, []))
    use sampler_pid <- fallible.then(
      start_sampler(sampler.Config(
        agent: ffi_proc.self(),
        id: state.next_probe,
        targets: pids,
        rate_hz: rate_hz,
        duration_ms: duration_ms,
        max_samples: max_samples,
      )),
    )

    Ok(#(sampler_pid, seq.length(pids)))
  }

  case started {
    Error(failure) -> answer(state, reply_to, reference, reply.failure(failure))
    Ok(#(sampler_pid, targets)) -> {
      let probe =
        StackProbe(
          id: state.next_probe,
          sampler: sampler_pid,
          monitor: ffi_proc.monitor(ffi_proc.Process, sampler_pid),
          deadline_at_ms: ffi_proc.now_ms() + duration_ms,
          phase: StackSampling,
        )

      answer(
        State(
          ..state,
          stacks: [probe, ..state.stacks],
          next_probe: state.next_probe + 1,
        ),
        reply_to,
        reference,
        reply.stacks_started(
          probe.id,
          targets,
          rate_hz,
          duration_ms,
          max_samples,
        ),
      )
    }
  }
}

fn check_stack_room(state: State) -> Result(Nil, Failure) {
  case sampling_count(state.stacks) >= max_running_stack_probes {
    True -> Error(Failure("probe_limit", "a stack probe is already sampling"))
    False -> Ok(Nil)
  }
}

fn start_sampler(config: sampler.Config) -> Result(Pid, Failure) {
  case sampler.start(config, sampler_heap_words) {
    Ok(pid) -> Ok(pid)
    Error(Nil) ->
      Error(Failure("start_failed", "the agent could not start a sampler"))
  }
}

fn find_stack_probe(
  probes: List(StackProbe),
  id: Int,
) -> Result(StackProbe, Nil) {
  case probes {
    [] -> Error(Nil)
    [probe, ..rest] ->
      case probe.id == id {
        True -> Ok(probe)
        False -> find_stack_probe(rest, id)
      }
  }
}

// A read is answered by the sampler, which holds the aggregate. The agent
// only forwards the request, so it never copies a probe's table.
fn read_stacks(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_stack_probe(state.stacks, id) {
    Error(Nil) -> refuse_no_such_probe(state, reply_to, reference)
    Ok(probe) -> {
      sampler.read(probe.sampler, reply_to, reference)

      Noreply(state)
    }
  }
}

// A stop is answered by the sampler with its final snapshot, and the sampler
// then exits. The agent drops the probe at once and removes the monitor, so
// the sampler's exit is not mistaken for a crash.
fn stop_stacks(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_stack_probe(state.stacks, id) {
    Error(Nil) -> refuse_no_such_probe(state, reply_to, reference)
    Ok(probe) -> {
      let _ = ffi_proc.demonitor(probe.monitor, [ffi_proc.Flush])

      sampler.stop(probe.sampler, reply_to, reference)

      Noreply(
        State(
          ..state,
          stacks: seq.filter(state.stacks, fn(other) { other.id != id }),
        ),
      )
    }
  }
}

fn refuse_no_such_probe(
  state: State,
  to: Pid,
  reference: Reference,
) -> Next(State) {
  refuse(state, to, reference, "no_such_probe", "no probe has that id")
}

fn mark_stacks_done(state: State, id: Int) -> State {
  State(
    ..state,
    stacks: seq.map(state.stacks, fn(probe) {
      case probe.id == id {
        True -> StackProbe(..probe, phase: StackDone)
        False -> probe
      }
    }),
  )
}

fn sampling_count(probes: List(StackProbe)) -> Int {
  seq.length(seq.filter(probes, fn(probe) { probe.phase == StackSampling }))
}

// A sampler that has not stopped well after its deadline is stuck, most
// likely on a target that does not answer signals, and is killed. The
// finished probes kept for reading are bounded, and the oldest is killed when
// there are too many, because its sampler's heap is the memory they cost.
fn expire_stacks(probes: List(StackProbe), now: Int) -> List(StackProbe) {
  let live =
    seq.filter(probes, fn(probe) {
      case
        probe.phase == StackSampling
        && now >= probe.deadline_at_ms + sampler_grace_ms
      {
        True -> {
          kill_stack_probe(probe)

          False
        }
        False -> True
      }
    })

  case seq.length(live) - sampling_count(live) > max_finished_stack_probes {
    False -> live
    True -> seq.reverse(drop_oldest_done(seq.reverse(live)))
  }
}

fn drop_oldest_done(oldest_first: List(StackProbe)) -> List(StackProbe) {
  case oldest_first {
    [] -> []
    [probe, ..rest] ->
      case probe.phase {
        StackSampling -> [probe, ..drop_oldest_done(rest)]
        StackDone -> {
          kill_stack_probe(probe)

          rest
        }
      }
  }
}

fn kill_stack_probe(probe: StackProbe) -> Nil {
  let _ = ffi_proc.demonitor(probe.monitor, [ffi_proc.Flush])
  let _ = ffi_proc.exit_with(probe.sampler, ffi_proc.Kill)

  Nil
}

// ------------------------------------------------------------ time and exits

// Each tick enforces two deadlines: the viewer's lease, and every running
// probe's own. A probe past its deadline is collected and its session
// destroyed in this handler, so no probe outlives its deadline by more than a
// tick. The tick is re-armed last, after everything it may have changed.
fn on_tick(state: State) -> Next(State) {
  let now = ffi_proc.now_ms()

  case now - state.last_heard_ms > state.config.lease_ms {
    True -> stop(state, LeaseExpired)
    False -> {
      let _ =
        ffi_proc.send_after(tick_ms, ffi_proc.self(), ffi_term.coerce(Tick))

      Noreply(
        State(
          ..state,
          probes: expire_probes(state.probes, now),
          stacks: expire_stacks(state.stacks, now),
          workers: expire_workers(state.workers, now),
        ),
      )
    }
  }
}

// A worker past its deadline is killed and the requester is told. The monitor
// is removed first, with its message flushed, so the kill does not also reach
// `on_worker_down` and produce a second refusal.
fn expire_workers(workers: List(Worker), now: Int) -> List(Worker) {
  seq.filter(workers, fn(worker) {
    case now >= worker.deadline_at_ms {
      False -> True
      True -> {
        let _ = ffi_proc.demonitor(worker.monitor, [ffi_proc.Flush])
        let _ = ffi_proc.exit_with(worker.pid, ffi_proc.Kill)

        reply.send(
          worker.reply_to,
          worker.request,
          reply.failure(Failure(
            "deadline",
            "the " <> worker.kind <> " did not finish in time",
          )),
        )

        False
      }
    }
  })
}

fn expire_probes(probes: List(Probe), now: Int) -> List(Probe) {
  let advanced =
    seq.map(probes, fn(probe) {
      case is_running(probe) && now >= probe.deadline_at_ms {
        True -> counters.finish(probe)
        False -> probe
      }
    })

  drop_oldest_finished(advanced)
}

// Finished probes wait to be read. The list is bounded, and the oldest
// finished probe is dropped first when it overflows.
fn drop_oldest_finished(probes: List(Probe)) -> List(Probe) {
  let finished = seq.length(probes) - running_count(probes)

  case finished > max_finished_probes {
    False -> probes
    True -> seq.reverse(drop_one_finished(seq.reverse(probes)))
  }
}

fn drop_one_finished(oldest_first: List(Probe)) -> List(Probe) {
  case oldest_first {
    [] -> []
    [probe, ..rest] ->
      case is_running(probe) {
        True -> [probe, ..drop_one_finished(rest)]
        False -> rest
      }
  }
}

fn on_down(monitor: Reference, reason: Term, state: State) -> Next(State) {
  case monitor == state.viewer_monitor {
    True -> stop(state, ViewerGone)
    False ->
      Noreply(
        State(
          ..on_worker_down(monitor, reason, state),
          pins: seq.filter(state.pins, fn(entry) { entry.monitor != monitor }),
          stacks: seq.filter(state.stacks, fn(probe) {
            probe.monitor != monitor
          }),
        ),
      )
  }
}

// A worker ends normally after it has replied. Any other exit, such as the
// VM killing it for passing its heap cap, leaves the requester without an
// answer, so the agent sends the refusal on the worker's behalf.
fn on_worker_down(monitor: Reference, reason: Term, state: State) -> State {
  let #(finished, rest) =
    seq.fold(state.workers, #([], []), fn(acc, worker) {
      case worker.monitor == monitor {
        True -> #([worker, ..acc.0], acc.1)
        False -> #(acc.0, [worker, ..acc.1])
      }
    })

  seq.each(finished, fn(worker) {
    case reason == ffi_term.coerce(Normal) {
      True -> Nil
      False ->
        reply.send(
          worker.reply_to,
          worker.request,
          reply.failure(Failure(
            worker.kind <> "_failed",
            "the " <> worker.kind <> " worker ended before it could answer",
          )),
        )
    }
  })

  State(..state, workers: rest)
}

// ----------------------------------------------------------------- teardown

fn detach(state: State, reply_to: Pid, reference: Reference) -> Next(State) {
  let stopped = shut_down(state)

  reply.send(reply_to, reference, reply.detached(cause_name(Requested)))

  Stop(Normal, stopped)
}

fn stop(state: State, cause: Cause) -> Next(State) {
  let _ = cause_name(cause)

  Stop(Normal, shut_down(state))
}

fn cause_name(cause: Cause) -> String {
  case cause {
    Requested -> "requested"
    ViewerGone -> "viewer_gone"
    NodeDown -> "node_down"
    LeaseExpired -> "lease_expired"
  }
}

// Releases everything the agent holds on the target and returns the state
// with nothing left to release, so that running it a second time, from
// `terminate` after a request-driven stop, does nothing. Sessions are
// destroyed explicitly rather than left to the VM, because the explicit path
// is the one that has already returned by the time the viewer is told.
fn shut_down(state: State) -> State {
  seq.each(state.probes, counters.destroy)
  seq.each(state.stacks, kill_stack_probe)
  seq.each(state.workers, fn(worker) {
    ffi_proc.exit_with(worker.pid, ffi_proc.Kill)
  })

  case state.scheduler {
    Collecting -> ffi_vm.disable_scheduler_wall_time()
    NotCollecting -> Nil
  }

  State(
    ..state,
    probes: [],
    stacks: [],
    workers: [],
    pins: [],
    scheduler: NotCollecting,
  )
}
