//// The page models: what the viewer feeds the pages.
////
//// Pickglass draws every page from a plain record that the viewer builds
//// from core types. A model holds no process, no socket and no function:
//// it is data, so a page is a pure function of it and a test can build one
//// by hand. The viewer owns where the numbers come from (a census, a probe,
//// a capture file) and hands them over already measured, with the
//// `PanelInfo` that says how.
////
//// Three rules shape these types. A reading is a `Measurement`, never an
//// `Int`, so an absent value stays a word all the way to the glass. A column
//// that overlaps another carries its `Additivity` so the page can refuse to
//// total it. And anything the browser can act on carries a `Key` the viewer
//// issued, never a pid or a name.
////
//// View state that the operator controls (the open tab, the sort, the
//// selected box, which owner rows are expanded) is not here. It lives in
//// `pickglass_web/state` so a new census does not reset it.
////
//// ## Reading order
////
//// The shared pieces come first (`PanelInfo`, `Panel`, the strip), then one
//// model per page in navigation order: overview, owners, processes, process
//// detail, memory, supervision, probes, profile, timeline, compare, audit.

import gleam/option.{type Option}
import pickglass_core/analysis/graph
import pickglass_core/analysis/peek
import pickglass_core/analysis/top
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity.{type NodeIncarnation, type OsProcess}
import pickglass_core/layout/dag
import pickglass_core/layout/flame
import pickglass_core/measure.{
  type Additivity, type Cadence, type Coverage, type Measurement,
  type SeriesKind,
}
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/provenance
import pickglass_core/unit.{type Unit}
import pickglass_web/key.{type Key}

// ------------------------------------------------------------ shared

/// The line every data panel shows in its title bar: where the data came
/// from, how it was collected, how often, how much of it there is and
/// whether anything was cut.
pub type PanelInfo {
  PanelInfo(
    /// What was read, for example `census` or `VM gauges`.
    source: String,
    /// How it was read, for example `process_info bundle v1`.
    method: String,
    /// The interval that was asked for.
    cadence: Cadence,
    /// The interval that was achieved, in milliseconds, when known.
    achieved_ms: Option(Int),
    /// How much of the requested scope the collection covered, and why it
    /// stopped. Truncation is read from its outcome.
    coverage: Coverage,
  )
}

/// A body of data under its title-bar information.
pub type Panel(a) {
  Panel(
    /// The title-bar line for this panel.
    info: PanelInfo,
    /// The panel's data.
    body: a,
  )
}

/// A checkpoint the operator can compare against.
pub type CheckpointRef {
  CheckpointRef(
    /// The key the viewer issued for this checkpoint.
    key: Key,
    /// The checkpoint as recorded in a capture.
    checkpoint: capture.Checkpoint,
  )
}

/// Whether a figure was read directly or computed from two readings.
pub type Derivation {
  /// A reading taken from the node.
  Measured

  /// The difference of two non-atomic readings, with a note on what it
  /// stands for.
  Derived(note: String)
}

/// A small series for a sparkline. A point may be missing; the line then
/// breaks instead of dropping to zero.
pub type Sparkline {
  Sparkline(
    /// What the series is.
    label: String,
    /// The unit of its points.
    unit: Unit,
    /// One reading per sampling interval, oldest first.
    points: List(Measurement),
    /// A single summary reading, such as the latest or the mean.
    summary: Measurement,
    /// A short caveat, such as `work, not CPU`.
    note: String,
  )
}

// ------------------------------------------------------------ strip

/// Whether the page shows the live node or a saved capture.
pub type DataSource {
  /// Attached to a running node.
  Live

  /// Reading a capture file, by its name.
  Viewing(capture: String)
}

/// What the viewer is allowed to do on this attachment.
pub type Role {
  /// Read-only diagnostics.
  Diagnostic

  /// Attached with full control of the target.
  AttachedFullTrust
}

/// The capability banner shown on every page.
pub type CapabilityBanner {
  CapabilityBanner(
    /// The role of this attachment.
    role: Role,
    /// The capabilities the page's principal holds.
    grants: List(policy.Capability),
    /// The data-source line, for example the census generation and age.
    source_line: String,
  )
}

/// The cost pickglass itself imposes on the target, as a duty cycle.
pub type ObserverEffect {
  ObserverEffect(
    /// Parts per ten thousand of one scheduler spent collecting.
    duty: Measurement,
    /// A short statement of what is included.
    note: String,
  )
}

/// A probe that is running now.
pub type ActiveProbe {
  ActiveProbe(
    /// The key of the probe, for stopping it.
    key: Key,
    /// What kind of probe.
    kind: policy.ProbeKind,
    /// Time left before its deadline, when known.
    remaining_ms: Measurement,
  )
}

/// The top strip: the node, how long it has been seen, what we may do and
/// what the observation costs.
pub type StripModel {
  StripModel(
    /// The node's name.
    node: String,
    /// The node's digest, creation and agent boot id.
    incarnation: NodeIncarnation,
    /// The OS process the node runs as.
    os: OsProcess,
    /// How long the node has been up, when known.
    uptime_ms: Measurement,
    /// Live or a capture.
    source: DataSource,
    /// The capability banner.
    banner: CapabilityBanner,
    /// The observer-effect meter.
    observer: ObserverEffect,
    /// Probes running now.
    probes: List(ActiveProbe),
  )
}

// ------------------------------------------------------------ overview

/// One row of the memory-layers stack.
pub type LayerRow {
  LayerRow(
    /// The layer's name.
    label: String,
    /// How deeply it nests under the row above, for indentation.
    depth: Int,
    /// Its current value.
    value: Measurement,
    /// Its change since the chosen checkpoint, when there is one.
    delta: Measurement,
    /// Whether it was read or derived.
    derivation: Derivation,
  )
}

/// A labelled count with an optional limit, such as atoms used of the table
/// size.
pub type CountTile {
  CountTile(
    /// What is counted.
    label: String,
    /// The count.
    value: Measurement,
    /// The limit, when there is one.
    limit: Measurement,
  )
}

/// An OS process in a role.
pub type OsRole {
  OsRole(
    /// The role, such as `daemon` or `helper`.
    role: String,
    /// Its OS pid and start identity.
    os: OsProcess,
    /// Resident set size.
    rss: Measurement,
    /// The anonymous part of the resident set, when the OS reports it.
    anon: Measurement,
    /// A short note, for example what the process is.
    note: String,
  )
}

/// The overview page.
pub type OverviewModel {
  OverviewModel(
    /// The memory layers and their gaps.
    layers: Panel(List(LayerRow)),
    /// The checkpoint the deltas are against.
    checkpoint: Option(CheckpointRef),
    /// Checkpoints the operator may pick instead.
    checkpoints: List(CheckpointRef),
    /// Scheduler utilisation, run queues and reductions.
    schedulers: Panel(List(Sparkline)),
    /// Counts of processes, ports, tables and atoms.
    counts: List(CountTile),
    /// OS processes by role.
    roles: Panel(List(OsRole)),
  )
}

// ------------------------------------------------------------ processes

/// One process as the census read it.
pub type ProcRow {
  ProcRow(
    /// The key the viewer issued for the process.
    key: Key,
    /// The process id as text, for display only.
    pid_text: String,
    /// The owner label the join produced.
    owner_label: String,
    /// The strongest claim behind that label, when there is one.
    attribution: owner.Attribution,
    /// Memory of the process (`process_info(memory)`).
    memory: Measurement,
    /// Heap capacity.
    heap_cap: Measurement,
    /// Messages waiting.
    mailbox: Measurement,
    /// Reductions per second, a work counter.
    reductions: Measurement,
    /// References to reference-counted binaries; overlaps other processes.
    binary_refs: Measurement,
    /// The function the process is in, when known.
    current: Option(String),
  )
}

/// Which column the processes are sorted by.
pub type SortColumn {
  /// By memory.
  ByMemory

  /// By mailbox length.
  ByMailbox

  /// By reductions per second.
  ByReductions
}

/// A window over the sorted index.
pub type Window {
  Window(
    /// The index of the first row shown.
    offset: Int,
    /// The number of rows the window holds.
    size: Int,
    /// The number of rows in the whole sorted index.
    total: Int,
  )
}

/// The processes page.
pub type ProcessesModel {
  ProcessesModel(
    /// Census information.
    info: PanelInfo,
    /// The sort in force.
    sort: SortColumn,
    /// The window of the sorted index.
    window: Window,
    /// The rows inside the window.
    rows: List(ProcRow),
  )
}

// ------------------------------------------------------------ owners

/// Whether a row is a group of processes, a role within one, or the
/// unclaimed remainder.
pub type OwnerKind {
  /// An owner path.
  OwnerGroup

  /// A role inside an owner.
  RoleGroup

  /// Processes nobody claimed. Always present.
  UnknownGroup
}

/// One row of the owner tree.
pub type OwnerRow {
  OwnerRow(
    /// The key for expanding the row and for opening a group.
    key: Key,
    /// Group, role or unknown.
    kind: OwnerKind,
    /// The owner path rendered, or the role name.
    label: String,
    /// Nesting depth, zero for a top-level owner.
    depth: Int,
    /// The strongest source behind the row, when the row is attributed.
    source: Option(owner.Source),
    /// Disagreeing weaker claims.
    dissent: Int,
    /// The number of processes.
    procs: Measurement,
    /// Total heap capacity. When `unread` is above zero it is a lower bound.
    heap_cap: Measurement,
    /// How many members had no heap-capacity reading, so the total above
    /// leaves them out.
    unread: Int,
    /// Change of heap capacity since the checkpoint.
    delta: Measurement,
    /// Total mailbox length.
    mailbox: Measurement,
    /// Reductions per second.
    reductions: Measurement,
    /// Binary references. Overlaps between processes, so a group has no
    /// total for it.
    binary_refs: Measurement,
    /// The processes of the group, shown when it is expanded.
    members: List(ProcRow),
  )
}

/// The owners page.
pub type OwnersModel {
  OwnersModel(
    /// Census information.
    info: PanelInfo,
    /// The groups, then roles beneath each, in display order.
    rows: List(OwnerRow),
    /// The unknown group, always present even when empty.
    unknown: OwnerRow,
    /// Checkpoints to compare against.
    checkpoints: List(CheckpointRef),
    /// The checkpoint in force.
    baseline: Option(CheckpointRef),
    /// How many processes carried a label and how many did not.
    labelled: #(Int, Int),
  )
}

// ------------------------------------------------------------ detail

/// Whether the process is alive.
pub type Liveness {
  /// Alive at the last read.
  Alive

  /// Exited; the text says when.
  Exited(at: String)
}

/// Whether the process is pinned, with the key for the pin when it is.
pub type PinState {
  /// Not pinned.
  NotPinned

  /// Pinned; the key names the pin for unpinning and commands.
  Pinned(pin: Key)
}

/// A process this one replaced under the same owner and role.
pub type Successor {
  Successor(
    /// The earlier process's birth, as text.
    predecessor: String,
    /// When it exited.
    exited: String,
  )
}

/// An edge that is evidence about a process but not ownership.
pub type Evidence {
  Evidence(
    /// The kind: link, monitor, supervisor, table owned.
    kind: String,
    /// What it points at.
    target: String,
    /// Where the edge was read from.
    source: owner.Source,
  )
}

/// One named counter on the detail page.
pub type Counter {
  Counter(
    /// The counter's name.
    label: String,
    /// Its unit.
    unit: Unit,
    /// Its reading.
    value: Measurement,
  )
}

/// The process detail page.
pub type ProcessDetailModel {
  ProcessDetailModel(
    /// Census information for the counters.
    info: PanelInfo,
    /// The key of the process row.
    key: Key,
    /// The pid as text.
    pid_text: String,
    /// The birth of this process as text.
    birth: String,
    /// Alive or exited.
    liveness: Liveness,
    /// Pinned or not.
    pin: PinState,
    /// The owner attribution with dissent.
    attribution: owner.Attribution,
    /// The process this one succeeded, when there is one.
    successor: Option(Successor),
    /// Memory and queue counters.
    counters: List(Counter),
    /// Collection counters.
    gc: List(Counter),
    /// Short histories.
    history: List(Sparkline),
    /// Links, monitors and the supervisor, as evidence only.
    evidence: List(Evidence),
    /// Whether the host answers a self-measure request.
    self_measure: SelfMeasure,
  )
}

/// Whether the target can answer a self-measure request.
pub type SelfMeasure {
  /// The process advertised that it answers.
  Available

  /// The process did not advertise it.
  Unavailable
}

// ------------------------------------------------------------ memory

/// One category of memory.
pub type CategoryRow {
  CategoryRow(
    /// The category's name.
    label: String,
    /// Its unit.
    unit: Unit,
    /// Its reading.
    value: Measurement,
    /// Whether it may be added to the others or overlaps them.
    additivity: Additivity,
    /// What the category is.
    note: String,
  )
}

/// The memory page.
pub type MemoryModel {
  MemoryModel(
    /// The erlang:memory categories.
    categories: Panel(List(CategoryRow)),
    /// Allocator carriers and utilisation.
    allocators: Panel(List(CategoryRow)),
    /// ETS, binaries and similar.
    tables: Panel(List(CategoryRow)),
  )
}

// ------------------------------------------------------------ supervision

/// What a node in the supervision tree is.
pub type SupKind {
  /// A supervisor.
  Supervisor

  /// A worker.
  Worker

  /// A process whose parent could be read but not its kind.
  UnknownKind
}

/// One node of the supervision tree.
pub type SupNode {
  SupNode(
    /// The key for opening the process.
    key: Key,
    /// The process's name or initial call.
    label: String,
    /// Its kind.
    kind: SupKind,
    /// The owner label, when attributed.
    owner_label: Option(String),
    /// Its children.
    children: List(SupNode),
  )
}

/// The supervision page.
pub type SupervisionModel {
  SupervisionModel(
    /// Where the tree came from.
    info: PanelInfo,
    /// The roots, as read from parent links.
    roots: List(SupNode),
    /// What the tree cannot show, for example the application-master gap.
    caveat: String,
    /// Nodes beyond the drawing bound.
    omitted: Int,
  )
}

// ------------------------------------------------------------ probes

/// A plan waiting for confirmation.
pub type PlanCard {
  PlanCard(
    /// The key to confirm or cancel this plan.
    key: Key,
    /// The probe kind.
    kind: policy.ProbeKind,
    /// The core plan, with its scope, estimate and perturbation.
    plan: policy.Plan,
    /// How many functions the agent's own validation matched.
    matched: Measurement,
    /// What the target said about the targets, as text for the dialog.
    target_labels: List(String),
  )
}

/// A probe that finished or stopped.
pub type ProbeHistoryRow {
  ProbeHistoryRow(
    /// The key of the probe.
    key: Key,
    /// What kind it was.
    kind: policy.ProbeKind,
    /// How it ended.
    outcome: measure.Outcome,
    /// What it cost the target.
    cost: capture.ProbeCost,
  )
}

/// The probes page.
pub type ProbesModel {
  ProbesModel(
    /// Where the lists came from.
    info: PanelInfo,
    /// Processes the operator may target, by pin.
    targets: List(#(Key, String)),
    /// A plan waiting for the operator to confirm.
    pending: Option(PlanCard),
    /// Probes running.
    active: List(ActiveProbe),
    /// Probes that ended.
    history: List(ProbeHistoryRow),
    /// The principal's capabilities, to say what may be planned.
    grants: List(policy.Capability),
  )
}

// ------------------------------------------------------------ profile

/// The line above a profile: which probe, what source and what to be
/// careful about.
pub type ProfileHeader {
  ProfileHeader(
    /// The probe or capture name.
    title: String,
    /// The profile's source kind.
    source: profile.Source,
    /// Sampling and coverage line.
    info: PanelInfo,
    /// Caveats that apply to every view of this profile.
    caveats: List(String),
  )
}

/// The profile page, with every view's layout already computed.
pub type ProfileModel {
  ProfileModel(
    /// The header.
    header: ProfileHeader,
    /// The profile after the chain, for function names.
    profile: profile.Profile,
    /// The value column everything is drawn from.
    column: profile.Column,
    /// The transform chain, one report per step.
    chain: List(transform.StepReport),
    /// The profile's total before any step.
    total_before: Int,
    /// The views that need call stacks, or the reason there are none.
    stacks: Stacks,
    /// The Top table.
    top: top.Table,
  )
}

/// The views of a profile that exist only for a source with call stacks.
/// Counters and allocation counts have none, and core refuses to lay them
/// out; the page then says so instead of drawing an empty picture.
pub type Stacks {
  /// The source has call stacks.
  HasStacks(
    /// The flame layout; the icicle is the same boxes upside down.
    layout: flame.Layout,
    /// The call graph behind the Graph and Peek tabs.
    graph: graph.Graph,
    /// The graph drawn in layers.
    dag: dag.Layout,
    /// Peek for each function in the graph.
    peeks: List(peek.Peek),
  )

  /// The source has no call stacks, so flame, icicle, graph and peek are not
  /// offered.
  NoStacks(source: profile.Source)
}

// ------------------------------------------------------------ timeline

/// A stretch where evidence was lost.
pub type CoverageGap {
  CoverageGap(
    /// Start, in milliseconds from the window start.
    from_ms: Int,
    /// End, in milliseconds from the window start.
    to_ms: Int,
    /// Events dropped inside the gap, when known.
    dropped: Measurement,
    /// Why it was lost.
    reason: String,
  )
}

/// A reading with the width of time it stands for.
pub type Step {
  Step(
    /// When the reading was taken, in milliseconds from the window start.
    at_ms: Int,
    /// How long it stands for: the sampling interval.
    width_ms: Int,
    /// The reading.
    value: Measurement,
  )
}

/// A span of an operation.
pub type Span {
  Span(
    /// Start, in milliseconds from the window start.
    at_ms: Int,
    /// Length in milliseconds.
    length_ms: Int,
    /// The operation name.
    label: String,
  )
}

/// A row of the timeline.
pub type Track {
  /// A polled counter, drawn as steps and never interpolated.
  CounterTrack(label: String, unit: Unit, steps: List(Step))

  /// Operation spans reported by the host.
  SpanTrack(label: String, spans: List(Span))
}

/// The timeline page.
pub type TimelineModel {
  TimelineModel(
    /// Where the timeline came from.
    info: PanelInfo,
    /// The window length in milliseconds.
    window_ms: Int,
    /// The clock the tracks share and its error.
    clock_note: String,
    /// The tracks.
    tracks: List(Track),
    /// Where evidence was dropped.
    gaps: List(CoverageGap),
  )
}

// ------------------------------------------------------------ compare

/// One compared figure.
pub type CompareRow {
  CompareRow(
    /// What is compared.
    label: String,
    /// Gauge, counter or per-interval change; decides which verdict applies.
    kind: SeriesKind,
    /// The unit.
    unit: Unit,
    /// The baseline reading.
    baseline: Measurement,
    /// The candidate reading.
    candidate: Measurement,
  )
}

/// The compare page.
pub type CompareModel {
  CompareModel(
    /// The baseline capture's name.
    baseline_name: String,
    /// The candidate capture's name.
    candidate_name: String,
    /// The baseline provenance.
    baseline: provenance.Provenance,
    /// The candidate provenance.
    candidate: provenance.Provenance,
    /// The compared figures.
    rows: List(CompareRow),
    /// The differential flame, when both captures carry stacks.
    diff: Option(DiffFlame),
  )
}

/// A differential flame and what it needs to name its boxes.
pub type DiffFlame {
  DiffFlame(
    /// The merged profile, for names.
    profile: profile.Profile,
    /// The differential layout.
    layout: flame.Layout,
  )
}

// ------------------------------------------------------------ audit

/// The audit page.
pub type AuditModel {
  AuditModel(
    /// Where the log came from.
    info: PanelInfo,
    /// Entries, newest first.
    entries: List(policy.AuditEntry),
  )
}
