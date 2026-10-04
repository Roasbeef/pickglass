//// What the viewer may ask, and the total decoder for it.
////
//// A request arrives as an Erlang term from the viewer, but the agent trusts
//// the wire no more than the process that sent it. Any process on the node
//// can send the agent any term. `decode` therefore classifies a message into
//// a valid request, a malformed request that still names where to send the
//// refusal, or something that is not a request at all. It never raises and
//// never creates an atom: tags and enumerations are binaries, and names the
//// request wants resolved to atoms go through `ffi_safe.existing_atom`.
////
//// The envelope is `{<<"pg">>, 1, ReplyTo, Ref, Request}`. `Request` is a
//// tuple whose first element is a binary tag:
////
//// | Request | Tag and fields |
//// |---|---|
//// | liveness | `{<<"ping">>}` |
//// | census | `{<<"census">>, MaxScanned, TopK}` |
//// | memory | `{<<"memory">>}` |
//// | pin a process | `{<<"pin">>, PidText}` |
//// | release a pin | `{<<"unpin">>, {BootId, PinId}}` |
//// | scheduler accounting | `{<<"scheduler">>, <<"on" \| "off" \| "read">>}` |
//// | start a counters probe | `{<<"start_counters">>, Module, Function, Targets, DeadlineMs}` |
//// | read or stop a probe | `{<<"read_counters">>, Id}`, `{<<"stop_counters">>, Id}` |
//// | one process in detail | `{<<"process_detail">>, Token}` |
//// | parent edges over the node | `{<<"supervision">>, MaxScanned, MaxEdges}` |
//// | node facts and allocator carriers | `{<<"system">>}` |
//// | collect one process's garbage | `{<<"gc">>, Token, DeadlineMs}` |
//// | ask a process to measure itself | `{<<"measure">>, Token, BudgetMs}` |
//// | detach | `{<<"detach">>}` |
////
//// `Targets` is `{<<"all">>}` or `{<<"pins">>, [{BootId, PinId}]}`. Numeric
//// limits are clamped to the agent's own bounds rather than refused, so a
//// viewer asking for more than the budget allows gets the budget and sees
//// it in the reply's coverage.

import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Pid, type Reference, type Term}
import pickglass_agent/internal/seq

/// The wire version this agent speaks.
pub const wire_version = 1

/// The most processes one census may scan.
pub const max_scan = 200_000

/// The most edges one supervision walk returns.
pub const max_edges = 10_000

/// The shortest and longest wait for a targeted collection, in milliseconds.
pub const min_gc_wait_ms = 100

/// The longest wait for a targeted collection, in milliseconds.
pub const max_gc_wait_ms = 10_000

/// The shortest and longest wait for a self-measurement, in milliseconds.
pub const min_measure_wait_ms = 50

/// The longest wait for a self-measurement, in milliseconds.
pub const max_measure_wait_ms = 5000

/// The most rows one census returns.
pub const max_top_k = 200

/// The most processes a counters probe may target by pin.
pub const max_targets = 16

/// The shortest and longest counters probe, in milliseconds.
pub const min_deadline_ms = 100

/// The longest counters probe, in milliseconds.
pub const max_deadline_ms = 300_000

const max_tag_bytes = 32

const max_name_bytes = 255

/// What to do with scheduler wall time accounting.
pub type SchedulerAction {
  SchedulerOn
  SchedulerOff
  SchedulerRead
}

/// A reference to a pin the agent issued: the agent's boot id and the pin
/// number. A token from an earlier agent, or for a process that has exited,
/// is refused.
pub type Token {
  Token(boot_id: String, pin_id: Int)
}

/// Which processes a counters probe covers.
pub type Targets {
  /// Every process on the node, except the agent.
  AllProcesses

  /// Only the processes behind these pins.
  PinnedProcesses(tokens: List(Token))
}

/// A decoded request.
pub type Request {
  Ping
  Census(max_scanned: Int, top_k: Int)
  MemoryReport
  Pin(pid_text: String)
  Unpin(token: Token)
  Scheduler(action: SchedulerAction)
  StartCounters(
    module: String,
    function: String,
    targets: Targets,
    deadline_ms: Int,
  )
  ReadCounters(probe_id: Int)
  StopCounters(probe_id: Int)
  ProcessDetail(token: Token)
  Supervision(max_scanned: Int, max_edges: Int)
  SystemReport
  TargetedGc(token: Token, deadline_ms: Int)
  SelfMeasure(token: Token, budget_ms: Int)
  Detach
}

/// A request and where to answer it.
pub type Envelope {
  Envelope(reply_to: Pid, reference: Reference, request: Request)
}

/// The classification of one message.
pub type Decoded {
  /// A well-formed request.
  Valid(envelope: Envelope)

  /// An envelope with a valid reply address and an unusable request. The
  /// refusal goes to the sender, so a viewer with a bug learns of it.
  Malformed(reply_to: Pid, reference: Reference, detail: String)

  /// Not a request. Another subsystem's message, or noise.
  NotARequest
}

/// Classify a message.
///
/// ## Examples
///
/// ```gleam
/// decode(coerce(#("pg", 1, self(), make_ref(), #("ping"))))
/// // -> Valid(Envelope(self(), ref, Ping))
/// decode(coerce(42))
/// // -> NotARequest
/// ```
pub fn decode(message: Term) -> Decoded {
  case is_envelope(message) {
    False -> NotARequest
    True -> decode_envelope(message)
  }
}

fn is_envelope(message: Term) -> Bool {
  ffi_term.is_tuple(message)
  && ffi_term.tuple_size(message) == 5
  && ffi_term.element(1, message) == ffi_term.coerce("pg")
  && ffi_term.element(2, message) == ffi_term.coerce(wire_version)
  && ffi_term.is_pid(ffi_term.element(3, message))
  && ffi_term.is_reference(ffi_term.element(4, message))
}

fn decode_envelope(message: Term) -> Decoded {
  let reply_to: Pid = ffi_term.coerce(ffi_term.element(3, message))
  let reference: Reference = ffi_term.coerce(ffi_term.element(4, message))

  case decode_request(ffi_term.element(5, message)) {
    Ok(request) -> Valid(Envelope(reply_to, reference, request))
    Error(detail) -> Malformed(reply_to, reference, detail)
  }
}

fn decode_request(term: Term) -> Result(Request, String) {
  case ffi_term.is_tuple(term) && ffi_term.tuple_size(term) >= 1 {
    False -> Error("request is not a tuple")
    True ->
      case tag(ffi_term.element(1, term)) {
        Ok(name) -> by_tag(name, term, ffi_term.tuple_size(term))
        Error(Nil) -> Error("request tag is not a short binary")
      }
  }
}

fn tag(term: Term) -> Result(String, Nil) {
  case ffi_term.is_binary(term) && ffi_term.byte_size(term) <= max_tag_bytes {
    True -> Ok(ffi_term.coerce(term))
    False -> Error(Nil)
  }
}

fn by_tag(name: String, term: Term, size: Int) -> Result(Request, String) {
  case name, size {
    "ping", 1 -> Ok(Ping)
    "memory", 1 -> Ok(MemoryReport)
    "detach", 1 -> Ok(Detach)
    "census", 3 -> decode_census(term)
    "pin", 2 -> decode_pin(term)
    "unpin", 2 -> decode_unpin(term)
    "scheduler", 2 -> decode_scheduler(term)
    "start_counters", 5 -> decode_start_counters(term)
    "read_counters", 2 -> decode_probe(term, ReadCounters)
    "stop_counters", 2 -> decode_probe(term, StopCounters)
    "process_detail", 2 -> decode_token_request(term, ProcessDetail)
    "supervision", 3 -> decode_supervision(term)
    "system", 1 -> Ok(SystemReport)
    "gc", 3 -> decode_wait(term, TargetedGc, min_gc_wait_ms, max_gc_wait_ms)
    "measure", 3 ->
      decode_wait(term, SelfMeasure, min_measure_wait_ms, max_measure_wait_ms)
    _, _ -> Error("unknown request or wrong number of fields")
  }
}

fn decode_census(term: Term) -> Result(Request, String) {
  use scanned <- fallible.then(integer(ffi_term.element(2, term), "max_scanned"))
  use top_k <- fallible.then(integer(ffi_term.element(3, term), "top_k"))

  Ok(Census(clamp(scanned, 1, max_scan), clamp(top_k, 1, max_top_k)))
}

fn decode_pin(term: Term) -> Result(Request, String) {
  use text <- fallible.then(name(ffi_term.element(2, term), "pid text"))

  Ok(Pin(text))
}

fn decode_unpin(term: Term) -> Result(Request, String) {
  use token <- fallible.then(decode_token(ffi_term.element(2, term)))

  Ok(Unpin(token))
}

fn decode_scheduler(term: Term) -> Result(Request, String) {
  use action <- fallible.then(name(ffi_term.element(2, term), "action"))

  case action {
    "on" -> Ok(Scheduler(SchedulerOn))
    "off" -> Ok(Scheduler(SchedulerOff))
    "read" -> Ok(Scheduler(SchedulerRead))
    _ -> Error("scheduler action must be on, off or read")
  }
}

fn decode_start_counters(term: Term) -> Result(Request, String) {
  use module <- fallible.then(name(ffi_term.element(2, term), "module"))
  use function <- fallible.then(name(ffi_term.element(3, term), "function"))
  use targets <- fallible.then(decode_targets(ffi_term.element(4, term)))
  use deadline <- fallible.then(integer(ffi_term.element(5, term), "deadline"))

  Ok(StartCounters(
    module,
    function,
    targets,
    clamp(deadline, min_deadline_ms, max_deadline_ms),
  ))
}

fn decode_token_request(
  term: Term,
  build: fn(Token) -> Request,
) -> Result(Request, String) {
  use token <- fallible.then(decode_token(ffi_term.element(2, term)))

  Ok(build(token))
}

fn decode_supervision(term: Term) -> Result(Request, String) {
  use scanned <- fallible.then(integer(ffi_term.element(2, term), "max_scanned"))
  use edges <- fallible.then(integer(ffi_term.element(3, term), "max_edges"))

  Ok(Supervision(clamp(scanned, 1, max_scan), clamp(edges, 1, max_edges)))
}

// `{Tag, Token, WaitMs}` for the two requests that act on one pinned process
// and wait for it, clamped to the request's own bounds.
fn decode_wait(
  term: Term,
  build: fn(Token, Int) -> Request,
  low: Int,
  high: Int,
) -> Result(Request, String) {
  use token <- fallible.then(decode_token(ffi_term.element(2, term)))
  use wait <- fallible.then(integer(ffi_term.element(3, term), "wait"))

  Ok(build(token, clamp(wait, low, high)))
}

fn decode_probe(
  term: Term,
  build: fn(Int) -> Request,
) -> Result(Request, String) {
  use id <- fallible.then(integer(ffi_term.element(2, term), "probe id"))

  Ok(build(id))
}

fn decode_targets(term: Term) -> Result(Targets, String) {
  case ffi_term.is_tuple(term) && ffi_term.tuple_size(term) >= 1 {
    False -> Error("targets is not a tuple")
    True ->
      case tag(ffi_term.element(1, term)), ffi_term.tuple_size(term) {
        Ok("all"), 1 -> Ok(AllProcesses)
        Ok("pins"), 2 -> decode_pin_list(ffi_term.element(2, term))
        Ok(_), _ -> Error("targets must be all or pins")
        Error(Nil), _ -> Error("targets tag is not a short binary")
      }
  }
}

fn decode_pin_list(term: Term) -> Result(Targets, String) {
  case ffi_safe.proper_length(term) {
    Error(Nil) -> Error("pins is not a list")
    Ok(count) ->
      case count < 1 || count > max_targets {
        True -> Error("a probe takes between one and sixteen pins")
        False -> {
          use tokens <- fallible.then(decode_tokens(ffi_term.coerce(term), []))

          Ok(PinnedProcesses(tokens))
        }
      }
  }
}

fn decode_tokens(
  items: List(Term),
  acc: List(Token),
) -> Result(List(Token), String) {
  case items {
    [] -> Ok(seq.reverse(acc))
    [item, ..rest] -> {
      use token <- fallible.then(decode_token(item))

      decode_tokens(rest, [token, ..acc])
    }
  }
}

fn decode_token(term: Term) -> Result(Token, String) {
  case ffi_term.is_tuple(term) && ffi_term.tuple_size(term) == 2 {
    False -> Error("a pin token is a two-tuple")
    True -> {
      use boot_id <- fallible.then(name(ffi_term.element(1, term), "boot id"))
      use pin_id <- fallible.then(integer(ffi_term.element(2, term), "pin id"))

      Ok(Token(boot_id, pin_id))
    }
  }
}

fn integer(term: Term, what: String) -> Result(Int, String) {
  case ffi_term.is_integer(term) {
    True -> Ok(ffi_term.coerce(term))
    False -> Error(what <> " is not an integer")
  }
}

fn name(term: Term, what: String) -> Result(String, String) {
  case ffi_term.is_binary(term) && ffi_term.byte_size(term) <= max_name_bytes {
    True -> Ok(ffi_term.coerce(term))
    False -> Error(what <> " is not a short binary")
  }
}

/// Bring a number into `[low, high]`.
///
/// ## Examples
///
/// ```gleam
/// clamp(500, 1, 200)
/// // -> 200
/// ```
pub fn clamp(value: Int, low: Int, high: Int) -> Int {
  case value < low, value > high {
    True, _ -> low
    False, True -> high
    False, False -> value
  }
}
