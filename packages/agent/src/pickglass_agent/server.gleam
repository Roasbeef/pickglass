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
//// One agent serves every viewer attached to its node. The first viewer
//// pushes and starts it; a later viewer of the same build asks to `join`, and
//// the agent adds it to its `viewers` table. A viewer is known by its link
//// process, the reply address of its requests. Every pin, probe and worker
//// carries the pid of the viewer that made it, and every lookup by token or
//// probe id also names the requester, so a viewer sees only its own.
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
//// The first viewer calls `start`, which decodes the start arguments and
//// starts the gen_server. `init` admits that viewer, which monitors its link
//// process and its node, and arms a tick. `handle_info` then runs for every
//// message: `admit_request` lets a `join` through and refuses a request from a
//// pid that is not attached, `dispatch` answers an admitted request, `on_down`
//// handles a monitored process ending, and `on_tick` enforces the leases and
//// the probe deadlines.
////
//// ## Teardown
////
//// Four things end one viewer's attach: an explicit `detach`, its link process
//// dying, its node going down, and its lease expiring because it stopped
//// pinging. Each reaches `release`, which destroys that viewer's sessions,
//// kills its samplers, tracers and workers, drops its pins and gives up its
//// share of the `scheduler_wall_time` flag, and touches nothing another
//// viewer owns. When the last viewer is released the agent stops, `shut_down`
//// clears whatever is left, and `terminate` hands the modules to the janitor
//// module. The decision to stop is made in the agent's own mailbox order with
//// the count of viewers it holds, so a `join` handled before the last
//// `detach` keeps the agent and modules alive, and one handled after it finds
//// no agent and its sender starts a new one.
////
//// A crash in the agent reaches `terminate`, which runs the same cleanup for
//// every viewer. A kill signal runs neither, and the VM then destroys the
//// sessions because the agent was their sole holder.

import pickglass_agent/activitytrace
import pickglass_agent/binaries
import pickglass_agent/calltrace
import pickglass_agent/census
import pickglass_agent/counters.{type Probe}
import pickglass_agent/detail
import pickglass_agent/ets
import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_gen_server.{type Next, Noreply, Normal, Stop}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{
  type Atom, type Pid, type Reference, type Term,
}
import pickglass_agent/internal/ffi_trace.{type CounterMode, type Session}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/seq
import pickglass_agent/janitor
import pickglass_agent/measure
import pickglass_agent/modules
import pickglass_agent/owner
import pickglass_agent/reply.{type Failure, Failure}
import pickglass_agent/request.{type Envelope, type Token, Envelope}
import pickglass_agent/sampler
import pickglass_agent/supervision
import pickglass_agent/system
import pickglass_agent/tracer
import pickglass_agent/viewers.{
  type Scheduler, type Viewer, Collecting, NotCollecting, Viewer,
}

/// How often the agent looks at its lease and its probe deadlines.
const tick_ms = 250

/// The most processes the agent will pin at once.
const max_pins = 64

/// The most probes sampling or counting at once, of every kind together.
const max_running_probes = 2

/// The most stack probes sampling at once.
const max_running_stack_probes = 1

/// The most call tree probes, and the most events probes, running at once.
/// Both count toward `max_running_probes`.
const max_running_trace_probes_per_kind = 1

/// The most finished call tree and events probes kept for reading. Each holds
/// its aggregate in its tracer's heap, so the bound is small.
const max_finished_trace_probes = 2

/// The heap a tracer may grow to, in words, before the VM kills it.
const tracer_heap_words = 4_000_000

/// How long past its window a tracer may take to stop before the agent kills
/// it, in milliseconds. A tracer stops itself at its deadline, so this only
/// matters to one that is stuck.
const tracer_grace_ms = 1000

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

/// How the agent is configured at start: by the first viewer, which becomes
/// the first row of the viewers table.
pub type Config {
  Config(
    /// The viewer's link process. Its death ends that viewer's attach.
    viewer: Pid,
    /// An identifier the viewer generated for this attach. Pin tokens are
    /// bound to it, so a token from an earlier agent is refused.
    boot_id: String,
    /// How long the agent waits without hearing from the viewer before it
    /// drops that viewer, in milliseconds.
    lease_ms: Int,
    /// The identity of the agent build, which the viewer computed from the
    /// beams it pushed. A viewer that asks to join must carry the same one,
    /// because joining shares the code already running and never replaces it.
    build: String,
  )
}

/// A process a viewer asked the agent to watch. `owner` is that viewer's link
/// process: only it may use or release the pin.
pub type Pin {
  Pin(id: Int, pid: Pid, text: String, monitor: Reference, owner: Pid)
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
/// deadline. The aggregate lives in the sampler, not here. `owner` is the
/// viewer that started it.
pub type StackProbe {
  StackProbe(
    id: Int,
    owner: Pid,
    sampler: Pid,
    monitor: Reference,
    deadline_at_ms: Int,
    phase: StackPhase,
  )
}

/// Which trace-based event probe a `TraceProbe` is. The two kinds are limited
/// separately, and a read or stop names the kind it expects.
pub type TraceKind {
  CallTree
  SchedulingGc
}

/// Whether an event probe is still tracing, and if so the session it owns.
/// This is the only place the strong session handle lives. It is never sent,
/// returned or logged, and it is gone from the probe once the session is
/// destroyed.
pub type TracePhase {
  TraceRunning(session: Session)
  TraceDone
}

/// An event probe: the tracer process that folds the events, its monitor and
/// its deadline. The aggregate lives in the tracer, not here. `owner` is the
/// viewer that started it.
pub type TraceProbe {
  TraceProbe(
    id: Int,
    owner: Pid,
    kind: TraceKind,
    tracer: Pid,
    monitor: Reference,
    deadline_at_ms: Int,
    phase: TracePhase,
  )
}

/// The agent's state. Pins, probes and workers of every viewer share these
/// lists, each tagged with its owner; the ids come from one counter, so an id
/// never names two things, and the limits that protect the target are counted
/// across all viewers.
pub type State {
  State(
    build: String,
    started_ms: Int,
    viewers: List(Viewer),
    pins: List(Pin),
    next_pin: Int,
    probes: List(Probe),
    stacks: List(StackProbe),
    traces: List(TraceProbe),
    next_probe: Int,
    workers: List(Worker),
  )
}

/// The messages the agent sends itself, and the one `nodedown` notice the
/// VM sends it. Each is the atom of the same name.
type Notice {
  Tick
  Nodedown
}

type Event {
  Asked(Envelope)
  JoinAsked(
    reply_to: Pid,
    reference: Reference,
    boot_id: String,
    lease_ms: Int,
    build: String,
  )
  Refused(reply_to: Pid, reference: Reference, detail: String)
  Ticked
  StacksFinished(id: Int)
  TraceFinished(id: Int)
  Exited(monitor: Reference, reason: Term)
  NodeLost(node: Atom)
  Ignored
}

/// Start the agent. The first viewer calls this over `erpc` after pushing the
/// modules. `args` is `{ViewerPid, BootId, LeaseMs, Build}`; anything else is
/// refused. The agent is started unlinked from the caller, which is a
/// temporary process that ends when the call returns.
///
/// Returns `{ok, Pid}`, `{error, {already_started, Pid}}` when an agent is
/// already registered, or `{error, Reason}`. A viewer that finds an agent
/// running joins it with a `join` request instead of starting another.
///
/// ## Examples
///
/// ```gleam
/// start(coerce(#(viewer_pid, "boot-1", 30_000, "build-1")))
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
    && ffi_term.tuple_size(args) == 4
    && ffi_term.is_pid(ffi_term.element(1, args))
    && ffi_term.is_binary(ffi_term.element(2, args))
    && ffi_term.is_integer(ffi_term.element(3, args))
    && ffi_term.is_binary(ffi_term.element(4, args))
  {
    False -> Error(Nil)
    True ->
      Ok(Config(
        viewer: ffi_term.coerce(ffi_term.element(1, args)),
        boot_id: ffi_term.coerce(ffi_term.element(2, args)),
        lease_ms: request.clamp(
          ffi_term.coerce(ffi_term.element(3, args)),
          request.min_lease_ms,
          request.max_lease_ms,
        ),
        build: ffi_term.coerce(ffi_term.element(4, args)),
      ))
  }
}

/// The `gen_server` init callback. Admits the first viewer, which watches its
/// process and node, and arms the first tick.
pub fn init(config: Config) -> Result(State, Nil) {
  owner.claim_self()

  let now = ffi_proc.now_ms()
  let first = watch_viewer(config.viewer, config.boot_id, config.lease_ms, now)

  let _ = ffi_proc.send_after(tick_ms, ffi_proc.self(), ffi_term.coerce(Tick))

  Ok(
    State(
      build: config.build,
      started_ms: now,
      viewers: viewers.add([], first),
      pins: [],
      next_pin: 1,
      probes: [],
      stacks: [],
      traces: [],
      next_probe: 1,
      workers: [],
    ),
  )
}

// A viewer is watched twice, by a monitor on its link process and by a flag
// on its node, so that a killed process, a killed VM and a lost connection all
// end its attach. The monitor message alone would also carry a lost
// connection; the node flag keeps the original behaviour of ending the attach
// on `nodedown` without waiting for it.
fn watch_viewer(pid: Pid, boot_id: String, lease_ms: Int, now: Int) -> Viewer {
  let node = ffi_proc.node_of(pid)
  let monitor = ffi_proc.monitor(ffi_proc.Process, pid)

  let _ = ffi_proc.monitor_node_flag(node, ffi_term.coerce(True))

  Viewer(
    pid: pid,
    boot_id: boot_id,
    monitor: monitor,
    node: node,
    lease_ms: lease_ms,
    last_heard_ms: now,
    scheduler: NotCollecting,
  )
}

/// The `gen_server` callback for every message. A message that is not one of
/// the closed set is dropped.
pub fn handle_info(message: Term, state: State) -> Next(State) {
  case classify(message) {
    Asked(envelope) -> admit_request(envelope, state)
    JoinAsked(reply_to, reference, boot_id, lease_ms, build) ->
      join(state, reply_to, reference, boot_id, lease_ms, build)
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
    TraceFinished(id) -> Noreply(mark_trace_done(state, id))
    Exited(monitor, reason) -> on_down(monitor, reason, state)
    NodeLost(node) ->
      release_viewers(state, viewers.on_node(state.viewers, node))
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
    request.Joining(reply_to, reference, boot_id, lease_ms, build) ->
      JoinAsked(reply_to, reference, boot_id, lease_ms, build)
    request.Malformed(reply_to, reference, detail) ->
      Refused(reply_to, reference, detail)
    request.NotARequest -> classify_notice(message)
  }
}

fn classify_notice(message: Term) -> Event {
  case ffi_term.is_tuple(message) {
    False -> Ignored
    True -> classify_signal(message, ffi_term.tuple_size(message))
  }
}

fn classify_signal(message: Term, size: Int) -> Event {
  case size {
    5 ->
      case is_down(message) {
        True ->
          Exited(
            ffi_term.coerce(ffi_term.element(2, message)),
            ffi_term.element(5, message),
          )
        False -> Ignored
      }
    2 -> classify_pair(message)
    _ -> Ignored
  }
}

// `{nodedown, Node}`, or `{Tag, ProbeId}` from a sampler or a tracer that
// stopped on its own.
fn classify_pair(message: Term) -> Event {
  let tag = ffi_term.element(1, message)
  let value = ffi_term.element(2, message)

  case tag == ffi_term.coerce(Nodedown) && ffi_term.is_atom(value) {
    True -> NodeLost(ffi_term.coerce(value))
    False -> classify_finished(tag, value)
  }
}

fn classify_finished(tag: Term, value: Term) -> Event {
  case
    ffi_term.is_integer(value),
    tag == ffi_term.coerce(sampler.finished_tag()),
    tag == ffi_term.coerce(tracer.finished_tag())
  {
    True, True, _ -> StacksFinished(ffi_term.coerce(value))
    True, False, True -> TraceFinished(ffi_term.coerce(value))
    True, False, False -> Ignored
    False, _, _ -> Ignored
  }
}

// `{'DOWN', Ref, process, Pid, Reason}`.
fn is_down(message: Term) -> Bool {
  ffi_term.element(1, message) == ffi_term.coerce(ffi_term.atom("DOWN"))
  && ffi_term.is_reference(ffi_term.element(2, message))
}

// ----------------------------------------------------------------- requests

// A request from an attached viewer renews that viewer's lease and no other's.
// A request from a pid that is not attached is refused: the only message such
// a pid may send is a join, which is classified apart and never reaches here.
fn admit_request(envelope: Envelope, state: State) -> Next(State) {
  let Envelope(reply_to, reference, _) = envelope

  case viewers.find(state.viewers, reply_to) {
    Ok(viewer) ->
      dispatch(
        envelope,
        viewer,
        State(
          ..state,
          viewers: viewers.touch(state.viewers, reply_to, ffi_proc.now_ms()),
        ),
      )
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "not_attached",
        "this process is not attached to the agent; send a join first",
      )
  }
}

// Joining shares the code that is running, so it is allowed only for the
// build that is running: a viewer with other beams would need them loaded
// under the same module names, and loading them replaces the code another
// viewer's agent is executing. The refusal's detail is the running build, so
// the viewer can say which two builds differ. The room check comes after the
// build check because it is the one a viewer can fix by waiting. A pid that is
// already attached is told so, which a viewer whose first join was answered
// late takes as success.
fn join(
  state: State,
  reply_to: Pid,
  reference: Reference,
  boot_id: String,
  lease_ms: Int,
  build: String,
) -> Next(State) {
  case
    viewers.find(state.viewers, reply_to),
    build == state.build,
    viewers.has_room(state.viewers)
  {
    Ok(_), _, _ ->
      refuse(
        state,
        reply_to,
        reference,
        "already_attached",
        "this process is already attached to the agent",
      )
    Error(Nil), False, _ ->
      refuse(state, reply_to, reference, "build_mismatch", state.build)
    Error(Nil), True, False ->
      refuse(
        state,
        reply_to,
        reference,
        "too_many_viewers",
        "the agent already serves the most viewers it allows",
      )
    Error(Nil), True, True -> {
      let viewer = watch_viewer(reply_to, boot_id, lease_ms, ffi_proc.now_ms())
      let attached = viewers.add(state.viewers, viewer)

      answer(
        State(..state, viewers: attached),
        reply_to,
        reference,
        reply.joined(seq.length(attached)),
      )
    }
  }
}

fn dispatch(envelope: Envelope, viewer: Viewer, state: State) -> Next(State) {
  let Envelope(reply_to, reference, request) = envelope

  case request {
    request.Detach -> detach(state, viewer, reply_to, reference)
    request.Ping -> answer(state, reply_to, reference, ping(state, viewer))
    request.MemoryReport -> answer(state, reply_to, reference, memory())
    request.Census(max_scanned, top_k) ->
      census_request(
        state,
        reply_to,
        reference,
        max_scanned,
        top_k,
        census.Basic,
        reply.census,
      )
    request.Owners(max_scanned, top_k) ->
      census_request(
        state,
        reply_to,
        reference,
        max_scanned,
        top_k,
        census.Basic,
        reply.owners,
      )
    request.OwnersDetail(max_scanned, top_k) ->
      census_request(
        state,
        reply_to,
        reference,
        max_scanned,
        top_k,
        census.Extended,
        reply.owners_detail,
      )
    request.EtsTables(top_k) -> ets_request(state, reply_to, reference, top_k)
    request.Binaries(token, top_k) ->
      binaries_request(state, reply_to, reference, token, top_k)
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
    request.StartCalltrace(
      tokens,
      patterns,
      duration_ms,
      max_events,
      timeline_limit,
    ) ->
      start_calltrace(
        state,
        reply_to,
        reference,
        tokens,
        patterns,
        duration_ms,
        max_events,
        timeline_limit,
      )
    request.ReadCalltrace(id) ->
      read_trace(state, reply_to, reference, id, CallTree)
    request.StopCalltrace(id) ->
      stop_trace(state, reply_to, reference, id, CallTree)
    request.StartEvents(
      tokens,
      duration_ms,
      max_events,
      slice_limit,
      long_gc_ms,
      long_schedule_ms,
    ) ->
      start_events(
        state,
        reply_to,
        reference,
        tokens,
        duration_ms,
        max_events,
        slice_limit,
        long_gc_ms,
        long_schedule_ms,
      )
    request.ReadEvents(id) ->
      read_trace(state, reply_to, reference, id, SchedulingGc)
    request.StopEvents(id) ->
      stop_trace(state, reply_to, reference, id, SchedulingGc)
    request.SystemReport ->
      start_worker(state, reply_to, reference, "system", read_deadline_ms, fn() {
        reply.system(system.read())
      })
    request.Pin(text) -> pin(state, viewer, reference, text)
    request.Unpin(token) -> unpin(state, reply_to, reference, token)
    request.Scheduler(action) -> scheduler(state, viewer, reference, action)
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
    request.ReadCounterMemory(id) ->
      read_counter_memory(state, reply_to, reference, id)
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

// A viewer's ping counts what that viewer holds, not what the node holds, so
// a viewer reads its own pins and probes however many others are attached.
fn ping(state: State, viewer: Viewer) -> Term {
  let pid = viewer.pid
  let mine = fn(owner: Pid) { owner == pid }

  reply.pong(
    viewer.boot_id,
    ffi_term.atom_name(ffi_vm.node_name()),
    ffi_vm.otp_release(),
    ffi_proc.now_ms() - state.started_ms,
    seq.length(seq.filter(state.pins, fn(entry) { mine(entry.owner) })),
    running_count(seq.filter(state.probes, fn(probe) { mine(probe.owner) }))
      + sampling_count(
      seq.filter(state.stacks, fn(probe) { mine(probe.owner) }),
    )
      + tracing_count(seq.filter(state.traces, fn(probe) { mine(probe.owner) })),
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
  mode: census.Mode,
  shape: fn(census.Report) -> Term,
) -> Next(State) {
  let budget = census.Budget(max_scanned, top_k, census_deadline_ms, mode)

  start_worker(state, reply_to, reference, "census", census_deadline_ms, fn() {
    shape(census.run(budget))
  })
}

// The ETS listing is a walk over every table on the node, bounded by the same
// deadline as a census and run in a worker for the same reasons. The one list
// `ets:all/0` builds lives in the worker's heap, so a node with a very large
// number of tables is a `ets_failed` refusal and not a larger agent.
fn ets_request(
  state: State,
  reply_to: Pid,
  reference: Reference,
  top_k: Int,
) -> Next(State) {
  let budget = ets.Budget(top_k, census_deadline_ms)

  start_worker(state, reply_to, reference, "ets", census_deadline_ms, fn() {
    reply.ets_tables(ets.run(budget))
  })
}

// A binaries read is the one read whose cost grows with what the target
// holds, so it takes a pin and not a pid text and runs in a worker. A process
// with more references than the budget, or so many that the worker's heap cap
// ends the read first, is refused as `too_many_binaries`.
fn binaries_request(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
  top_k: Int,
) -> Next(State) {
  case find_pin(state, reply_to, token) {
    Error(Nil) -> refuse_stale_pin(state, reply_to, reference)
    Ok(entry) ->
      start_worker(
        state,
        reply_to,
        reference,
        "binaries",
        read_deadline_ms,
        fn() {
          case binaries.read(entry.pid, top_k) {
            Ok(report) -> reply.binaries(ffi_term.pid_text(entry.pid), report)
            Error(binaries.Gone) -> reply.failure(target_gone())
            Error(binaries.TooMany(_)) -> reply.failure(too_many_binaries())
          }
        },
      )
  }
}

fn too_many_binaries() -> Failure {
  Failure(
    "too_many_binaries",
    "the process holds more binary references than the agent reads at once",
  )
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
  case find_pin(state, reply_to, token) {
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
  case find_pin(state, reply_to, token) {
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
  case find_pin(state, reply_to, token) {
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

// The pin table is one list for every viewer, but a viewer's pin is its own:
// two viewers pinning the same process hold two pins, each with its own id,
// monitor and token, so releasing one never releases the other.
fn pin(
  state: State,
  viewer: Viewer,
  reference: Reference,
  text: String,
) -> Next(State) {
  case resolve_pid(text) {
    Error(Nil) ->
      refuse(
        state,
        viewer.pid,
        reference,
        "no_such_process",
        "no live local process has that identifier",
      )
    Ok(pid) ->
      case find_pin_by_pid(owned_pins(state.pins, viewer.pid), pid) {
        Ok(existing) ->
          answer(state, viewer.pid, reference, pinned(viewer, existing))
        Error(Nil) -> add_pin(state, viewer, reference, pid, text)
      }
  }
}

fn owned_pins(pins: List(Pin), owner: Pid) -> List(Pin) {
  seq.filter(pins, fn(entry) { entry.owner == owner })
}

fn add_pin(
  state: State,
  viewer: Viewer,
  reference: Reference,
  pid: Pid,
  text: String,
) -> Next(State) {
  case seq.length(owned_pins(state.pins, viewer.pid)) >= max_pins {
    True ->
      refuse(
        state,
        viewer.pid,
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
          owner: viewer.pid,
        )

      answer(
        State(
          ..state,
          pins: [entry, ..state.pins],
          next_pin: state.next_pin + 1,
        ),
        viewer.pid,
        reference,
        pinned(viewer, entry),
      )
    }
  }
}

fn pinned(viewer: Viewer, entry: Pin) -> Term {
  reply.pinned(viewer.boot_id, entry.id, entry.text)
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

// A token names a pin only for the viewer it was issued to: its boot id must
// be the requester's, and the pin must be one the requester owns. Both checks
// give the same `Error`, so a viewer cannot tell a pin that belongs to another
// viewer from one that does not exist.
fn find_pin(state: State, owner: Pid, token: Token) -> Result(Pin, Nil) {
  case viewers.find(state.viewers, owner) {
    Error(Nil) -> Error(Nil)
    Ok(viewer) ->
      case token.boot_id == viewer.boot_id {
        False -> Error(Nil)
        True ->
          seq.find(owned_pins(state.pins, owner), fn(entry) {
            entry.id == token.pin_id
          })
      }
  }
}

fn unpin(
  state: State,
  reply_to: Pid,
  reference: Reference,
  token: Token,
) -> Next(State) {
  case find_pin(state, reply_to, token) {
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

// The flag is node-wide and the VM counts it per process, so the agent turns
// it on when the first viewer asks and off when the last one releases, however
// many viewers ask in between. Each viewer is told only its own request:
// `collecting` means this viewer asked, and a viewer that did not ask gets no
// readings even while another viewer holds the flag.
fn scheduler(
  state: State,
  viewer: Viewer,
  reference: Reference,
  action: request.SchedulerAction,
) -> Next(State) {
  let wanted = case action {
    request.SchedulerOn -> Collecting
    request.SchedulerOff -> NotCollecting
    request.SchedulerRead -> viewer.scheduler
  }
  let #(updated, switch) =
    viewers.set_scheduler(state.viewers, viewer.pid, wanted)

  apply_switch(switch)

  answer(
    State(..state, viewers: updated),
    viewer.pid,
    reference,
    scheduler_reply(wanted),
  )
}

fn apply_switch(switch: viewers.Switch) -> Nil {
  case switch {
    viewers.TurnOn -> ffi_vm.enable_scheduler_wall_time()
    viewers.TurnOff -> ffi_vm.disable_scheduler_wall_time()
    viewers.Keep -> Nil
  }
}

fn scheduler_reply(wanted: Scheduler) -> Term {
  case wanted {
    NotCollecting -> reply.scheduler("not_collecting", [])
    Collecting -> {
      let readings = ffi_vm.scheduler_wall_time()
      let rows = case ffi_term.is_atom(readings) {
        True -> []
        False -> ffi_term.coerce(readings)
      }

      reply.scheduler("collecting", rows)
    }
  }
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
    use selection <- fallible.then(select(state, reply_to, targets))
    use probe <- fallible.then(start_probe(
      state,
      reply_to,
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
  owner: Pid,
  patterns: List(counters.Pattern),
  mode: CounterMode,
  selection: counters.Selection,
  deadline_ms: Int,
) -> Result(Probe, Failure) {
  case
    counters.start(
      state.next_probe,
      owner,
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
    running_count(state.probes)
    + sampling_count(state.stacks)
    + tracing_count(state.traces)
    >= max_running_probes
  {
    True -> Error(Failure("probe_limit", "two probes are already running"))
    False -> Ok(Nil)
  }
}

// Every name in the set resolves to an atom the node already has, or the
// whole request is refused: an unknown name is never turned into a new atom.
// A module name ending in `*` is a prefix and stands for every loaded module
// that starts with it, each paired with the pattern's function.
fn resolve_patterns(
  patterns: List(request.Pattern),
  acc: List(counters.Pattern),
) -> Result(List(counters.Pattern), Failure) {
  case patterns {
    [] -> Ok(seq.reverse(acc))
    [pattern, ..rest] -> {
      use modules <- fallible.then(resolve_modules(pattern))
      use function <- fallible.then(resolve_name(
        pattern.function,
        "unknown_function",
      ))

      resolve_patterns(
        rest,
        seq.fold(modules, acc, fn(acc, module) {
          [counters.Pattern(module, function), ..acc]
        }),
      )
    }
  }
}

// The modules a pattern names: one atom for an ordinary name and every
// matching loaded module for a prefix. A prefix takes every function of its
// modules, because most of the modules it matches would not have a function
// of any other name and the probe would be refused as matching nothing.
fn resolve_modules(pattern: request.Pattern) -> Result(List(Atom), Failure) {
  case modules.prefix_of(pattern.module) {
    Error(Nil) -> {
      use module <- fallible.then(resolve_name(pattern.module, "unknown_module"))

      Ok([module])
    }
    Ok(prefix) ->
      case pattern.function {
        "_" ->
          case modules.expand(prefix) {
            Ok(found) -> Ok(found)
            Error(refusal) -> Error(prefix_failure(refusal))
          }
        _ ->
          Error(Failure(
            "unknown_function",
            "a module prefix covers every function, so its function is _",
          ))
      }
  }
}

fn prefix_failure(refusal: modules.Refusal) -> Failure {
  case refusal {
    modules.BareWildcard ->
      Failure(
        "pattern_too_broad",
        "a * with no module name before it matches every module",
      )
    modules.NoModule ->
      Failure("unknown_module", "no loaded module starts with that prefix")
    modules.TooManyModules ->
      Failure(
        "pattern_too_broad",
        "the prefix matches more modules than one probe may trace",
      )
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
  owner: Pid,
  targets: request.Targets,
) -> Result(counters.Selection, Failure) {
  case targets {
    request.AllProcesses -> Ok(counters.EveryProcess)
    request.PinnedProcesses(tokens) -> {
      use pids <- fallible.then(pids_of(state, owner, tokens, []))

      Ok(counters.TheseProcesses(pids))
    }
  }
}

fn pids_of(
  state: State,
  owner: Pid,
  tokens: List(Token),
  acc: List(Pid),
) -> Result(List(Pid), Failure) {
  case tokens {
    [] -> Ok(seq.reverse(acc))
    [token, ..rest] ->
      case find_pin(state, owner, token) {
        Ok(entry) -> pids_of(state, owner, rest, [entry.pid, ..acc])
        Error(Nil) ->
          Error(Failure(
            "stale_pin",
            "a target's pin does not exist or the process exited",
          ))
      }
  }
}

// A probe id names a probe only for the viewer that started it, so another
// viewer's read, stop or memory request finds nothing and gets the same
// `no_such_probe` as an id that was never issued.
fn find_probe(probes: List(Probe), owner: Pid, id: Int) -> Result(Probe, Nil) {
  seq.find(probes, fn(probe) { probe.id == id && probe.owner == owner })
}

fn read_counters(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_probe(state.probes, reply_to, id) {
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

// The allocation reading is a separate request so that the counters reply
// keeps the shape the first wire release gave it. A probe is read here before
// it is stopped, since stopping removes it.
fn read_counter_memory(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_probe(state.probes, reply_to, id) {
    Error(Nil) ->
      refuse(
        state,
        reply_to,
        reference,
        "no_such_probe",
        "no probe has that id",
      )
    Ok(probe) ->
      answer(
        state,
        reply_to,
        reference,
        reply.counter_memory(probe.id, probe_state(probe), snapshot_of(probe)),
      )
  }
}

fn stop_counters(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_probe(state.probes, reply_to, id) {
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

fn probe_state(probe: Probe) -> String {
  case probe.phase {
    counters.Running(_) -> "running"
    counters.Finished(_) -> "finished"
  }
}

fn probe_reply(probe: Probe, snapshot: counters.Snapshot) -> Term {
  reply.counters(
    probe.id,
    probe_state(probe),
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
    use pids <- fallible.then(pids_of(state, reply_to, tokens, []))
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
          owner: reply_to,
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
  owner: Pid,
  id: Int,
) -> Result(StackProbe, Nil) {
  seq.find(probes, fn(probe) { probe.id == id && probe.owner == owner })
}

// A read is answered by the sampler, which holds the aggregate. The agent
// only forwards the request, so it never copies a probe's table.
fn read_stacks(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
) -> Next(State) {
  case find_stack_probe(state.stacks, reply_to, id) {
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
  case find_stack_probe(state.stacks, reply_to, id) {
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

// ------------------------------------------------------------------- traces

fn start_calltrace(
  state: State,
  reply_to: Pid,
  reference: Reference,
  tokens: List(Token),
  patterns: List(request.Pattern),
  duration_ms: Int,
  max_events: Int,
  timeline_limit: Int,
) -> Next(State) {
  let started = {
    use _ <- fallible.then(check_probe_room(state))
    use _ <- fallible.then(check_trace_room(state, CallTree))
    use pids <- fallible.then(trace_targets(state, reply_to, tokens))
    use resolved <- fallible.then(resolve_patterns(patterns, []))
    use launched <- fallible.then(
      launch(calltrace.start(
        calltrace.Config(
          agent: ffi_proc.self(),
          id: state.next_probe,
          targets: pids,
          patterns: resolved,
          duration_ms: duration_ms,
          max_events: max_events,
          timeline_limit: timeline_limit,
        ),
        tracer_heap_words,
      )),
    )

    Ok(#(launched, seq.length(pids)))
  }

  case started {
    Error(failure) -> answer(state, reply_to, reference, reply.failure(failure))
    Ok(#(launched, targets)) ->
      answer(
        add_trace(state, reply_to, CallTree, launched, duration_ms),
        reply_to,
        reference,
        reply.calltrace_started(
          state.next_probe,
          targets,
          launched.matched,
          duration_ms,
          max_events,
          timeline_limit,
        ),
      )
  }
}

fn start_events(
  state: State,
  reply_to: Pid,
  reference: Reference,
  tokens: List(Token),
  duration_ms: Int,
  max_events: Int,
  slice_limit: Int,
  long_gc_ms: Int,
  long_schedule_ms: Int,
) -> Next(State) {
  let started = {
    use _ <- fallible.then(check_probe_room(state))
    use _ <- fallible.then(check_trace_room(state, SchedulingGc))
    use pids <- fallible.then(trace_targets(state, reply_to, tokens))
    use launched <- fallible.then(
      launch(activitytrace.start(
        activitytrace.Config(
          agent: ffi_proc.self(),
          id: state.next_probe,
          targets: pids,
          duration_ms: duration_ms,
          max_events: max_events,
          slice_limit: slice_limit,
          long_gc_ms: long_gc_ms,
          long_schedule_ms: long_schedule_ms,
        ),
        tracer_heap_words,
      )),
    )

    Ok(#(launched, seq.length(pids)))
  }

  case started {
    Error(failure) -> answer(state, reply_to, reference, reply.failure(failure))
    Ok(#(launched, targets)) ->
      answer(
        add_trace(state, reply_to, SchedulingGc, launched, duration_ms),
        reply_to,
        reference,
        reply.events_started(
          state.next_probe,
          targets,
          duration_ms,
          max_events,
          slice_limit,
          long_gc_ms,
          long_schedule_ms,
        ),
      )
  }
}

fn launch(
  launched: Result(tracer.Launched, counters.Refusal),
) -> Result(tracer.Launched, Failure) {
  case launched {
    Ok(found) -> Ok(found)
    Error(counters.Refusal(code, detail)) -> Error(Failure(code, detail))
  }
}

// Pins become pids, without repeats, and the agent's own processes are never
// traced: a probe over the tracer or a sampler would measure the probe.
fn trace_targets(
  state: State,
  owner: Pid,
  tokens: List(Token),
) -> Result(List(Pid), Failure) {
  use pids <- fallible.then(pids_of(state, owner, tokens, []))

  let distinct = distinct_pids(pids, [])

  case seq.any(distinct, fn(pid) { is_agent_process(state, pid) }) {
    True ->
      Error(Failure(
        "agent_process",
        "a probe never traces the agent's own processes",
      ))
    False -> Ok(distinct)
  }
}

fn distinct_pids(pids: List(Pid), kept: List(Pid)) -> List(Pid) {
  case pids {
    [] -> seq.reverse(kept)
    [pid, ..rest] ->
      case seq.any(kept, fn(other) { other == pid }) {
        True -> distinct_pids(rest, kept)
        False -> distinct_pids(rest, [pid, ..kept])
      }
  }
}

fn is_agent_process(state: State, pid: Pid) -> Bool {
  pid == ffi_proc.self()
  || seq.any(state.stacks, fn(probe) { probe.sampler == pid })
  || seq.any(state.traces, fn(probe) { probe.tracer == pid })
  || seq.any(state.workers, fn(worker) { worker.pid == pid })
}

fn check_trace_room(state: State, kind: TraceKind) -> Result(Nil, Failure) {
  let running =
    seq.length(
      seq.filter(state.traces, fn(probe) {
        probe.kind == kind && is_tracing(probe)
      }),
    )

  case running >= max_running_trace_probes_per_kind {
    True ->
      Error(Failure("probe_limit", "a probe of this kind is already tracing"))
    False -> Ok(Nil)
  }
}

// The probe's own id is the agent's next one, which `add_trace` consumes.
// The session handle in `launched` goes straight into the probe and is held
// nowhere else.
fn add_trace(
  state: State,
  owner: Pid,
  kind: TraceKind,
  launched: tracer.Launched,
  duration_ms: Int,
) -> State {
  let probe =
    TraceProbe(
      id: state.next_probe,
      owner: owner,
      kind: kind,
      tracer: launched.tracer,
      monitor: ffi_proc.monitor(ffi_proc.Process, launched.tracer),
      deadline_at_ms: ffi_proc.now_ms() + duration_ms,
      phase: TraceRunning(launched.session),
    )

  State(
    ..state,
    traces: [probe, ..state.traces],
    next_probe: state.next_probe + 1,
  )
}

fn find_trace(
  probes: List(TraceProbe),
  owner: Pid,
  id: Int,
  kind: TraceKind,
) -> Result(TraceProbe, Nil) {
  seq.find(probes, fn(probe) {
    probe.id == id && probe.kind == kind && probe.owner == owner
  })
}

// A read is answered by the tracer, which holds the aggregate. The agent only
// forwards the request, so it never copies a probe's tables.
fn read_trace(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
  kind: TraceKind,
) -> Next(State) {
  case find_trace(state.traces, reply_to, id, kind) {
    Error(Nil) -> refuse_no_such_probe(state, reply_to, reference)
    Ok(probe) -> {
      tracer.read(probe.tracer, reply_to, reference)

      Noreply(state)
    }
  }
}

// A stop destroys the session first, which cuts the event stream at its
// source whatever backlog the tracer has, and then asks the tracer for its
// final result. The tracer replies and exits. The agent drops the probe at
// once and removes the monitor, so the tracer's exit is not mistaken for a
// crash.
fn stop_trace(
  state: State,
  reply_to: Pid,
  reference: Reference,
  id: Int,
  kind: TraceKind,
) -> Next(State) {
  case find_trace(state.traces, reply_to, id, kind) {
    Error(Nil) -> refuse_no_such_probe(state, reply_to, reference)
    Ok(probe) -> {
      let _ = ffi_proc.demonitor(probe.monitor, [ffi_proc.Flush])

      destroy_trace_session(probe)
      tracer.stop(probe.tracer, reply_to, reference)

      Noreply(
        State(
          ..state,
          traces: seq.filter(state.traces, fn(other) { other.id != id }),
        ),
      )
    }
  }
}

// A tracer that stopped on its own has already cut the stream. The agent
// destroys the session it owns as well, and keeps the probe until it is read.
fn mark_trace_done(state: State, id: Int) -> State {
  State(
    ..state,
    traces: seq.map(state.traces, fn(probe) {
      case probe.id == id {
        True -> {
          destroy_trace_session(probe)

          TraceProbe(..probe, phase: TraceDone)
        }
        False -> probe
      }
    }),
  )
}

fn destroy_trace_session(probe: TraceProbe) -> Nil {
  case probe.phase {
    TraceRunning(session) -> {
      let _ = ffi_trace.session_destroy(session)

      Nil
    }
    TraceDone -> Nil
  }
}

fn kill_trace(probe: TraceProbe) -> Nil {
  destroy_trace_session(probe)

  let _ = ffi_proc.demonitor(probe.monitor, [ffi_proc.Flush])
  let _ = ffi_proc.exit_with(probe.tracer, ffi_proc.Kill)

  Nil
}

fn is_tracing(probe: TraceProbe) -> Bool {
  case probe.phase {
    TraceRunning(_) -> True
    TraceDone -> False
  }
}

fn tracing_count(probes: List(TraceProbe)) -> Int {
  seq.length(seq.filter(probes, is_tracing))
}

// A tracer stops itself at its window, so one still tracing well after it is
// stuck, and is killed with its session. Finished probes wait to be read and
// are bounded: the oldest is killed when there are too many, because its
// tracer's heap is what they cost.
fn expire_traces(probes: List(TraceProbe), now: Int) -> List(TraceProbe) {
  let live =
    seq.filter(probes, fn(probe) {
      case is_tracing(probe) && now >= probe.deadline_at_ms + tracer_grace_ms {
        True -> {
          kill_trace(probe)

          False
        }
        False -> True
      }
    })

  case seq.length(live) - tracing_count(live) > max_finished_trace_probes {
    False -> live
    True -> seq.reverse(drop_oldest_finished_trace(seq.reverse(live)))
  }
}

fn drop_oldest_finished_trace(
  oldest_first: List(TraceProbe),
) -> List(TraceProbe) {
  case oldest_first {
    [] -> []
    [probe, ..rest] ->
      case probe.phase {
        TraceRunning(_) -> [probe, ..drop_oldest_finished_trace(rest)]
        TraceDone -> {
          kill_trace(probe)

          rest
        }
      }
  }
}

// A tracer that died, by its heap cap or by a crash, leaves its session's
// patterns running with nobody to read them, so the session is destroyed
// with the probe.
fn drop_dead_traces(
  probes: List(TraceProbe),
  monitor: Reference,
) -> List(TraceProbe) {
  seq.filter(probes, fn(probe) {
    case probe.monitor == monitor {
      True -> {
        destroy_trace_session(probe)

        False
      }
      False -> True
    }
  })
}

// ------------------------------------------------------------ time and exits

// Each tick enforces two deadlines: every viewer's lease, and every running
// probe's own. A viewer past its lease is released alone; the others keep
// their attach, and the agent stops only when none is left. A probe past its
// deadline is collected and its session destroyed in this handler, so no probe
// outlives its deadline by more than a tick. The tick is re-armed last, after
// everything it may have changed.
fn on_tick(state: State) -> Next(State) {
  let now = ffi_proc.now_ms()

  let released = seq.fold(viewers.lapsed(state.viewers, now), state, release)

  case released.viewers {
    [] -> Stop(Normal, released)
    _ -> {
      let _ =
        ffi_proc.send_after(tick_ms, ffi_proc.self(), ffi_term.coerce(Tick))

      Noreply(
        State(
          ..released,
          probes: expire_probes(released.probes, now),
          stacks: expire_stacks(released.stacks, now),
          traces: expire_traces(released.traces, now),
          workers: expire_workers(released.workers, now),
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
  case viewers.find_by_monitor(state.viewers, monitor) {
    Ok(viewer) -> release_viewers(state, [viewer])
    Error(Nil) ->
      Noreply(
        State(
          ..on_worker_down(monitor, reason, state),
          pins: seq.filter(state.pins, fn(entry) { entry.monitor != monitor }),
          stacks: seq.filter(state.stacks, fn(probe) {
            probe.monitor != monitor
          }),
          traces: drop_dead_traces(state.traces, monitor),
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
          reply.failure(worker_failure(worker, reason)),
        )
    }
  })

  State(..state, workers: rest)
}

// What a worker that ended without answering is reported as. A binaries read
// that the VM killed, which with a heap cap is what a list too long to receive
// causes, is the same refusal as a list counted and found too long.
fn worker_failure(worker: Worker, reason: Term) -> Failure {
  case
    worker.kind == "binaries"
    && reason == ffi_term.coerce(ffi_term.atom("killed"))
  {
    True -> too_many_binaries()
    False ->
      Failure(
        worker.kind <> "_failed",
        "the " <> worker.kind <> " worker ended before it could answer",
      )
  }
}

// ----------------------------------------------------------------- teardown

// An explicit detach releases the requesting viewer. The last viewer's detach
// stops the agent, and its reply is `detached`, which is also the signal that
// the modules are about to be unloaded. A detach that leaves other viewers
// attached is answered `left` with how many remain, because the agent and its
// modules stay.
fn detach(
  state: State,
  viewer: Viewer,
  reply_to: Pid,
  reference: Reference,
) -> Next(State) {
  let released = release(state, viewer)

  case released.viewers {
    [] -> {
      reply.send(reply_to, reference, reply.detached("requested"))

      Stop(Normal, released)
    }
    remaining -> {
      reply.send(reply_to, reference, reply.left(seq.length(remaining)))

      Noreply(released)
    }
  }
}

// Releases the viewers an event named, and stops the agent if that leaves
// none. The count is read from the state this handler holds, so the decision
// is made in mailbox order: a `join` handled earlier is already in the table,
// and one handled later finds no agent.
fn release_viewers(state: State, victims: List(Viewer)) -> Next(State) {
  let released = seq.fold(victims, state, release)

  case released.viewers {
    [] -> Stop(Normal, released)
    _ -> Noreply(released)
  }
}

// Releases everything one viewer holds on the target, and nothing another
// viewer holds: its sessions, samplers, tracers and workers are destroyed or
// killed, its pins are dropped, and its claim on the accounting flag is given
// up (the flag itself goes off only if no other viewer wants it). A viewer
// that detaches is released before it is answered, so the explicit path has
// already returned by the time the viewer is told.
fn release(state: State, viewer: Viewer) -> State {
  let pid = viewer.pid
  let owned = fn(owner: Pid) { owner == pid }
  let foreign = fn(owner: Pid) { owner != pid }

  seq.each(
    seq.filter(state.probes, fn(probe) { owned(probe.owner) }),
    counters.destroy,
  )
  seq.each(
    seq.filter(state.stacks, fn(probe) { owned(probe.owner) }),
    kill_stack_probe,
  )
  seq.each(
    seq.filter(state.traces, fn(probe) { owned(probe.owner) }),
    kill_trace,
  )
  seq.each(
    seq.filter(state.workers, fn(worker) { owned(worker.reply_to) }),
    kill_worker,
  )
  seq.each(owned_pins(state.pins, viewer.pid), fn(entry) {
    ffi_proc.demonitor(entry.monitor, [ffi_proc.Flush])
  })

  let _ = ffi_proc.demonitor(viewer.monitor, [ffi_proc.Flush])
  let _ = ffi_proc.monitor_node_flag(viewer.node, ffi_term.coerce(False))
  let #(remaining, switch) = viewers.leave(state.viewers, viewer.pid)

  apply_switch(switch)

  State(
    ..state,
    viewers: remaining,
    probes: seq.filter(state.probes, fn(probe) { foreign(probe.owner) }),
    stacks: seq.filter(state.stacks, fn(probe) { foreign(probe.owner) }),
    traces: seq.filter(state.traces, fn(probe) { foreign(probe.owner) }),
    workers: seq.filter(state.workers, fn(worker) { foreign(worker.reply_to) }),
    pins: seq.filter(state.pins, fn(entry) { foreign(entry.owner) }),
  )
}

fn kill_worker(worker: Worker) -> Nil {
  let _ = ffi_proc.exit_with(worker.pid, ffi_proc.Kill)

  Nil
}

// Releases everything the agent holds on the target, for every viewer, and
// returns the state with nothing left to release, so that running it a second
// time, from `terminate` after a request-driven stop, does nothing. Sessions
// are destroyed explicitly rather than left to the VM, because the explicit
// path is the one that has already returned by the time a viewer is told.
fn shut_down(state: State) -> State {
  seq.each(state.probes, counters.destroy)
  seq.each(state.stacks, kill_stack_probe)
  seq.each(state.traces, kill_trace)
  seq.each(state.workers, kill_worker)

  case viewers.demand(state.viewers) {
    Collecting -> ffi_vm.disable_scheduler_wall_time()
    NotCollecting -> Nil
  }

  State(
    ..state,
    viewers: [],
    probes: [],
    stacks: [],
    traces: [],
    workers: [],
    pins: [],
  )
}
