//// The agent's replies, decoded into domain types.
////
//// The pushed agent answers with plain Erlang terms: tuples whose first
//// element is a binary tag, and binaries, integers, lists and booleans
//// inside. It never sends an atom, so these decoders need nothing but
//// `gleam/dynamic/decode`, and the package stays pure. The shapes are the
//// contract written in `pickglass_agent/reply.gleam`; a change to either
//// side is a change to both.
////
//// Every decoder is total: any term, however malformed, gives `Ok` of a
//// reply or `Error` of a decode error list, and none ever raises. A tag this
//// build does not know, a boot id outside the allowed alphabet, a path
//// segment the owner vocabulary refuses, and an enumeration value outside
//// its closed list are all errors rather than defaults.
////
//// The agent reports raw facts: counts, words, bytes and its own stop
//// reason. Turning them into `Measurement`s and a `Coverage` record needs
//// the request that was made (the requested budget lives with the caller),
//// so that mapping happens in the viewer, not here.
////
//// Requests go the other way. `encode_request` writes the envelope the
//// agent's `request.decode` reads, again with binaries and integers only, so
//// the viewer never has to create an atom the agent would not recognise.
////
//// ## Flow
////
//// - `encode_request` wraps a request in `{<<"pg">>, 1, ReplyTo, Ref, Body}`.
//// - `decode_envelope` reads `{<<"pg">>, 1, Ref, Body}` and returns the
////   request reference unread beside the decoded reply.
//// - `reply_decoder` dispatches on the body's tag to one decoder per reply
////   kind.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/list
import pickglass_core/identity.{type BootId, type PinToken}
import pickglass_core/owner.{type Segment}

/// The wire version this build understands.
pub const wire_version = 1

/// A reply with the reference of the request it answers. The reference is an
/// opaque Erlang reference; the viewer matches it by equality only.
pub type Envelope {
  Envelope(reference: Dynamic, reply: Reply)
}

/// Every reply the agent sends.
pub type Reply {
  Pong(PongInfo)
  MemoryReport(MemorySnapshot)
  CensusReport(CensusSnapshot)
  Pinned(token: PinToken, pid_text: String)
  Unpinned(pin_serial: Int)
  SchedulerReport(SchedulerSnapshot)
  CountersStarted(probe_id: Int, matched_functions: Int, deadline_ms: Int)
  CountersReport(CountersSnapshot)
  Detached(reason: String)
  Refused(code: String, detail: String)
}

/// The answer to `ping`.
pub type PongInfo {
  PongInfo(
    boot_id: BootId,
    node: String,
    otp_release: String,
    uptime_ms: Int,
    pins: Int,
    probes: Int,
  )
}

/// The answer to `memory`: the VM's categories in bytes, plus what is needed
/// to read process words as bytes.
pub type MemorySnapshot {
  MemorySnapshot(
    categories: List(#(String, Int)),
    word_size: Int,
    process_count: Int,
    otp_release: String,
    erts_version: String,
    schedulers_online: Int,
  )
}

/// Why a census ended.
pub type CensusStop {
  /// Every process alive for the whole walk was seen.
  WalkFinished
  /// The scan budget was reached with processes unvisited.
  ScanBudgetReached
  /// The deadline passed with processes unvisited.
  DeadlineReached
}

/// How much of the node a census covered.
pub type CensusCoverage {
  CensusCoverage(scanned: Int, total: Int, stop: CensusStop, elapsed_ms: Int)
}

/// What a process label says about its owner.
pub type OwnerReading {
  /// No label, or one that is not an ownership label.
  Unlabelled
  /// A well-formed ownership label.
  Labelled(path: List(Segment), role: String)
}

/// One process in a census top list. Heap, stack and total heap are in VM
/// words; `memory` is bytes.
pub type ProcessRow {
  ProcessRow(
    pid_text: String,
    memory: Int,
    total_heap_words: Int,
    heap_words: Int,
    stack_words: Int,
    queue_length: Int,
    reductions: Int,
    status: String,
    current_function: String,
    registered_name: String,
    owner: OwnerReading,
  )
}

/// The totals for one owner across the scanned processes.
pub type OwnerTotal {
  OwnerTotal(
    owner: OwnerReading,
    processes: Int,
    memory: Int,
    queue_length: Int,
    reductions: Int,
  )
}

/// The answer to `census`.
pub type CensusSnapshot {
  CensusSnapshot(
    coverage: CensusCoverage,
    rows: List(ProcessRow),
    owners: List(OwnerTotal),
  )
}

/// Whether the agent holds the scheduler wall time flag.
pub type SchedulerAccounting {
  Collecting
  NotCollecting
}

/// One scheduler's reading, in the VM's native time unit.
pub type SchedulerReading {
  SchedulerReading(scheduler: Int, active: Int, total: Int)
}

/// The answer to `scheduler`.
pub type SchedulerSnapshot {
  SchedulerSnapshot(
    accounting: SchedulerAccounting,
    readings: List(SchedulerReading),
  )
}

/// Where a counters probe is.
pub type ProbeState {
  ProbeRunning
  ProbeFinished
  ProbeStopped
}

/// One traced function's totals. Time is microseconds, summed over the
/// traced processes.
pub type FunctionRow {
  FunctionRow(
    module: String,
    function: String,
    arity: Int,
    calls: Int,
    time_us: Int,
  )
}

/// The answer to `read_counters` and `stop_counters`. A nonzero
/// `invalidated` means the VM stopped tracing some functions, which is what
/// a module reload does, and the rows are suspect.
pub type CountersSnapshot {
  CountersSnapshot(
    probe_id: Int,
    state: ProbeState,
    matched_functions: Int,
    elapsed_ms: Int,
    functions: Int,
    with_calls: Int,
    invalidated: Int,
    rows: List(FunctionRow),
  )
}

/// Decode a reply envelope.
///
/// ## Examples
///
/// ```gleam
/// wire.decode_envelope(term)
/// // -> Ok(Envelope(reference, Detached("requested")))
/// ```
pub fn decode_envelope(
  term: Dynamic,
) -> Result(Envelope, List(decode.DecodeError)) {
  decode.run(term, envelope_decoder())
}

/// Decode a reply body alone, without its envelope.
///
/// ## Examples
///
/// ```gleam
/// wire.decode_reply(body)
/// // -> Ok(Detached("requested"))
/// ```
pub fn decode_reply(term: Dynamic) -> Result(Reply, List(decode.DecodeError)) {
  decode.run(term, reply_decoder())
}

fn envelope_decoder() -> Decoder(Envelope) {
  use marker <- decode.field(0, decode.string)
  use version <- decode.field(1, decode.int)
  use reference <- decode.field(2, decode.dynamic)
  use reply <- decode.field(3, reply_decoder())

  case marker == "pg" && version == wire_version {
    True -> decode.success(Envelope(reference:, reply:))
    False ->
      decode.failure(Envelope(reference:, reply: Detached("")), "pg envelope")
  }
}

fn reply_decoder() -> Decoder(Reply) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "pong" -> pong_decoder()
    "memory" -> memory_decoder()
    "census" -> census_decoder()
    "pinned" -> pinned_decoder()
    "unpinned" -> {
      use serial <- decode.field(1, decode.int)
      decode.success(Unpinned(serial))
    }
    "scheduler" -> scheduler_decoder()
    "counters_started" -> {
      use id <- decode.field(1, decode.int)
      use matched <- decode.field(2, decode.int)
      use deadline <- decode.field(3, decode.int)
      decode.success(CountersStarted(id, matched, deadline))
    }
    "counters" -> counters_decoder()
    "detached" -> {
      use reason <- decode.field(1, decode.string)
      decode.success(Detached(reason))
    }
    "error" -> {
      use code <- decode.field(1, decode.string)
      use detail <- decode.field(2, decode.string)
      decode.success(Refused(code, detail))
    }
    _ -> decode.failure(Detached(""), "a known reply tag")
  }
}

fn boot_decoder() -> Decoder(BootId) {
  use text <- decode.then(decode.string)

  case identity.boot_id(text) {
    Ok(boot) -> decode.success(boot)
    Error(Nil) -> decode.failure(identity.unknown_boot, "BootId")
  }
}

fn pong_decoder() -> Decoder(Reply) {
  use boot_id <- decode.field(1, boot_decoder())
  use node <- decode.field(2, decode.string)
  use otp_release <- decode.field(3, decode.string)
  use uptime_ms <- decode.field(4, decode.int)
  use pins <- decode.field(5, decode.int)
  use probes <- decode.field(6, decode.int)

  decode.success(
    Pong(PongInfo(boot_id:, node:, otp_release:, uptime_ms:, pins:, probes:)),
  )
}

fn memory_decoder() -> Decoder(Reply) {
  use categories <- decode.field(1, decode.list(category_decoder()))
  use word_size <- decode.field(2, decode.int)
  use process_count <- decode.field(3, decode.int)
  use otp_release <- decode.field(4, decode.string)
  use erts_version <- decode.field(5, decode.string)
  use schedulers_online <- decode.field(6, decode.int)

  decode.success(
    MemoryReport(MemorySnapshot(
      categories:,
      word_size:,
      process_count:,
      otp_release:,
      erts_version:,
      schedulers_online:,
    )),
  )
}

fn category_decoder() -> Decoder(#(String, Int)) {
  use name <- decode.field(0, decode.string)
  use bytes <- decode.field(1, decode.int)

  decode.success(#(name, bytes))
}

fn census_decoder() -> Decoder(Reply) {
  use coverage <- decode.field(1, coverage_decoder())
  use rows <- decode.field(2, decode.list(row_decoder()))
  use owners <- decode.field(3, decode.list(owner_total_decoder()))

  decode.success(CensusReport(CensusSnapshot(coverage:, rows:, owners:)))
}

fn coverage_decoder() -> Decoder(CensusCoverage) {
  use scanned <- decode.field(0, decode.int)
  use total <- decode.field(1, decode.int)
  use stop <- decode.field(2, stop_decoder())
  use elapsed_ms <- decode.field(3, decode.int)

  decode.success(CensusCoverage(scanned:, total:, stop:, elapsed_ms:))
}

fn stop_decoder() -> Decoder(CensusStop) {
  use code <- decode.then(decode.string)

  case code {
    "finished" -> decode.success(WalkFinished)
    "scan_budget" -> decode.success(ScanBudgetReached)
    "deadline" -> decode.success(DeadlineReached)
    _ -> decode.failure(WalkFinished, "a census stop reason")
  }
}

fn row_decoder() -> Decoder(ProcessRow) {
  use pid_text <- decode.field(0, decode.string)
  use memory <- decode.field(1, decode.int)
  use total_heap_words <- decode.field(2, decode.int)
  use heap_words <- decode.field(3, decode.int)
  use stack_words <- decode.field(4, decode.int)
  use queue_length <- decode.field(5, decode.int)
  use reductions <- decode.field(6, decode.int)
  use status <- decode.field(7, decode.string)
  use current_function <- decode.field(8, decode.string)
  use registered_name <- decode.field(9, decode.string)
  use owner <- decode.field(10, owner_decoder())

  decode.success(ProcessRow(
    pid_text:,
    memory:,
    total_heap_words:,
    heap_words:,
    stack_words:,
    queue_length:,
    reductions:,
    status:,
    current_function:,
    registered_name:,
    owner:,
  ))
}

fn owner_total_decoder() -> Decoder(OwnerTotal) {
  use owner <- decode.field(0, owner_decoder())
  use processes <- decode.field(1, decode.int)
  use memory <- decode.field(2, decode.int)
  use queue_length <- decode.field(3, decode.int)
  use reductions <- decode.field(4, decode.int)

  decode.success(OwnerTotal(
    owner:,
    processes:,
    memory:,
    queue_length:,
    reductions:,
  ))
}

// An owner is `{<<"unknown">>}` or `{<<"owner">>, [{Kind, Id}], Role}`. Path
// segments go through the owner vocabulary's own constructor, so a segment
// it refuses is a decode error here and never a path it would not accept.
fn owner_decoder() -> Decoder(OwnerReading) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "unknown" -> decode.success(Unlabelled)
    "owner" -> {
      use path <- decode.field(1, decode.list(segment_decoder()))
      use role <- decode.field(2, decode.string)
      decode.success(Labelled(path:, role:))
    }
    _ -> decode.failure(Unlabelled, "an owner reading")
  }
}

fn segment_decoder() -> Decoder(Segment) {
  use kind <- decode.field(0, decode.string)
  use id <- decode.field(1, decode.string)

  case owner.segment(kind, id) {
    Ok(segment) -> decode.success(segment)
    Error(Nil) -> decode.failure(owner.Segment("", ""), "an owner path segment")
  }
}

fn pinned_decoder() -> Decoder(Reply) {
  use boot <- decode.field(1, boot_decoder())
  use serial <- decode.field(2, decode.int)
  use pid_text <- decode.field(3, decode.string)

  case identity.pin(boot, serial) {
    Ok(token) -> decode.success(Pinned(token:, pid_text:))
    Error(Nil) ->
      decode.failure(Unpinned(serial), "a pin token with a non-negative serial")
  }
}

fn scheduler_decoder() -> Decoder(Reply) {
  use accounting <- decode.field(1, accounting_decoder())
  use readings <- decode.field(2, decode.list(reading_decoder()))

  decode.success(SchedulerReport(SchedulerSnapshot(accounting:, readings:)))
}

fn accounting_decoder() -> Decoder(SchedulerAccounting) {
  use code <- decode.then(decode.string)

  case code {
    "collecting" -> decode.success(Collecting)
    "not_collecting" -> decode.success(NotCollecting)
    _ -> decode.failure(NotCollecting, "a scheduler accounting state")
  }
}

fn reading_decoder() -> Decoder(SchedulerReading) {
  use scheduler <- decode.field(0, decode.int)
  use active <- decode.field(1, decode.int)
  use total <- decode.field(2, decode.int)

  decode.success(SchedulerReading(scheduler:, active:, total:))
}

fn counters_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use state <- decode.field(2, probe_state_decoder())
  use matched_functions <- decode.field(3, decode.int)
  use elapsed_ms <- decode.field(4, decode.int)
  use functions <- decode.subfield([5, 0], decode.int)
  use with_calls <- decode.subfield([5, 1], decode.int)
  use invalidated <- decode.subfield([5, 2], decode.int)
  use rows <- decode.field(6, decode.list(function_row_decoder()))

  decode.success(
    CountersReport(CountersSnapshot(
      probe_id:,
      state:,
      matched_functions:,
      elapsed_ms:,
      functions:,
      with_calls:,
      invalidated:,
      rows:,
    )),
  )
}

fn probe_state_decoder() -> Decoder(ProbeState) {
  use code <- decode.then(decode.string)

  case code {
    "running" -> decode.success(ProbeRunning)
    "finished" -> decode.success(ProbeFinished)
    "stopped" -> decode.success(ProbeStopped)
    _ -> decode.failure(ProbeStopped, "a probe state")
  }
}

fn function_row_decoder() -> Decoder(FunctionRow) {
  use module <- decode.field(0, decode.string)
  use function <- decode.field(1, decode.string)
  use arity <- decode.field(2, decode.int)
  use calls <- decode.field(3, decode.int)
  use time_us <- decode.field(4, decode.int)

  decode.success(FunctionRow(module:, function:, arity:, calls:, time_us:))
}

// ---------------------------------------------------------------- requests

/// What to do with scheduler wall time accounting.
pub type SchedulerAction {
  SchedulerOn
  SchedulerOff
  SchedulerRead
}

/// Which processes a counters probe covers.
pub type Targets {
  /// Every process on the node except the agent.
  AllProcesses
  /// Only the processes behind these pins.
  PinnedProcesses(tokens: List(PinToken))
}

/// Everything the viewer may ask the agent.
pub type Request {
  AskPing
  AskCensus(max_scanned: Int, top_k: Int)
  AskMemory
  AskPin(pid_text: String)
  AskUnpin(token: PinToken)
  AskScheduler(action: SchedulerAction)
  AskStartCounters(
    module: String,
    function: String,
    targets: Targets,
    deadline_ms: Int,
  )
  AskReadCounters(probe_id: Int)
  AskStopCounters(probe_id: Int)
  AskDetach
}

/// Write a request as the envelope the agent reads. `reply_to` is the pid
/// the reply should go to and `reference` the tag it will carry; both are
/// opaque terms the caller owns.
///
/// ## Examples
///
/// ```gleam
/// wire.encode_request(reply_to, reference, wire.AskPing)
/// // -> {<<"pg">>, 1, ReplyTo, Ref, {<<"ping">>}}
/// ```
pub fn encode_request(
  reply_to: Dynamic,
  reference: Dynamic,
  request: Request,
) -> Dynamic {
  dynamic.array([
    dynamic.string("pg"),
    dynamic.int(wire_version),
    reply_to,
    reference,
    request_body(request),
  ])
}

fn request_body(request: Request) -> Dynamic {
  case request {
    AskPing -> tagged("ping", [])
    AskCensus(max_scanned, top_k) ->
      tagged("census", [dynamic.int(max_scanned), dynamic.int(top_k)])
    AskMemory -> tagged("memory", [])
    AskPin(pid_text) -> tagged("pin", [dynamic.string(pid_text)])
    AskUnpin(token) -> tagged("unpin", [token_term(token)])
    AskScheduler(action) -> tagged("scheduler", [scheduler_action(action)])
    AskStartCounters(module, function, targets, deadline_ms) ->
      tagged("start_counters", [
        dynamic.string(module),
        dynamic.string(function),
        targets_term(targets),
        dynamic.int(deadline_ms),
      ])
    AskReadCounters(id) -> tagged("read_counters", [dynamic.int(id)])
    AskStopCounters(id) -> tagged("stop_counters", [dynamic.int(id)])
    AskDetach -> tagged("detach", [])
  }
}

fn tagged(tag: String, fields: List(Dynamic)) -> Dynamic {
  dynamic.array([dynamic.string(tag), ..fields])
}

fn scheduler_action(action: SchedulerAction) -> Dynamic {
  case action {
    SchedulerOn -> dynamic.string("on")
    SchedulerOff -> dynamic.string("off")
    SchedulerRead -> dynamic.string("read")
  }
}

fn token_term(token: PinToken) -> Dynamic {
  dynamic.array([
    dynamic.string(identity.boot_id_text(identity.pin_boot(token))),
    dynamic.int(identity.pin_serial(token)),
  ])
}

fn targets_term(targets: Targets) -> Dynamic {
  case targets {
    AllProcesses -> tagged("all", [])
    PinnedProcesses(tokens) ->
      tagged("pins", [dynamic.list(list.map(tokens, token_term))])
  }
}
