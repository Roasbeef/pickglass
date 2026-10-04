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
//// The wire grew after its first release, and the growth is additive on
//// purpose. The original `Request`, `Reply` records and decoders keep their
//// shapes, because the viewer constructs and matches them. New replies are
//// new `Reply` variants, and new requests are the separate `ExtendedRequest`
//// type: a variant added to `Request` would break every exhaustive match on
//// it. Where a first-release reply would have had to gain a field, the agent
//// answers a new request with a new tag instead (`owners` beside `census`,
//// `counter_memory` beside `counters`).
////
//// ## Flow
////
//// - `encode_request` wraps a request in `{<<"pg">>, 1, ReplyTo, Ref, Body}`;
////   `encode_extended_request` does the same for the added requests.
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
  OwnersReport(OwnersSnapshot)
  CounterMemoryReport(CounterMemorySnapshot)
  ProcessDetailReport(ProcessDetail)
  SupervisionReport(SupervisionSnapshot)
  SystemReport(SystemSnapshot)
  CollectionReport(CollectionSnapshot)
  MeasureReport(MeasureSnapshot)
  StacksStarted(
    probe_id: Int,
    targets: Int,
    rate_hz: Int,
    duration_ms: Int,
    max_samples: Int,
  )
  StacksReport(StacksSnapshot)
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

/// The sums over every process the census scanned, whether or not its owner
/// is among the listed ones. The Owners remainder row is these totals minus
/// the sum of the listed owners, and `owners_tracked - owners_listed` is how
/// many owners that row stands for.
pub type CensusTotals {
  CensusTotals(
    processes: Int,
    memory: Int,
    queue_length: Int,
    reductions: Int,
    total_heap_words: Int,
    owners_tracked: Int,
    owners_listed: Int,
  )
}

/// An owner's totals with the heap capacity its processes hold: the sum of
/// their `total_heap_size`, in VM words.
pub type OwnerHeapTotal {
  OwnerHeapTotal(total: OwnerTotal, total_heap_words: Int)
}

/// The answer to `owners`: a census whose owner rows carry heap capacity,
/// and the totals over every scanned process.
pub type OwnersSnapshot {
  OwnersSnapshot(
    coverage: CensusCoverage,
    rows: List(ProcessRow),
    owners: List(OwnerHeapTotal),
    totals: CensusTotals,
  )
}

/// The words one traced function allocated while it ran, summed over the
/// traced processes.
pub type FunctionMemory {
  FunctionMemory(module: String, function: String, arity: Int, words: Int)
}

/// What a counters probe counted for allocation. A probe that did not ask
/// has no reading, which is not a list of zeros.
pub type CounterMemory {
  NoMemoryCounted
  MemoryCounted(rows: List(FunctionMemory))
}

/// The answer to `read_counter_memory`.
pub type CounterMemorySnapshot {
  CounterMemorySnapshot(probe_id: Int, state: ProbeState, memory: CounterMemory)
}

/// The sizes of one process, in bytes. `memory_bytes` is everything the VM
/// accounts to the process; the others are its heap generations and stack.
pub type ProcessSizes {
  ProcessSizes(
    memory_bytes: Int,
    total_heap_bytes: Int,
    heap_bytes: Int,
    stack_bytes: Int,
  )
}

/// What one process is doing. Function texts are `module:function/arity` or
/// empty.
pub type ProcessActivity {
  ProcessActivity(
    queue_length: Int,
    reductions: Int,
    status: String,
    current_function: String,
    initial_call: String,
    registered_name: String,
  )
}

/// A process's collection settings and heap blocks, in bytes. A
/// `max_heap_bytes` of zero is the VM's "no limit".
pub type ProcessGc {
  ProcessGc(
    minor_gcs: Int,
    fullsweep_after: Int,
    min_heap_bytes: Int,
    max_heap_bytes: Int,
    heap_block_bytes: Int,
    old_heap_bytes: Int,
    old_heap_block_bytes: Int,
    mbuf_bytes: Int,
    bin_vheap_bytes: Int,
  )
}

/// How many links, monitors and monitoring processes a process has, and who
/// spawned it (`""` when that is not recorded).
pub type ProcessRelations {
  ProcessRelations(
    links: Int,
    monitors: Int,
    monitored_by: Int,
    parent_pid_text: String,
  )
}

/// The answer to `process_detail`.
pub type ProcessDetail {
  ProcessDetail(
    pid_text: String,
    sizes: ProcessSizes,
    activity: ProcessActivity,
    gc: ProcessGc,
    relations: ProcessRelations,
    owner: OwnerReading,
    capabilities: List(String),
  )
}

/// Why a supervision walk ended.
pub type WalkStop {
  SupervisionFinished
  SupervisionScanBudget
  SupervisionDeadline
  SupervisionEdgeBudget
}

/// How much of the node a supervision walk covered.
pub type SupervisionCoverage {
  SupervisionCoverage(scanned: Int, total: Int, stop: WalkStop, elapsed_ms: Int)
}

/// One process and the process that spawned it. `parent_pid_text` is empty
/// when the parent is not recorded.
pub type SpawnEdge {
  SpawnEdge(
    child_pid_text: String,
    parent_pid_text: String,
    registered_name: String,
    initial_call: String,
    owner: OwnerReading,
  )
}

/// The answer to `supervision`. A parent is whoever spawned the process, so
/// the tree it draws is by spawner.
pub type SupervisionSnapshot {
  SupervisionSnapshot(coverage: SupervisionCoverage, edges: List(SpawnEdge))
}

/// What the node is: uptime, emulator and scheduler counts.
pub type NodeFacts {
  NodeFacts(
    uptime_ms: Int,
    creation: Int,
    emulator_flavor: String,
    emulator_type: String,
    erts_version: String,
    otp_release: String,
    schedulers: Int,
    schedulers_online: Int,
    dirty_cpu: Int,
    dirty_cpu_online: Int,
    dirty_io: Int,
    word_size: Int,
  )
}

/// Whether a carrier sits in the shared carrier pool.
pub type CarrierPool {
  InCarrierPool
  NotInCarrierPool
}

/// One allocator's carriers in one pool state. `unscanned_bytes` is what the
/// VM skipped to stay responsive.
pub type CarrierRow {
  CarrierRow(
    allocator: String,
    pool: CarrierPool,
    carriers: Int,
    total_bytes: Int,
    used_bytes: Int,
    unscanned_bytes: Int,
  )
}

/// The carrier reading, or why there is none. An unavailable reading is not
/// a total of zero.
pub type Carriers {
  CarriersUnavailable(reason: String)
  CarriersRead(rows: List(CarrierRow))
}

/// The answer to `system`.
pub type SystemSnapshot {
  SystemSnapshot(facts: NodeFacts, carriers: Carriers)
}

/// One reading of a process's heap, in bytes.
pub type HeapSizes {
  HeapSizes(
    memory_bytes: Int,
    total_heap_bytes: Int,
    heap_bytes: Int,
    heap_block_bytes: Int,
    old_heap_bytes: Int,
    old_heap_block_bytes: Int,
    mbuf_bytes: Int,
    stack_bytes: Int,
    bin_vheap_bytes: Int,
  )
}

/// A heap reading, or the fact that the process could not be read.
pub type HeapReading {
  HeapRead(HeapSizes)
  HeapGone
}

/// How a targeted collection ended.
pub type CollectionOutcome {
  CollectionCompleted
  CollectionTargetGone
}

/// The answer to `gc`. The class is always intrusive: the target stops while
/// it collects, so a view must say so beside the numbers.
pub type CollectionSnapshot {
  CollectionSnapshot(
    pid_text: String,
    outcome: CollectionOutcome,
    elapsed_ms: Int,
    before: HeapReading,
    after: HeapReading,
  )
}

/// The unit of a self-measurement reading.
pub type ReadingUnit {
  ReadingWords
  ReadingBytes
  ReadingCount
}

/// One reading a process reported about itself.
pub type SelfReading {
  SelfReading(name: String, value: Int, unit: ReadingUnit)
}

/// The answer to `measure`.
pub type MeasureSnapshot {
  MeasureSnapshot(
    pid_text: String,
    elapsed_ms: Int,
    readings: List(SelfReading),
  )
}

/// Why stack sampling ended, or that it has not.
pub type SamplingStop {
  SamplingRunning
  SamplingDeadline
  SamplingBudget
  SamplingTargetsGone
  SamplingStopped
}

/// How a stack probe sampled. `AchievedMilliHz` is rounds per second times a
/// thousand. `depth_limit` is the node's backtrace depth, and
/// `at_depth_limit` counts the samples whose stack reached it and may have
/// been cut. `dropped_samples` were not stored because the stack table was
/// full, and `truncated_samples` were stored but left out of the reply by its
/// frame bound. `samples` equals the returned counts plus both.
pub type SamplerMeter {
  SamplerMeter(
    requested_hz: Int,
    achieved_millihz: Int,
    rounds: Int,
    samples: Int,
    elapsed_ms: Int,
    depth_limit: Int,
    at_depth_limit: Int,
    targets_gone: Int,
    dropped_samples: Int,
    distinct_stacks: Int,
    truncated_samples: Int,
  )
}

/// Where in source a stack frame is.
pub type FrameLocation {
  NoLocation
  FileOnly(file: String)
  AtLine(file: String, line: Int)
}

/// One function frame of a sampled stack.
pub type StackFrame {
  StackFrame(
    module: String,
    function: String,
    arity: Int,
    location: FrameLocation,
  )
}

/// One distinct stack and the number of samples that saw it. `frames` are
/// indices into the snapshot's frame table, leaf first.
pub type SampledStack {
  SampledStack(count: Int, status: String, frames: List(Int))
}

/// The answer to `read_stacks` and `stop_stacks`. The method is always
/// polled `current_stacktrace`: samples are taken at reduction safe points,
/// so time in long built-ins is under-sampled and the result is not wall
/// time.
pub type StacksSnapshot {
  StacksSnapshot(
    probe_id: Int,
    state: ProbeState,
    stop: SamplingStop,
    meter: SamplerMeter,
    frames: List(StackFrame),
    stacks: List(SampledStack),
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
    "owners" -> owners_decoder()
    "counter_memory" -> counter_memory_decoder()
    "process_detail" -> process_detail_decoder()
    "supervision" -> supervision_decoder()
    "system" -> system_decoder()
    "gc" -> collection_decoder()
    "measure" -> measure_decoder()
    "stacks_started" -> {
      use probe_id <- decode.field(1, decode.int)
      use targets <- decode.field(2, decode.int)
      use rate_hz <- decode.field(3, decode.int)
      use duration_ms <- decode.field(4, decode.int)
      use max_samples <- decode.field(5, decode.int)
      decode.success(StacksStarted(
        probe_id:,
        targets:,
        rate_hz:,
        duration_ms:,
        max_samples:,
      ))
    }
    "stacks" -> stacks_decoder()
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

// ----------------------------------------------------------------- owners

fn owners_decoder() -> Decoder(Reply) {
  use coverage <- decode.field(1, coverage_decoder())
  use rows <- decode.field(2, decode.list(row_decoder()))
  use owners <- decode.field(3, decode.list(owner_heap_decoder()))
  use totals <- decode.field(4, census_totals_decoder())

  decode.success(
    OwnersReport(OwnersSnapshot(coverage:, rows:, owners:, totals:)),
  )
}

fn owner_heap_decoder() -> Decoder(OwnerHeapTotal) {
  use total <- decode.then(owner_total_decoder())
  use total_heap_words <- decode.field(5, decode.int)

  decode.success(OwnerHeapTotal(total:, total_heap_words:))
}

fn census_totals_decoder() -> Decoder(CensusTotals) {
  use processes <- decode.field(0, decode.int)
  use memory <- decode.field(1, decode.int)
  use queue_length <- decode.field(2, decode.int)
  use reductions <- decode.field(3, decode.int)
  use total_heap_words <- decode.field(4, decode.int)
  use owners_tracked <- decode.field(5, decode.int)
  use owners_listed <- decode.field(6, decode.int)

  decode.success(CensusTotals(
    processes:,
    memory:,
    queue_length:,
    reductions:,
    total_heap_words:,
    owners_tracked:,
    owners_listed:,
  ))
}

// ---------------------------------------------------------- counter memory

// `{<<"counter_memory">>, ProbeId, State, Memory}` where `Memory` is
// `{<<"none">>}` or `{<<"words">>, [{Module, Function, Arity, Words}]}`.
fn counter_memory_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use state <- decode.field(2, probe_state_decoder())
  use memory <- decode.field(3, counter_memory_value_decoder())

  decode.success(
    CounterMemoryReport(CounterMemorySnapshot(probe_id:, state:, memory:)),
  )
}

fn counter_memory_value_decoder() -> Decoder(CounterMemory) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "none" -> decode.success(NoMemoryCounted)
    "words" -> {
      use rows <- decode.field(1, decode.list(function_memory_decoder()))
      decode.success(MemoryCounted(rows:))
    }
    _ -> decode.failure(NoMemoryCounted, "a counter memory reading")
  }
}

fn function_memory_decoder() -> Decoder(FunctionMemory) {
  use module <- decode.field(0, decode.string)
  use function <- decode.field(1, decode.string)
  use arity <- decode.field(2, decode.int)
  use words <- decode.field(3, decode.int)

  decode.success(FunctionMemory(module:, function:, arity:, words:))
}

// ------------------------------------------------------- process detail

fn process_detail_decoder() -> Decoder(Reply) {
  use pid_text <- decode.field(1, decode.string)
  use sizes <- decode.field(2, sizes_decoder())
  use activity <- decode.field(3, activity_decoder())
  use gc <- decode.field(4, process_gc_decoder())
  use relations <- decode.field(5, relations_decoder())
  use owner <- decode.field(6, owner_decoder())
  use capabilities <- decode.field(7, decode.list(decode.string))

  decode.success(
    ProcessDetailReport(ProcessDetail(
      pid_text:,
      sizes:,
      activity:,
      gc:,
      relations:,
      owner:,
      capabilities:,
    )),
  )
}

fn sizes_decoder() -> Decoder(ProcessSizes) {
  use memory_bytes <- decode.field(0, decode.int)
  use total_heap_bytes <- decode.field(1, decode.int)
  use heap_bytes <- decode.field(2, decode.int)
  use stack_bytes <- decode.field(3, decode.int)

  decode.success(ProcessSizes(
    memory_bytes:,
    total_heap_bytes:,
    heap_bytes:,
    stack_bytes:,
  ))
}

fn activity_decoder() -> Decoder(ProcessActivity) {
  use queue_length <- decode.field(0, decode.int)
  use reductions <- decode.field(1, decode.int)
  use status <- decode.field(2, decode.string)
  use current_function <- decode.field(3, decode.string)
  use initial_call <- decode.field(4, decode.string)
  use registered_name <- decode.field(5, decode.string)

  decode.success(ProcessActivity(
    queue_length:,
    reductions:,
    status:,
    current_function:,
    initial_call:,
    registered_name:,
  ))
}

fn process_gc_decoder() -> Decoder(ProcessGc) {
  use minor_gcs <- decode.field(0, decode.int)
  use fullsweep_after <- decode.field(1, decode.int)
  use min_heap_bytes <- decode.field(2, decode.int)
  use max_heap_bytes <- decode.field(3, decode.int)
  use heap_block_bytes <- decode.field(4, decode.int)
  use old_heap_bytes <- decode.field(5, decode.int)
  use old_heap_block_bytes <- decode.field(6, decode.int)
  use mbuf_bytes <- decode.field(7, decode.int)
  use bin_vheap_bytes <- decode.field(8, decode.int)

  decode.success(ProcessGc(
    minor_gcs:,
    fullsweep_after:,
    min_heap_bytes:,
    max_heap_bytes:,
    heap_block_bytes:,
    old_heap_bytes:,
    old_heap_block_bytes:,
    mbuf_bytes:,
    bin_vheap_bytes:,
  ))
}

fn relations_decoder() -> Decoder(ProcessRelations) {
  use links <- decode.field(0, decode.int)
  use monitors <- decode.field(1, decode.int)
  use monitored_by <- decode.field(2, decode.int)
  use parent_pid_text <- decode.field(3, decode.string)

  decode.success(ProcessRelations(
    links:,
    monitors:,
    monitored_by:,
    parent_pid_text:,
  ))
}

// ------------------------------------------------------------ supervision

fn supervision_decoder() -> Decoder(Reply) {
  use coverage <- decode.field(1, supervision_coverage_decoder())
  use edges <- decode.field(2, decode.list(edge_decoder()))

  decode.success(SupervisionReport(SupervisionSnapshot(coverage:, edges:)))
}

fn supervision_coverage_decoder() -> Decoder(SupervisionCoverage) {
  use scanned <- decode.field(0, decode.int)
  use total <- decode.field(1, decode.int)
  use stop <- decode.field(2, walk_stop_decoder())
  use elapsed_ms <- decode.field(3, decode.int)

  decode.success(SupervisionCoverage(scanned:, total:, stop:, elapsed_ms:))
}

fn walk_stop_decoder() -> Decoder(WalkStop) {
  use code <- decode.then(decode.string)

  case code {
    "finished" -> decode.success(SupervisionFinished)
    "scan_budget" -> decode.success(SupervisionScanBudget)
    "deadline" -> decode.success(SupervisionDeadline)
    "edge_budget" -> decode.success(SupervisionEdgeBudget)
    _ -> decode.failure(SupervisionFinished, "a supervision stop reason")
  }
}

fn edge_decoder() -> Decoder(SpawnEdge) {
  use child_pid_text <- decode.field(0, decode.string)
  use parent_pid_text <- decode.field(1, decode.string)
  use registered_name <- decode.field(2, decode.string)
  use initial_call <- decode.field(3, decode.string)
  use owner <- decode.field(4, owner_decoder())

  decode.success(SpawnEdge(
    child_pid_text:,
    parent_pid_text:,
    registered_name:,
    initial_call:,
    owner:,
  ))
}

// ----------------------------------------------------------------- system

fn system_decoder() -> Decoder(Reply) {
  use facts <- decode.field(1, facts_decoder())
  use carriers <- decode.field(2, carriers_decoder())

  decode.success(SystemReport(SystemSnapshot(facts:, carriers:)))
}

fn facts_decoder() -> Decoder(NodeFacts) {
  use uptime_ms <- decode.field(0, decode.int)
  use creation <- decode.field(1, decode.int)
  use emulator_flavor <- decode.field(2, decode.string)
  use emulator_type <- decode.field(3, decode.string)
  use erts_version <- decode.field(4, decode.string)
  use otp_release <- decode.field(5, decode.string)
  use schedulers <- decode.field(6, decode.int)
  use schedulers_online <- decode.field(7, decode.int)
  use dirty_cpu <- decode.field(8, decode.int)
  use dirty_cpu_online <- decode.field(9, decode.int)
  use dirty_io <- decode.field(10, decode.int)
  use word_size <- decode.field(11, decode.int)

  decode.success(NodeFacts(
    uptime_ms:,
    creation:,
    emulator_flavor:,
    emulator_type:,
    erts_version:,
    otp_release:,
    schedulers:,
    schedulers_online:,
    dirty_cpu:,
    dirty_cpu_online:,
    dirty_io:,
    word_size:,
  ))
}

// `{<<"unavailable">>, Reason}` or `{<<"carriers">>, [Row]}`.
fn carriers_decoder() -> Decoder(Carriers) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "unavailable" -> {
      use reason <- decode.field(1, decode.string)
      decode.success(CarriersUnavailable(reason:))
    }
    "carriers" -> {
      use rows <- decode.field(1, decode.list(carrier_row_decoder()))
      decode.success(CarriersRead(rows:))
    }
    _ -> decode.failure(CarriersUnavailable(""), "a carrier reading")
  }
}

fn carrier_row_decoder() -> Decoder(CarrierRow) {
  use allocator <- decode.field(0, decode.string)
  use pool <- decode.field(1, decode.bool)
  use carriers <- decode.field(2, decode.int)
  use total_bytes <- decode.field(3, decode.int)
  use used_bytes <- decode.field(4, decode.int)
  use unscanned_bytes <- decode.field(5, decode.int)

  decode.success(CarrierRow(
    allocator:,
    pool: case pool {
      True -> InCarrierPool
      False -> NotInCarrierPool
    },
    carriers:,
    total_bytes:,
    used_bytes:,
    unscanned_bytes:,
  ))
}

// ------------------------------------------------------------- collection

fn collection_decoder() -> Decoder(Reply) {
  use class <- decode.field(1, decode.string)
  use pid_text <- decode.field(2, decode.string)
  use outcome <- decode.field(3, outcome_decoder())
  use elapsed_ms <- decode.field(4, decode.int)
  use before <- decode.field(5, heap_reading_decoder())
  use after <- decode.field(6, heap_reading_decoder())

  // The class is fixed by the protocol. A reply that names another class is
  // not one this build knows how to present as intrusive.
  case class {
    "intrusive" ->
      decode.success(
        CollectionReport(CollectionSnapshot(
          pid_text:,
          outcome:,
          elapsed_ms:,
          before:,
          after:,
        )),
      )
    _ ->
      decode.failure(
        CollectionReport(CollectionSnapshot(
          pid_text:,
          outcome:,
          elapsed_ms:,
          before:,
          after:,
        )),
        "an intrusive collection",
      )
  }
}

fn outcome_decoder() -> Decoder(CollectionOutcome) {
  use code <- decode.then(decode.string)

  case code {
    "completed" -> decode.success(CollectionCompleted)
    "target_gone" -> decode.success(CollectionTargetGone)
    _ -> decode.failure(CollectionCompleted, "a collection outcome")
  }
}

// `{<<"gone">>}` or `{<<"heap">>, Memory, TotalHeap, Heap, HeapBlock,
// OldHeap, OldHeapBlock, Mbuf, Stack, BinVheap}`.
fn heap_reading_decoder() -> Decoder(HeapReading) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "gone" -> decode.success(HeapGone)
    "heap" -> {
      use memory_bytes <- decode.field(1, decode.int)
      use total_heap_bytes <- decode.field(2, decode.int)
      use heap_bytes <- decode.field(3, decode.int)
      use heap_block_bytes <- decode.field(4, decode.int)
      use old_heap_bytes <- decode.field(5, decode.int)
      use old_heap_block_bytes <- decode.field(6, decode.int)
      use mbuf_bytes <- decode.field(7, decode.int)
      use stack_bytes <- decode.field(8, decode.int)
      use bin_vheap_bytes <- decode.field(9, decode.int)

      decode.success(
        HeapRead(HeapSizes(
          memory_bytes:,
          total_heap_bytes:,
          heap_bytes:,
          heap_block_bytes:,
          old_heap_bytes:,
          old_heap_block_bytes:,
          mbuf_bytes:,
          stack_bytes:,
          bin_vheap_bytes:,
        )),
      )
    }
    _ -> decode.failure(HeapGone, "a heap reading")
  }
}

// ---------------------------------------------------------------- measure

fn measure_decoder() -> Decoder(Reply) {
  use pid_text <- decode.field(1, decode.string)
  use elapsed_ms <- decode.field(2, decode.int)
  use readings <- decode.field(3, decode.list(self_reading_decoder()))

  decode.success(
    MeasureReport(MeasureSnapshot(pid_text:, elapsed_ms:, readings:)),
  )
}

fn self_reading_decoder() -> Decoder(SelfReading) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.int)
  use unit <- decode.field(2, reading_unit_decoder())

  decode.success(SelfReading(name:, value:, unit:))
}

fn reading_unit_decoder() -> Decoder(ReadingUnit) {
  use code <- decode.then(decode.string)

  case code {
    "words" -> decode.success(ReadingWords)
    "bytes" -> decode.success(ReadingBytes)
    "count" -> decode.success(ReadingCount)
    _ -> decode.failure(ReadingCount, "a reading unit")
  }
}

// ----------------------------------------------------------------- stacks

fn stacks_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use state <- decode.field(2, probe_state_decoder())
  use stop <- decode.field(3, sampling_stop_decoder())
  use meter <- decode.field(4, meter_decoder())
  use frames <- decode.field(5, decode.list(stack_frame_decoder()))
  use stacks <- decode.field(6, decode.list(sampled_stack_decoder()))

  decode.success(
    StacksReport(StacksSnapshot(
      probe_id:,
      state:,
      stop:,
      meter:,
      frames:,
      stacks:,
    )),
  )
}

fn sampling_stop_decoder() -> Decoder(SamplingStop) {
  use code <- decode.then(decode.string)

  case code {
    "running" -> decode.success(SamplingRunning)
    "deadline" -> decode.success(SamplingDeadline)
    "sample_budget" -> decode.success(SamplingBudget)
    "targets_gone" -> decode.success(SamplingTargetsGone)
    "stopped" -> decode.success(SamplingStopped)
    _ -> decode.failure(SamplingRunning, "a sampling stop reason")
  }
}

// The method is fixed: polled `current_stacktrace`. A reply naming another
// method would need a different caveat on screen, so it is an error here.
fn meter_decoder() -> Decoder(SamplerMeter) {
  use method <- decode.field(0, decode.string)
  use requested_hz <- decode.field(1, decode.int)
  use achieved_millihz <- decode.field(2, decode.int)
  use rounds <- decode.field(3, decode.int)
  use samples <- decode.field(4, decode.int)
  use elapsed_ms <- decode.field(5, decode.int)
  use depth_limit <- decode.field(6, decode.int)
  use at_depth_limit <- decode.field(7, decode.int)
  use targets_gone <- decode.field(8, decode.int)
  use dropped_samples <- decode.field(9, decode.int)
  use distinct_stacks <- decode.field(10, decode.int)
  use truncated_samples <- decode.field(11, decode.int)

  let meter =
    SamplerMeter(
      requested_hz:,
      achieved_millihz:,
      rounds:,
      samples:,
      elapsed_ms:,
      depth_limit:,
      at_depth_limit:,
      targets_gone:,
      dropped_samples:,
      distinct_stacks:,
      truncated_samples:,
    )

  case method {
    "polled_current_stacktrace" -> decode.success(meter)
    _ -> decode.failure(meter, "the polled stacktrace method")
  }
}

fn stack_frame_decoder() -> Decoder(StackFrame) {
  use module <- decode.field(0, decode.string)
  use function <- decode.field(1, decode.string)
  use arity <- decode.field(2, decode.int)
  use location <- decode.field(3, frame_location_decoder())

  decode.success(StackFrame(module:, function:, arity:, location:))
}

// `{<<"none">>}`, `{<<"file">>, File}` or `{<<"at">>, File, Line}`.
fn frame_location_decoder() -> Decoder(FrameLocation) {
  use tag <- decode.field(0, decode.string)

  case tag {
    "none" -> decode.success(NoLocation)
    "file" -> {
      use file <- decode.field(1, decode.string)
      decode.success(FileOnly(file:))
    }
    "at" -> {
      use file <- decode.field(1, decode.string)
      use line <- decode.field(2, decode.int)
      decode.success(AtLine(file:, line:))
    }
    _ -> decode.failure(NoLocation, "a frame location")
  }
}

fn sampled_stack_decoder() -> Decoder(SampledStack) {
  use count <- decode.field(0, decode.int)
  use status <- decode.field(1, decode.string)
  use frames <- decode.field(2, decode.list(decode.int))

  decode.success(SampledStack(count:, status:, frames:))
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

// ------------------------------------------------------ extended requests

/// One `{Module, Function}` pair of a counters probe. A function of `"_"`
/// covers every function of the module.
pub type CounterPattern {
  CounterPattern(module: String, function: String)
}

/// What a counters probe measures. `CountTimeAndMemory` also counts the words
/// each function allocates, which only some OTP releases can do; where the VM
/// lacks it the agent refuses the probe with `memory_unavailable`.
pub type CounterMode {
  CountTime
  CountTimeAndMemory
}

/// The requests added after the first wire release. They are a type of their
/// own so that `Request`, which the viewer already matches on exhaustively,
/// stays source compatible: adding a variant to it would break every such
/// match at once. A later change can fold the two together when the viewer
/// is rewired.
pub type ExtendedRequest {

  /// The census with owner heap capacity and totals over every scanned
  /// process.
  AskOwners(max_scanned: Int, top_k: Int)

  /// A counters probe over several patterns, with optional allocation
  /// counting.
  AskStartCounterSet(
    patterns: List(CounterPattern),
    targets: Targets,
    deadline_ms: Int,
    mode: CounterMode,
  )

  /// A counters probe's allocation, read before the probe is stopped.
  AskReadCounterMemory(probe_id: Int)

  /// One pinned process in detail.
  AskProcessDetail(token: PinToken)

  /// Parent edges over the node.
  AskSupervision(max_scanned: Int, max_edges: Int)

  /// Node facts and allocator carriers.
  AskSystem

  /// A targeted collection of one pinned process. Intrusive: the target
  /// stops while it collects.
  AskGc(token: PinToken, deadline_ms: Int)

  /// Ask a process that advertises the capability to measure itself.
  AskMeasure(token: PinToken, budget_ms: Int)

  /// A stack sampling probe over pinned processes.
  AskStartStacks(
    tokens: List(PinToken),
    rate_hz: Int,
    duration_ms: Int,
    max_samples: Int,
  )

  /// Read a running or finished stack probe.
  AskReadStacks(probe_id: Int)

  /// Stop a stack probe and return its result.
  AskStopStacks(probe_id: Int)
}

/// Write an extended request as the envelope the agent reads, exactly as
/// `encode_request` does for the original set.
///
/// ## Examples
///
/// ```gleam
/// wire.encode_extended_request(reply_to, reference, wire.AskSystem)
/// // -> {<<"pg">>, 1, ReplyTo, Ref, {<<"system">>}}
/// ```
pub fn encode_extended_request(
  reply_to: Dynamic,
  reference: Dynamic,
  request: ExtendedRequest,
) -> Dynamic {
  dynamic.array([
    dynamic.string("pg"),
    dynamic.int(wire_version),
    reply_to,
    reference,
    extended_body(request),
  ])
}

fn extended_body(request: ExtendedRequest) -> Dynamic {
  case request {
    AskOwners(max_scanned, top_k) ->
      tagged("owners", [dynamic.int(max_scanned), dynamic.int(top_k)])
    AskStartCounterSet(patterns, targets, deadline_ms, mode) ->
      tagged("start_counter_set", [
        dynamic.list(list.map(patterns, pattern_term)),
        targets_term(targets),
        dynamic.int(deadline_ms),
        counter_mode_term(mode),
      ])
    AskReadCounterMemory(id) -> tagged("read_counter_memory", [dynamic.int(id)])
    AskProcessDetail(token) -> tagged("process_detail", [token_term(token)])
    AskSupervision(max_scanned, max_edges) ->
      tagged("supervision", [dynamic.int(max_scanned), dynamic.int(max_edges)])
    AskSystem -> tagged("system", [])
    AskGc(token, deadline_ms) ->
      tagged("gc", [token_term(token), dynamic.int(deadline_ms)])
    AskMeasure(token, budget_ms) ->
      tagged("measure", [token_term(token), dynamic.int(budget_ms)])
    AskStartStacks(tokens, rate_hz, duration_ms, max_samples) ->
      tagged("start_stacks", [
        dynamic.list(list.map(tokens, token_term)),
        dynamic.int(rate_hz),
        dynamic.int(duration_ms),
        dynamic.int(max_samples),
      ])
    AskReadStacks(id) -> tagged("read_stacks", [dynamic.int(id)])
    AskStopStacks(id) -> tagged("stop_stacks", [dynamic.int(id)])
  }
}

fn pattern_term(pattern: CounterPattern) -> Dynamic {
  dynamic.array([
    dynamic.string(pattern.module),
    dynamic.string(pattern.function),
  ])
}

fn counter_mode_term(mode: CounterMode) -> Dynamic {
  case mode {
    CountTime -> dynamic.string("time")
    CountTimeAndMemory -> dynamic.string("time_and_memory")
  }
}
