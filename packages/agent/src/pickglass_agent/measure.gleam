//// Self-measurement: asking a process that can measure its own data to do
//// so, and relaying the answer.
////
//// A process that holds a large term cannot be measured from outside:
//// `erts_debug:flat_size` works only on a term the caller already holds, and
//// copying a process's state to measure it would cost the very memory being
//// measured. A process that knows how to measure itself says so by listing
//// `<<"measure">>` as a capability in its ownership label. The agent then
//// sends it `{pickglass_measure, BudgetMs, ReplyTo, Ref}` and the process
//// answers `{pickglass_measure_reply, Ref, [{Name, Value, Unit}]}` with
//// whatever it measured inside its own heap.
////
//// Each request runs in its own short-lived helper, a gen_server, because
//// the agent has nothing to wait with: a reply is a message, and the helper
//// is what receives it. The helper also isolates what comes back. The answer
//// is data from a process the agent does not own, so it is checked before it
//// is relayed: at most 32 readings, each a short printable name, an integer
//// and one of three units. A reply that fails any check is refused whole.
////
//// ## Flow
////
//// `start` spawns the helper with its heap capped. `init` sends the helper
//// a `Begin` message and returns at once, so that `gen_server:start` never
//// waits on a slow target. `handle_info` then handles `Begin` (read the
//// label, refuse if the capability is not advertised, send the request and arm the
//// deadline), the target's reply, the deadline, and the target's death.
//// Each ends the helper after answering the viewer.

import pickglass_agent/internal/ffi_gen_server.{
  type Next, Noreply, Normal, SpawnOpt, Stop,
}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Pid, type Reference, type Term}
import pickglass_agent/internal/seq
import pickglass_agent/owner
import pickglass_agent/reply.{Failure}

/// The most readings one reply may carry.
pub const max_readings = 32

/// The longest reading name, in bytes.
pub const max_name_bytes = 64

/// What the helper needs to run one request.
pub type Config {
  Config(
    /// The process to measure.
    target: Pid,
    /// Who asked, and the reference to answer with.
    reply_to: Pid,
    request: Reference,
    /// How long to wait for the target, in milliseconds.
    budget_ms: Int,
  )
}

/// The helper's state: its configuration, the reference that quotes the
/// request to the target, the monitor on the target and the start time.
pub type State {
  State(config: Config, ref: Reference, monitor: Reference, started_ms: Int)
}

type Notice {
  Begin
  Deadline
}

// The tag the target answers with.
type ReplyTag {
  PickglassMeasureReply
}

// The tag the agent asks with.
type AskTag {
  PickglassMeasure
}

type Event {
  Started
  Expired
  Answered(readings: Term)
  TargetDown
  Ignored
}

/// Start a helper for one measurement. Returns the helper's pid. The helper
/// is not linked, so its crash reaches the agent as a monitor message; the
/// caller monitors it.
///
/// ## Examples
///
/// ```gleam
/// start(Config(target: pid, reply_to: viewer, request: ref, budget_ms: 500))
/// // -> Ok(helper_pid)
/// ```
pub fn start(config: Config, heap_words: Int) -> Result(Pid, Nil) {
  let started =
    ffi_gen_server.start_unlinked(
      ffi_term.atom("pickglass_agent@measure"),
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

/// The `gen_server` init callback. It only schedules the work, so the
/// caller's `start` returns without waiting on the target.
pub fn init(config: Config) -> Result(State, Nil) {
  owner.claim_self()

  ffi_proc.send(ffi_proc.self(), ffi_term.coerce(Begin))

  Ok(State(
    config: config,
    ref: ffi_proc.make_ref(),
    monitor: ffi_proc.monitor(ffi_proc.Process, config.target),
    started_ms: ffi_proc.now_ms(),
  ))
}

/// The `gen_server` callback for every message.
pub fn handle_info(message: Term, state: State) -> Next(State) {
  case classify(message, state) {
    Started -> begin(state)
    Answered(readings) -> relay(state, readings)
    Expired ->
      finish(
        state,
        reply.failure(Failure(
          "measure_deadline",
          "the process did not answer within the budget",
        )),
      )
    TargetDown ->
      finish(state, reply.failure(Failure("target_gone", "the process exited")))
    Ignored -> Noreply(state)
  }
}

fn classify(message: Term, state: State) -> Event {
  case message == ffi_term.coerce(Begin) {
    True -> Started
    False ->
      case message == ffi_term.coerce(Deadline) {
        True -> Expired
        False -> classify_tuple(message, state)
      }
  }
}

fn classify_tuple(message: Term, state: State) -> Event {
  case ffi_term.is_tuple(message) {
    False -> Ignored
    True ->
      case ffi_term.tuple_size(message) {
        // `{pickglass_measure_reply, Ref, Readings}`, accepted only when it
        // quotes this request's reference.
        3 ->
          case
            ffi_term.element(1, message)
            == ffi_term.coerce(PickglassMeasureReply)
            && ffi_term.element(2, message) == ffi_term.coerce(state.ref)
          {
            True -> Answered(ffi_term.element(3, message))
            False -> Ignored
          }

        // `{'DOWN', Ref, process, Pid, Reason}` for the target.
        5 ->
          case
            ffi_term.element(1, message)
            == ffi_term.coerce(ffi_term.atom("DOWN"))
            && ffi_term.element(2, message) == ffi_term.coerce(state.monitor)
          {
            True -> TargetDown
            False -> Ignored
          }
        _ -> Ignored
      }
  }
}

// The target's label is read here, in the helper, because the read is a
// signal to a process that may be slow to answer, and the agent never waits
// on one. The agent kills the helper at the request's deadline.
fn begin(state: State) -> Next(State) {
  case advertises_measure(state.config.target) {
    False ->
      finish(
        state,
        reply.failure(Failure(
          "not_measurable",
          "the process does not advertise the measure capability",
        )),
      )
    True -> {
      ffi_proc.send(
        state.config.target,
        ffi_term.coerce(#(
          PickglassMeasure,
          state.config.budget_ms,
          ffi_proc.self(),
          state.ref,
        )),
      )

      let _ =
        ffi_proc.send_after(
          state.config.budget_ms,
          ffi_proc.self(),
          ffi_term.coerce(Deadline),
        )

      Noreply(state)
    }
  }
}

fn advertises_measure(target: Pid) -> Bool {
  let answer = ffi_proc.process_info(target, [ffi_proc.Label])

  case ffi_term.is_list(answer) {
    False -> False
    True -> {
      let found: List(Term) = ffi_term.coerce(answer)

      case found {
        [entry] ->
          ffi_term.is_tuple(entry)
          && ffi_term.tuple_size(entry) == 2
          && seq.any(owner.capabilities(ffi_term.element(2, entry)), fn(name) {
            name == "measure"
          })
        _ -> False
      }
    }
  }
}

fn relay(state: State, readings: Term) -> Next(State) {
  case valid_readings(readings) {
    False ->
      finish(
        state,
        reply.failure(Failure(
          "bad_reply",
          "the process answered with something other than readings",
        )),
      )
    True ->
      finish(
        state,
        reply.measured(
          ffi_term.pid_text(state.config.target),
          ffi_proc.now_ms() - state.started_ms,
          readings,
        ),
      )
  }
}

// Sends the answer to the viewer and ends the helper. The viewer is the only
// reader of the reply, so the helper sends it itself.
fn finish(state: State, body: Term) -> Next(State) {
  reply.send(state.config.reply_to, state.config.request, body)

  Stop(Normal, state)
}

/// Whether a term is a list of at most 32 `{Name, Value, Unit}` readings
/// whose names are short printable binaries, values are integers and units
/// are `<<"words">>`, `<<"bytes">>` or `<<"count">>`. One bad reading makes
/// the whole list invalid: a reply is not partially trusted.
///
/// ## Examples
///
/// ```gleam
/// valid_readings(coerce([#("callback", 120, "words")]))
/// // -> True
/// valid_readings(coerce([#("callback", "x", "words")]))
/// // -> False
/// ```
pub fn valid_readings(term: Term) -> Bool {
  case ffi_term.is_list(term) {
    False -> False
    True ->
      case ffi_safe.proper_length(term) {
        Error(Nil) -> False
        Ok(length) ->
          length <= max_readings
          && seq.fold(ffi_term.coerce(term), True, fn(ok, item) {
            ok && valid_reading(item)
          })
      }
  }
}

fn valid_reading(item: Term) -> Bool {
  ffi_term.is_tuple(item)
  && ffi_term.tuple_size(item) == 3
  && valid_name(ffi_term.element(1, item))
  && ffi_term.is_integer(ffi_term.element(2, item))
  && valid_unit(ffi_term.element(3, item))
}

fn valid_name(term: Term) -> Bool {
  ffi_term.is_binary(term)
  && ffi_term.byte_size(term) >= 1
  && ffi_term.byte_size(term) <= max_name_bytes
  && printable(ffi_term.coerce(term))
}

fn printable(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> -> byte >= 32 && byte <= 126 && printable(rest)
    _ -> False
  }
}

fn valid_unit(term: Term) -> Bool {
  term == ffi_term.coerce("words")
  || term == ffi_term.coerce("bytes")
  || term == ffi_term.coerce("count")
}
