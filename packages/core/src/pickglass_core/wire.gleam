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

/// The number of ETS tables the viewer asks for unless it has a reason to ask
/// for another.
pub const default_ets_top_k = 100

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
  OwnersDetailReport(OwnersDetailSnapshot)
  EtsTablesReport(EtsSnapshot)
  BinariesReport(BinariesSnapshot)
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
  CalltraceStarted(
    probe_id: Int,
    targets: Int,
    matched_functions: Int,
    duration_ms: Int,
    max_events: Int,
    timeline_limit: Int,
  )
  CalltraceReport(CalltraceSnapshot)
  EventsStarted(
    probe_id: Int,
    targets: Int,
    duration_ms: Int,
    max_events: Int,
    slice_limit: Int,
    long_gc_ms: Int,
    long_schedule_ms: Int,
  )
  EventsReport(EventsSnapshot)
  Detached(reason: String)

  /// The answer to a `join`: the viewer is attached to the agent that was
  /// already running, and `viewers` counts the viewers it serves now.
  Joined(viewers: Int)

  /// The answer to a `detach` that left other viewers attached. The agent
  /// and its modules stay; `remaining` is how many viewers are still on it.
  /// The detach that leaves none is answered `Detached`.
  Left(remaining: Int)
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

/// A census row with the process's `proc_lib` initial call. `initial_call` is
/// `module:function/arity` of the call `proc_lib` recorded, so a supervisor
/// reads `supervisor:my_sup/1` and a `gen_server` reads `my_server:init/1`, or
/// `""` for a process `proc_lib` did not start.
pub type DetailedRow {
  DetailedRow(row: ProcessRow, initial_call: String)
}

/// An owner's totals with the ETS tables its processes own: how many and
/// their memory in bytes. Tables owned by an unlabelled process count under
/// the unlabelled owner.
pub type OwnerDetail {
  OwnerDetail(owner: OwnerHeapTotal, ets_tables: Int, ets_bytes: Int)
}

/// Why the ETS pass of an owners census ended.
pub type EtsStop {
  /// Every table the list named was read or found deleted.
  EtsFinished

  /// The deadline passed with tables unread, so the ETS figures understate.
  EtsDeadline
}

/// What the ETS pass read over every table on the node, whether or not its
/// owner is listed: how many tables, their memory in bytes, how many were
/// deleted before they could be read, and why the pass ended. The remainder
/// row's ETS figures are these minus the listed owners'.
pub type EtsPass {
  EtsPass(tables: Int, memory_bytes: Int, skipped: Int, stop: EtsStop)
}

/// The answer to `owners_detail`: the `owners` census with each row's initial
/// call, each owner's ETS memory and the totals of the ETS pass.
pub type OwnersDetailSnapshot {
  OwnersDetailSnapshot(
    coverage: CensusCoverage,
    rows: List(DetailedRow),
    owners: List(OwnerDetail),
    totals: CensusTotals,
    ets: EtsPass,
  )
}

/// How much of the node's ETS tables a listing covered. `total` is the number
/// of tables when the walk began, `counted` how many were read and `skipped`
/// how many were deleted before they could be.
pub type EtsCoverage {
  EtsCoverage(
    total: Int,
    counted: Int,
    skipped: Int,
    stop: EtsStop,
    elapsed_ms: Int,
  )
}

/// One ETS table, described by its properties and never its contents. `name`
/// is `""` for a table with no name, `heir_pid_text` is `""` for one with no
/// heir and `owner_name` is `""` for an owner with no registered name. `memory_bytes` is bytes; `objects` is the object count.
pub type EtsTable {
  EtsTable(
    id_text: String,
    name: String,
    owner_pid_text: String,
    owner: OwnerReading,
    owner_name: String,
    kind: String,
    objects: Int,
    memory_bytes: Int,
    protection: String,
    heir_pid_text: String,
  )
}

/// The sums over every table a listing read, listed or not.
pub type EtsTotals {
  EtsTotals(tables: Int, objects: Int, memory_bytes: Int)
}

/// The answer to `ets_tables`: the largest tables by memory, the totals over
/// all tables read and the coverage.
pub type EtsSnapshot {
  EtsSnapshot(coverage: EtsCoverage, tables: List(EtsTable), totals: EtsTotals)
}

/// One reference-counted binary a process holds. `address_text` is its
/// address in hexadecimal, which identifies the same binary across processes.
pub type BinaryRef {
  BinaryRef(address_text: String, bytes: Int, refc: Int)
}

/// The answer to `binaries`: how many different binaries the process holds,
/// their total size in bytes, how many references it holds to them, and the
/// largest ones. A binary held through several references is counted once, so
/// `references` is at least `distinct`, and `distinct` minus the length of
/// `binaries` is how many the listing leaves out. A sub-binary counts the
/// whole binary's size, so `bytes` is what the process keeps alive and not
/// memory unique to it.
pub type BinariesSnapshot {
  BinariesSnapshot(
    pid_text: String,
    distinct: Int,
    bytes: Int,
    references: Int,
    binaries: List(BinaryRef),
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

/// Why a call tree or an events probe stopped, or that it has not. The agent
/// stops a probe itself at its window, at its event budget, and when the
/// mailbox of its tracer grows past the limit (`TraceOverrun`): a traced
/// process produces events faster than the tracer can fold them, and the
/// probe ends instead of letting the backlog grow.
pub type TraceStop {
  TraceRunning
  TraceDeadline
  TraceBudget
  TraceOverrun
  TraceTargetsGone
  TraceStopped
}

/// What an event probe measured about its own run. `events` were folded into
/// the result and `max_events` is the budget. `dropped_events` arrived after
/// the probe stopped and were discarded unread; `in_flight_at_stop` were
/// already queued at the moment it stopped, so the two normally agree, and
/// `dropped_events` is larger by the few that were sent while the stream was
/// being cut. `peak_queue` is the longest tracer mailbox seen, against
/// `queue_limit`.
pub type TraceMeter {
  TraceMeter(
    elapsed_ms: Int,
    events: Int,
    max_events: Int,
    dropped_events: Int,
    in_flight_at_stop: Int,
    peak_queue: Int,
    queue_limit: Int,
    targets_gone: Int,
  )
}

/// A call tree probe's meter: the shared one, and what the call paths leave
/// out. `forced_closes` frames were still open when the probe stopped and were
/// closed at the latest timestamp seen. `dropped_calls` were on a path past
/// the path table's bound, `elided_calls` were deeper than `depth_limit`, and
/// `strays` were events the tree could not use.
pub type CalltraceMeter {
  CalltraceMeter(
    trace: TraceMeter,
    forced_closes: Int,
    distinct_paths: Int,
    dropped_calls: Int,
    elided_calls: Int,
    strays: Int,
    depth_limit: Int,
  )
}

/// One call path with its totals. `frames` index the snapshot's frame table,
/// leaf first, as a sampled stack's do. Times are traced time in nanoseconds,
/// which includes any time the process was descheduled: `exclusive_ns` is
/// `inclusive_ns` less what the path's callees took, and the exclusive times
/// of all paths sum to the traced time.
pub type CallPath {
  CallPath(calls: Int, inclusive_ns: Int, exclusive_ns: Int, frames: List(Int))
}

/// One closed call, for a timeline. `process` indexes the snapshot's
/// `processes`, `frame` its frame table, and `start_ns` counts from the
/// tracer's start.
pub type CallSlice {
  CallSlice(
    process: Int,
    frame: Int,
    start_ns: Int,
    duration_ns: Int,
    depth: Int,
  )
}

/// The answer to `read_calltrace` and `stop_calltrace`. Frames have the shape
/// of a sampled stack's and no location, so one reader serves both, and the
/// method is always traced `call` with `return_to`, each call carrying its
/// caller. Directly recursive calls more than one level deep read as two
/// levels, and time outside the traced functions is not seen.
pub type CalltraceSnapshot {
  CalltraceSnapshot(
    probe_id: Int,
    state: ProbeState,
    stop: TraceStop,
    meter: CalltraceMeter,
    frames: List(StackFrame),
    paths: List(CallPath),
    processes: List(String),
    slices: List(CallSlice),
  )
}

/// An events probe's meter: the shared one, and what its results leave out.
/// `unpaired_events` had no start or end to pair with, `dropped_slices` were
/// past the slice limit, `long_events_seen` counts every node-wide threshold
/// event including those past the list's bound, and `strays` were events the
/// record could not use. The two thresholds are the ones in force, in
/// milliseconds, and zero is off.
pub type EventsMeter {
  EventsMeter(
    trace: TraceMeter,
    unpaired_events: Int,
    dropped_slices: Int,
    long_events_seen: Int,
    strays: Int,
    long_gc_ms: Int,
    long_schedule_ms: Int,
  )
}

/// One traced process's scheduling and collection totals. `run_ns` is time
/// on a scheduler, the closest the BEAM comes to a per-process CPU time.
pub type TracedProcess {
  TracedProcess(
    pid_text: String,
    runs: Int,
    run_ns: Int,
    minor_gcs: Int,
    major_gcs: Int,
    gc_ns: Int,
  )
}

/// What an events slice describes.
pub type ActivityKind {
  RunSlice
  MinorGcSlice
  MajorGcSlice
}

/// One run or collection, for a timeline. `process` indexes the snapshot's
/// `processes`, and `start_ns` counts from the tracer's start.
pub type ActivitySlice {
  ActivitySlice(
    process: Int,
    kind: ActivityKind,
    start_ns: Int,
    duration_ns: Int,
  )
}

/// A node-wide threshold event, as the VM reported it. It concerns any
/// process, not only the traced ones.
pub type LongEvent {
  /// A collection that took `duration_ms` and left `heap_words` of heap.
  LongGc(pid_text: String, duration_ms: Int, heap_words: Int)

  /// A timeslice that lasted `duration_ms` and ended in `function`, which is
  /// empty when the VM named none.
  LongSchedule(pid_text: String, duration_ms: Int, function: String)
}

/// The answer to `read_events` and `stop_events`. `processes` are the traced
/// processes in the order the request named them, with their totals, and
/// `slices` are the first runs and collections to close.
pub type EventsSnapshot {
  EventsSnapshot(
    probe_id: Int,
    state: ProbeState,
    stop: TraceStop,
    meter: EventsMeter,
    processes: List(TracedProcess),
    slices: List(ActivitySlice),
    long: List(LongEvent),
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
    "owners_detail" -> owners_detail_decoder()
    "ets_tables" -> ets_tables_decoder()
    "binaries" -> binaries_decoder()
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
    "calltrace_started" -> calltrace_started_decoder()
    "calltrace" -> calltrace_decoder()
    "events_started" -> events_started_decoder()
    "events" -> events_decoder()
    "detached" -> {
      use reason <- decode.field(1, decode.string)
      decode.success(Detached(reason))
    }
    "joined" -> {
      use viewers <- decode.field(1, decode.int)
      decode.success(Joined(viewers))
    }
    "left" -> {
      use remaining <- decode.field(1, decode.int)
      decode.success(Left(remaining))
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

// ----------------------------------------------------------- owners detail

// `{<<"owners_detail">>, Coverage, Rows, Owners, Totals, EtsPass}`: the shape
// of `owners` with one field appended to each row (the initial call), two to
// each owner (ETS tables and bytes) and the ETS pass at the end. The shared
// parts are read with the `owners` decoders, which read tuples by position.
fn owners_detail_decoder() -> Decoder(Reply) {
  use coverage <- decode.field(1, coverage_decoder())
  use rows <- decode.field(2, decode.list(detailed_row_decoder()))
  use owners <- decode.field(3, decode.list(owner_detail_decoder()))
  use totals <- decode.field(4, census_totals_decoder())
  use ets <- decode.field(5, ets_pass_decoder())

  decode.success(
    OwnersDetailReport(OwnersDetailSnapshot(
      coverage:,
      rows:,
      owners:,
      totals:,
      ets:,
    )),
  )
}

fn detailed_row_decoder() -> Decoder(DetailedRow) {
  use row <- decode.then(row_decoder())
  use initial_call <- decode.field(11, decode.string)

  decode.success(DetailedRow(row:, initial_call:))
}

fn owner_detail_decoder() -> Decoder(OwnerDetail) {
  use owner <- decode.then(owner_heap_decoder())
  use ets_tables <- decode.field(6, decode.int)
  use ets_bytes <- decode.field(7, decode.int)

  decode.success(OwnerDetail(owner:, ets_tables:, ets_bytes:))
}

fn ets_pass_decoder() -> Decoder(EtsPass) {
  use tables <- decode.field(0, decode.int)
  use memory_bytes <- decode.field(1, decode.int)
  use skipped <- decode.field(2, decode.int)
  use stop <- decode.field(3, ets_stop_decoder())

  decode.success(EtsPass(tables:, memory_bytes:, skipped:, stop:))
}

fn ets_stop_decoder() -> Decoder(EtsStop) {
  use code <- decode.then(decode.string)

  case code {
    "finished" -> decode.success(EtsFinished)
    "deadline" -> decode.success(EtsDeadline)
    _ -> decode.failure(EtsFinished, "an ETS stop reason")
  }
}

// ------------------------------------------------------------ ets tables

// `{<<"ets_tables">>, {Total, Counted, Skipped, Stop, ElapsedMs}, Tables,
// {Tables, Objects, MemoryBytes}}`.
fn ets_tables_decoder() -> Decoder(Reply) {
  use coverage <- decode.field(1, ets_coverage_decoder())
  use tables <- decode.field(2, decode.list(ets_table_decoder()))
  use totals <- decode.field(3, ets_totals_decoder())

  decode.success(EtsTablesReport(EtsSnapshot(coverage:, tables:, totals:)))
}

fn ets_coverage_decoder() -> Decoder(EtsCoverage) {
  use total <- decode.field(0, decode.int)
  use counted <- decode.field(1, decode.int)
  use skipped <- decode.field(2, decode.int)
  use stop <- decode.field(3, ets_stop_decoder())
  use elapsed_ms <- decode.field(4, decode.int)

  decode.success(EtsCoverage(total:, counted:, skipped:, stop:, elapsed_ms:))
}

fn ets_table_decoder() -> Decoder(EtsTable) {
  use id_text <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use owner_pid_text <- decode.field(2, decode.string)
  use owner <- decode.field(3, owner_decoder())
  use kind <- decode.field(4, decode.string)
  use objects <- decode.field(5, decode.int)
  use memory_bytes <- decode.field(6, decode.int)
  use protection <- decode.field(7, decode.string)
  use heir_pid_text <- decode.field(8, decode.string)
  use owner_name <- decode.field(9, decode.string)

  decode.success(EtsTable(
    id_text:,
    name:,
    owner_pid_text:,
    owner:,
    owner_name:,
    kind:,
    objects:,
    memory_bytes:,
    protection:,
    heir_pid_text:,
  ))
}

fn ets_totals_decoder() -> Decoder(EtsTotals) {
  use tables <- decode.field(0, decode.int)
  use objects <- decode.field(1, decode.int)
  use memory_bytes <- decode.field(2, decode.int)

  decode.success(EtsTotals(tables:, objects:, memory_bytes:))
}

// ------------------------------------------------------------- binaries

// `{<<"binaries">>, PidText, Distinct, Bytes, References, [{AddressText,
// Bytes, RefCount}]}`.
fn binaries_decoder() -> Decoder(Reply) {
  use pid_text <- decode.field(1, decode.string)
  use distinct <- decode.field(2, decode.int)
  use bytes <- decode.field(3, decode.int)
  use references <- decode.field(4, decode.int)
  use binaries <- decode.field(5, decode.list(binary_ref_decoder()))

  decode.success(
    BinariesReport(BinariesSnapshot(
      pid_text:,
      distinct:,
      bytes:,
      references:,
      binaries:,
    )),
  )
}

fn binary_ref_decoder() -> Decoder(BinaryRef) {
  use address_text <- decode.field(0, decode.string)
  use bytes <- decode.field(1, decode.int)
  use refc <- decode.field(2, decode.int)

  decode.success(BinaryRef(address_text:, bytes:, refc:))
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

// ------------------------------------------------------------------ traces

fn trace_stop_decoder() -> Decoder(TraceStop) {
  use code <- decode.then(decode.string)

  case code {
    "running" -> decode.success(TraceRunning)
    "deadline" -> decode.success(TraceDeadline)
    "event_budget" -> decode.success(TraceBudget)
    "overrun" -> decode.success(TraceOverrun)
    "targets_gone" -> decode.success(TraceTargetsGone)
    "stopped" -> decode.success(TraceStopped)
    _ -> decode.failure(TraceRunning, "a trace stop reason")
  }
}

fn calltrace_started_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use targets <- decode.field(2, decode.int)
  use matched_functions <- decode.field(3, decode.int)
  use duration_ms <- decode.field(4, decode.int)
  use max_events <- decode.field(5, decode.int)
  use timeline_limit <- decode.field(6, decode.int)

  decode.success(CalltraceStarted(
    probe_id:,
    targets:,
    matched_functions:,
    duration_ms:,
    max_events:,
    timeline_limit:,
  ))
}

fn events_started_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use targets <- decode.field(2, decode.int)
  use duration_ms <- decode.field(3, decode.int)
  use max_events <- decode.field(4, decode.int)
  use slice_limit <- decode.field(5, decode.int)
  use long_gc_ms <- decode.field(6, decode.int)
  use long_schedule_ms <- decode.field(7, decode.int)

  decode.success(EventsStarted(
    probe_id:,
    targets:,
    duration_ms:,
    max_events:,
    slice_limit:,
    long_gc_ms:,
    long_schedule_ms:,
  ))
}

// The first nine fields of a meter, after its method, are the same for both
// probes. They sit at positions 1 to 8 of the meter tuple.
fn trace_meter_decoder() -> Decoder(TraceMeter) {
  use elapsed_ms <- decode.field(1, decode.int)
  use events <- decode.field(2, decode.int)
  use max_events <- decode.field(3, decode.int)
  use dropped_events <- decode.field(4, decode.int)
  use in_flight_at_stop <- decode.field(5, decode.int)
  use peak_queue <- decode.field(6, decode.int)
  use queue_limit <- decode.field(7, decode.int)
  use targets_gone <- decode.field(8, decode.int)

  decode.success(TraceMeter(
    elapsed_ms:,
    events:,
    max_events:,
    dropped_events:,
    in_flight_at_stop:,
    peak_queue:,
    queue_limit:,
    targets_gone:,
  ))
}

fn calltrace_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use state <- decode.field(2, probe_state_decoder())
  use stop <- decode.field(3, trace_stop_decoder())
  use meter <- decode.field(4, calltrace_meter_decoder())
  use frames <- decode.field(5, decode.list(stack_frame_decoder()))
  use paths <- decode.field(6, decode.list(call_path_decoder()))
  use processes <- decode.subfield([7, 0], decode.list(decode.string))
  use slices <- decode.subfield([7, 1], decode.list(call_slice_decoder()))

  decode.success(
    CalltraceReport(CalltraceSnapshot(
      probe_id:,
      state:,
      stop:,
      meter:,
      frames:,
      paths:,
      processes:,
      slices:,
    )),
  )
}

// The method is fixed: traced `call` with `return_to`. A reply naming another
// method would need a different caveat on screen, so it is an error here.
fn calltrace_meter_decoder() -> Decoder(CalltraceMeter) {
  use method <- decode.field(0, decode.string)
  use trace <- decode.then(trace_meter_decoder())
  use forced_closes <- decode.field(9, decode.int)
  use distinct_paths <- decode.field(10, decode.int)
  use dropped_calls <- decode.field(11, decode.int)
  use elided_calls <- decode.field(12, decode.int)
  use strays <- decode.field(13, decode.int)
  use depth_limit <- decode.field(14, decode.int)

  let meter =
    CalltraceMeter(
      trace:,
      forced_closes:,
      distinct_paths:,
      dropped_calls:,
      elided_calls:,
      strays:,
      depth_limit:,
    )

  case method {
    "traced_call_return_to" -> decode.success(meter)
    _ -> decode.failure(meter, "the traced call method")
  }
}

fn call_path_decoder() -> Decoder(CallPath) {
  use calls <- decode.field(0, decode.int)
  use inclusive_ns <- decode.field(1, decode.int)
  use exclusive_ns <- decode.field(2, decode.int)
  use frames <- decode.field(3, decode.list(decode.int))

  decode.success(CallPath(calls:, inclusive_ns:, exclusive_ns:, frames:))
}

fn call_slice_decoder() -> Decoder(CallSlice) {
  use process <- decode.field(0, decode.int)
  use frame <- decode.field(1, decode.int)
  use start_ns <- decode.field(2, decode.int)
  use duration_ns <- decode.field(3, decode.int)
  use depth <- decode.field(4, decode.int)

  decode.success(CallSlice(process:, frame:, start_ns:, duration_ns:, depth:))
}

fn events_decoder() -> Decoder(Reply) {
  use probe_id <- decode.field(1, decode.int)
  use state <- decode.field(2, probe_state_decoder())
  use stop <- decode.field(3, trace_stop_decoder())
  use meter <- decode.field(4, events_meter_decoder())
  use processes <- decode.field(5, decode.list(traced_process_decoder()))
  use slices <- decode.field(6, decode.list(activity_slice_decoder()))
  use long <- decode.field(7, decode.list(long_event_decoder()))

  decode.success(
    EventsReport(EventsSnapshot(
      probe_id:,
      state:,
      stop:,
      meter:,
      processes:,
      slices:,
      long:,
    )),
  )
}

fn events_meter_decoder() -> Decoder(EventsMeter) {
  use method <- decode.field(0, decode.string)
  use trace <- decode.then(trace_meter_decoder())
  use unpaired_events <- decode.field(9, decode.int)
  use dropped_slices <- decode.field(10, decode.int)
  use long_events_seen <- decode.field(11, decode.int)
  use strays <- decode.field(12, decode.int)
  use long_gc_ms <- decode.field(13, decode.int)
  use long_schedule_ms <- decode.field(14, decode.int)

  let meter =
    EventsMeter(
      trace:,
      unpaired_events:,
      dropped_slices:,
      long_events_seen:,
      strays:,
      long_gc_ms:,
      long_schedule_ms:,
    )

  case method {
    "traced_running_gc" -> decode.success(meter)
    _ -> decode.failure(meter, "the traced running method")
  }
}

fn traced_process_decoder() -> Decoder(TracedProcess) {
  use pid_text <- decode.field(0, decode.string)
  use runs <- decode.field(1, decode.int)
  use run_ns <- decode.field(2, decode.int)
  use minor_gcs <- decode.field(3, decode.int)
  use major_gcs <- decode.field(4, decode.int)
  use gc_ns <- decode.field(5, decode.int)

  decode.success(TracedProcess(
    pid_text:,
    runs:,
    run_ns:,
    minor_gcs:,
    major_gcs:,
    gc_ns:,
  ))
}

fn activity_slice_decoder() -> Decoder(ActivitySlice) {
  use process <- decode.field(0, decode.int)
  use kind <- decode.field(1, activity_kind_decoder())
  use start_ns <- decode.field(2, decode.int)
  use duration_ns <- decode.field(3, decode.int)

  decode.success(ActivitySlice(process:, kind:, start_ns:, duration_ns:))
}

fn activity_kind_decoder() -> Decoder(ActivityKind) {
  use code <- decode.then(decode.string)

  case code {
    "run" -> decode.success(RunSlice)
    "gc_minor" -> decode.success(MinorGcSlice)
    "gc_major" -> decode.success(MajorGcSlice)
    _ -> decode.failure(RunSlice, "a slice kind")
  }
}

// `{<<"long_gc">>, Pid, Ms, HeapWords}` or
// `{<<"long_schedule">>, Pid, Ms, Function}`: the fourth field depends on
// the kind.
fn long_event_decoder() -> Decoder(LongEvent) {
  use kind <- decode.field(0, decode.string)
  use pid_text <- decode.field(1, decode.string)
  use duration_ms <- decode.field(2, decode.int)

  case kind {
    "long_gc" -> {
      use heap_words <- decode.field(3, decode.int)
      decode.success(LongGc(pid_text:, duration_ms:, heap_words:))
    }
    "long_schedule" -> {
      use function <- decode.field(3, decode.string)
      decode.success(LongSchedule(pid_text:, duration_ms:, function:))
    }
    _ -> decode.failure(LongGc("", 0, 0), "a threshold event kind")
  }
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

  /// A request added after the first release; see `ExtendedRequest`.
  Extended(request: ExtendedRequest)
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
    Extended(inner) -> extended_body(inner)
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

  /// The census with each row's `proc_lib` initial call and each owner's ETS
  /// memory. It walks every ETS table after the processes, which costs time
  /// in proportion to the table count and is bounded by the census deadline.
  AskOwnersDetail(max_scanned: Int, top_k: Int)

  /// The largest ETS tables by memory, at most `top_k` (1 to 500, clamped),
  /// described by properties only. `default_ets_top_k` is the usual count.
  AskEtsTables(top_k: Int)

  /// The reference-counted binaries one pinned process holds, the largest
  /// `top_k` (1 to 200, clamped) listed. Costly for a process holding many
  /// binaries: a process with more than 50,000 references is refused with
  /// `too_many_binaries` rather than summarised.
  AskBinaries(token: PinToken, top_k: Int)

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

  /// A call tree probe over one to four pinned processes and one to eight
  /// patterns, with the same pattern rules as a counters probe. The window is
  /// 100 ms to 10 s, the event budget up to 200,000, and `timeline_limit`
  /// is how many raw call slices to keep, 0 to 2,000. Values outside the
  /// bounds are clamped, and the reply says what was settled on.
  AskStartCalltrace(
    tokens: List(PinToken),
    patterns: List(CounterPattern),
    duration_ms: Int,
    max_events: Int,
    timeline_limit: Int,
  )

  /// Read a running or finished call tree probe.
  AskReadCalltrace(probe_id: Int)

  /// Stop a call tree probe and return its result.
  AskStopCalltrace(probe_id: Int)

  /// A scheduling and collection probe over one to eight pinned processes.
  /// The window is 100 ms to 60 s, the event budget up to 200,000,
  /// `slice_limit` is 0 to 5,000, and a threshold of 0 is off. The two
  /// thresholds are node-wide and exist on OTP 28 and later; a node without
  /// them refuses the probe when one is set.
  AskStartEvents(
    tokens: List(PinToken),
    duration_ms: Int,
    max_events: Int,
    slice_limit: Int,
    long_gc_ms: Int,
    long_schedule_ms: Int,
  )

  /// Read a running or finished events probe.
  AskReadEvents(probe_id: Int)

  /// Stop an events probe and return its result.
  AskStopEvents(probe_id: Int)

  /// Attach as one more viewer of the agent already running on the node. The
  /// agent accepts only a viewer that carries the same `build` it runs, so the
  /// code every viewer relies on is never replaced under another. `boot_id`
  /// is the identifier this viewer's pin tokens will carry and `lease_ms` how
  /// long the agent may go without hearing from it. The viewer sends this
  /// instead of pushing and starting an agent when one is registered.
  AskJoin(boot_id: String, lease_ms: Int, build: String)
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
    AskOwnersDetail(max_scanned, top_k) ->
      tagged("owners_detail", [dynamic.int(max_scanned), dynamic.int(top_k)])
    AskEtsTables(top_k) -> tagged("ets_tables", [dynamic.int(top_k)])
    AskBinaries(token, top_k) ->
      tagged("binaries", [token_term(token), dynamic.int(top_k)])
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
    AskStartCalltrace(tokens, patterns, duration_ms, max_events, timeline_limit) ->
      tagged("start_calltrace", [
        dynamic.list(list.map(tokens, token_term)),
        dynamic.list(list.map(patterns, pattern_term)),
        dynamic.int(duration_ms),
        dynamic.int(max_events),
        dynamic.int(timeline_limit),
      ])
    AskReadCalltrace(id) -> tagged("read_calltrace", [dynamic.int(id)])
    AskStopCalltrace(id) -> tagged("stop_calltrace", [dynamic.int(id)])
    AskStartEvents(
      tokens,
      duration_ms,
      max_events,
      slice_limit,
      long_gc_ms,
      long_schedule_ms,
    ) ->
      tagged("start_events", [
        dynamic.list(list.map(tokens, token_term)),
        dynamic.int(duration_ms),
        dynamic.int(max_events),
        dynamic.int(slice_limit),
        dynamic.int(long_gc_ms),
        dynamic.int(long_schedule_ms),
      ])
    AskReadEvents(id) -> tagged("read_events", [dynamic.int(id)])
    AskStopEvents(id) -> tagged("stop_events", [dynamic.int(id)])
    AskJoin(boot_id, lease_ms, build) ->
      tagged("join", [
        dynamic.string(boot_id),
        dynamic.int(lease_ms),
        dynamic.string(build),
      ])
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
