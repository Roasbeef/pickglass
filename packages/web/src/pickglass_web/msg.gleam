//// The closed set of messages a pickglass page handles.
////
//// A `Msg` has three families, and the split is the security boundary of
//// the package.
////
//// - `Fed` carries data from the viewer into the page. No handler in any
////   view builds one, so no browser event can produce it; only the code that
////   owns the Lustre runtime sends it.
//// - `Ui` is a change to view state that the operator controls and that
////   needs nothing from the node: the open tab, which rows are expanded,
////   which box is selected. `update` applies it to the page's own state.
//// - `Ask` names a *request*. `RequestPin(row)` says "the operator asked to
////   pin the process behind this row"; it is not a command and it carries no
////   authority. The viewer's `policy.authorize` decides whether a request
////   becomes a command, using the principal fixed at admission and a pin the
////   viewer issued, never anything in the message.
////
//// A request carries only `Key`s the viewer issued, closed choices from the
//// types below, and text that a total decoder in `wire` already bounded and
//// checked. It never carries a pid, a module name taken from the target, or
//// a function name taken from a profile.
////
//// ## Reading order
////
//// `wire` builds the event attributes and their decoders; `app.update` takes
//// each `Msg` and either changes state, records the request and hands it to
//// the viewer, or refuses it.

import pickglass_core/policy
import pickglass_core/profile/activity
import pickglass_web/key.{type Key}
import pickglass_web/model
import pickglass_web/timeline_model

/// One browser-visible message.
pub type Msg {
  /// New data from the viewer.
  Fed(feed: Feed)

  /// A view-state change the operator made.
  Ui(event: UiEvent)

  /// A request for the viewer to consider.
  Ask(request: Request)
}

/// A piece of data the viewer pushes into a page.
pub type Feed {
  /// The top strip.
  FedStrip(model.StripModel)

  /// The overview page.
  FedOverview(model.OverviewModel)

  /// The owners that moved most, shown on the overview when it arrives.
  FedOwnerMovers(model.OwnerMovers)

  /// The owners page.
  FedOwners(model.OwnersModel)

  /// The processes page.
  FedProcesses(model.ProcessesModel)

  /// The process detail page.
  FedProcessDetail(model.ProcessDetailModel)

  /// The memory page.
  FedMemory(model.MemoryModel)

  /// The supervision page.
  FedSupervision(model.SupervisionModel)

  /// The probes page.
  FedProbes(model.ProbesModel)

  /// The profile page.
  FedProfile(model.ProfileModel)

  /// The timeline page.
  FedTimeline(timeline_model.TimelineModel)

  /// The compare page.
  FedCompare(model.CompareModel)

  /// The audit page.
  FedAudit(model.AuditModel)

  /// The capture files offered on the compare page.
  FedCaptures(model.CapturesModel)

  /// A target the plan form should offer first, by the key of its pin. The
  /// page applies it only when the pin is among the offered targets.
  FedPlanTarget(Key)

  /// The one-click profile in flight: its plan, the probes running and the
  /// profile that just finished. Every page but Probes draws it above its
  /// body, so a profile started from any page is confirmed and found there.
  FedFlow(model.FlowModel)
}

/// The tabs of the profile page.
pub type ProfileTab {
  /// Flame graph, root at the bottom.
  FlameTab

  /// Icicle graph, root at the top.
  IcicleTab

  /// The call graph in layers.
  GraphTab

  /// Flat and cumulative table.
  TopTab

  /// Callers and callees of one function.
  PeekTab

  /// Function source locations.
  SourceTab
}

/// How long a probe may run, as a closed choice.
pub type DurationChoice {
  /// Five seconds.
  Seconds5

  /// Ten seconds.
  Seconds10

  /// Thirty seconds.
  Seconds30

  /// One minute.
  Seconds60

  /// Five minutes.
  Seconds300
}

/// How many samples per second per process a profile takes, as a closed
/// choice. The agent lowers it when many processes share its ceiling, and the
/// plan says what it will run.
pub type RateChoice {
  /// Fifty samples per second.
  Hz50

  /// One hundred samples per second.
  Hz100

  /// Two hundred and fifty samples per second.
  Hz250
}

/// The kind of step a filter adds to the chain.
pub type FilterKind {
  /// Keep only samples with a matching frame.
  FocusFilter

  /// Drop samples with a matching frame.
  IgnoreFilter

  /// Start each stack at the first matching frame.
  ShowFromFilter

  /// Remove matching frames from every stack.
  HideFilter

  /// Keep only matching frames.
  ShowFilter
}

/// A step through the processes window.
pub type PageStep {
  /// Back to the top of the sorted index.
  FirstPage

  /// The window before this one.
  PreviousPage

  /// The window after this one.
  NextPage
}

/// What to export from a profile.
pub type ExportChoice {
  /// Collapsed stacks, one line per stack.
  AsCollapsed

  /// Speedscope JSON.
  AsSpeedscope

  /// Chrome trace events.
  AsChromeTrace
}

/// Which tracing probe's timeline to export.
pub type TraceExport {
  /// The newest scheduling and collection probe.
  EventsTrace

  /// The newest call tree probe that kept call slices.
  CallsTrace
}

/// A change to page-local view state. None of these reaches the node.
pub type UiEvent {
  /// Show another tab of the profile page.
  OpenTab(ProfileTab)

  /// Expand or collapse an owner row.
  ToggleRow(Key)

  /// Select a box in a flame, icicle or diff graph.
  SelectBox(Key)

  /// Select a node in the call graph.
  SelectNode(Key)

  /// Select a reading or span on the timeline.
  SelectReading(Key)

  /// Clear the selection.
  ClearSelection

  /// The probe kind in the plan form.
  DraftKind(policy.ProbeKind)

  /// The duration in the plan form.
  DraftDuration(DurationChoice)

  /// The target process in the plan form, by key.
  DraftTarget(Key)

  /// Send the plan form as a request, if it passes `update`'s checks. The
  /// text is the module field as it stood when the form was submitted; a
  /// stack or events probe ignores it.
  SubmitDraft(modules: String)

  /// Send the module patterns submitted with the form as a request to trace
  /// the calls of a pending profile's processes, if they pass `update`'s
  /// checks. The key names the pending plan.
  SubmitTraceInstead(plan: Key, modules: String)

  /// Send the module patterns submitted with the form as a request to trace
  /// the calls of one process, if they pass `update`'s checks.
  SubmitTraceProcess(process: Key, modules: String)

  /// The kind of the filter being added.
  FilterKindChosen(FilterKind)

  /// Send the filter being added as a request, if its pattern compiles. The
  /// text is the pattern field as it stood when the form was submitted.
  SubmitFilter(pattern: String)

  /// The search text on the profile page.
  Search(String)
}

/// A request for the viewer. Each is one the operator made by pressing a
/// control; the viewer decides whether it is allowed.
pub type Request {
  /// Pin the process behind a row.
  RequestPin(row: Key)

  /// Release a pin.
  RequestUnpin(pin: Key)

  /// Plan a probe from the form's draft.
  PlanProbe(draft: ProbeDraft)

  /// Plan a targeted garbage collection of a pinned process.
  PlanGc(pin: Key)

  /// Ask a pinned process to measure itself.
  RequestSelfMeasure(pin: Key)

  /// Plan a read of the reference-counted binaries one pinned process holds.
  /// The read is costly for a process holding many, so it waits for Confirm
  /// like a probe does.
  PlanBinaries(pin: Key)

  /// Confirm a plan the viewer showed.
  ConfirmPlan(plan: Key)

  /// Cancel a plan the viewer showed.
  CancelPlan(plan: Key)

  /// Stop a running probe.
  StopProbe(probe: Key)

  /// Compare against another checkpoint, or on the compare page use a
  /// capture file as the baseline.
  ChooseBaseline(checkpoint: Key)

  /// Use a capture file the compare page offers as the candidate.
  ChooseCandidate(capture: Key)

  /// Take a checkpoint now. The name is the field as it stood when the form
  /// was submitted. An empty name asks the viewer to number it.
  TakeCheckpoint(name: String)

  /// Detach from the node: the agent unloads itself, every pin and running
  /// probe ends, and the page shows a detached state. It needs the
  /// administer capability, and the viewer checks that again.
  DetachViewer

  /// Write the viewer's live window to a capture file in its save
  /// directory, where the compare page offers it.
  SaveCapture

  /// Sort the processes by another column.
  SortProcesses(column: model.SortColumn)

  /// Move the processes window.
  MovePage(step: PageStep)

  /// Add a step to the transform chain.
  AddFilter(kind: FilterKind, pattern: String)

  /// Add a step to the transform chain on the function behind a selected
  /// box or node. The key is the viewer's; the viewer builds the pattern
  /// from the function it holds, so no function name travels from the
  /// browser.
  AddFilterAt(kind: FilterKind, frame: Key)

  /// Open the probe form with this process as its target. The detail page
  /// sends it from "Plan probe…"; the viewer opens the Probes page and
  /// pre-fills the form's target. It plans nothing.
  PlanProbeFor(process: Key)

  /// Profile the processes of the owner row with this key: pin the busiest of
  /// them, plan one stack probe over the pins and show the plan. It starts
  /// nothing until the plan is confirmed.
  ProfileOwner(owner: Key)

  /// Profile the busiest processes of the last pass, planned the same way.
  ProfileBusiest

  /// Profile one process, pinning it if it is not pinned.
  ProfileProcess(process: Key)

  /// Plan again the same processes for another duration and rate. The key
  /// names the pending plan a profile button made.
  AdjustProfile(plan: Key, duration: DurationChoice, rate: RateChoice)

  /// Plan the processes of a pending profile as a call trace of these
  /// modules instead. The modules are patterns already checked against the
  /// pattern alphabet; the processes are the plan's own.
  TraceCallsInstead(plan: Key, modules: List(String))

  /// Plan the processes of a pending call trace as a stack profile instead.
  SampleStacksInstead(plan: Key)

  /// Trace the calls of these modules in one process, pinning it if it is
  /// not pinned, and show the plan.
  TraceProcess(process: Key, modules: List(String))

  /// Record the scheduling and garbage collection of one process, pinning it
  /// if it is not pinned, and show the plan.
  RecordProcess(process: Key)

  /// Record the scheduling and garbage collection of the busiest processes
  /// of an owner row and show the plan.
  RecordOwner(owner: Key)

  /// Drop every chain step from this index on.
  TruncateChain(from: Int)

  /// Show the profile's running and runnable samples only, or include the
  /// ones taken while a process waited. It is a choice about which samples
  /// the page draws; nothing reaches the node.
  ChooseSamples(inclusion: activity.Inclusion)

  /// Export the profile in a format.
  ExportProfile(choice: ExportChoice)

  /// Export a tracing probe's timeline as a Chrome trace.
  ExportTrace(which: TraceExport)
}

/// A probe the operator drafted. Targets are keys; the viewer turns them into
/// pins it issued.
pub type ProbeDraft {
  ProbeDraft(
    /// The kind of probe.
    kind: policy.ProbeKind,
    /// The processes to probe, by key.
    targets: List(Key),
    /// Module patterns, already checked against the pattern alphabet.
    modules: List(String),
    /// How long to run.
    duration: DurationChoice,
  )
}

/// How many processes a "profile the busiest" button takes, and the most
/// any profile button takes: the agent's limit for one stack probe.
pub const profile_limit = 16

/// The duration in milliseconds.
pub fn duration_ms(choice: DurationChoice) -> Int {
  case choice {
    Seconds5 -> 5000
    Seconds10 -> 10_000
    Seconds30 -> 30_000
    Seconds60 -> 60_000
    Seconds300 -> 300_000
  }
}

/// The sampling rate of a choice, in samples per second per process.
///
/// ## Examples
///
/// ```gleam
/// msg.rate_hz(Hz100)
/// // -> 100
/// ```
pub fn rate_hz(choice: RateChoice) -> Int {
  case choice {
    Hz50 -> 50
    Hz100 -> 100
    Hz250 -> 250
  }
}

/// The choice whose rate is exactly `hz`, when there is one. The plan card
/// uses it to mark the choice in force.
pub fn rate_choice(hz: Int) -> Result(RateChoice, Nil) {
  case hz {
    50 -> Ok(Hz50)
    100 -> Ok(Hz100)
    250 -> Ok(Hz250)
    _ -> Error(Nil)
  }
}

/// The duration choice that is exactly `ms` milliseconds, when there is one.
pub fn duration_choice(ms: Int) -> Result(DurationChoice, Nil) {
  case ms {
    5000 -> Ok(Seconds5)
    10_000 -> Ok(Seconds10)
    30_000 -> Ok(Seconds30)
    60_000 -> Ok(Seconds60)
    300_000 -> Ok(Seconds300)
    _ -> Error(Nil)
  }
}

/// The text of a duration choice, for the select and for its code.
pub fn duration_code(choice: DurationChoice) -> String {
  case choice {
    Seconds5 -> "5s"
    Seconds10 -> "10s"
    Seconds30 -> "30s"
    Seconds60 -> "60s"
    Seconds300 -> "300s"
  }
}

/// Parse a duration code written by `duration_code`.
pub fn parse_duration(code: String) -> Result(DurationChoice, Nil) {
  case code {
    "5s" -> Ok(Seconds5)
    "10s" -> Ok(Seconds10)
    "30s" -> Ok(Seconds30)
    "60s" -> Ok(Seconds60)
    "300s" -> Ok(Seconds300)
    _ -> Error(Nil)
  }
}

/// The durations the plan form offers for a kind of probe, shortest first.
/// They are what the agent runs: a call tree for at most ten seconds, a stack
/// or events probe for at most a minute, a counters probe for any.
///
/// ## Examples
///
/// ```gleam
/// msg.durations_for(policy.CallTree)
/// // -> [Seconds5, Seconds10]
/// ```
pub fn durations_for(kind: policy.ProbeKind) -> List(DurationChoice) {
  case kind {
    policy.CallTree -> [Seconds5, Seconds10]
    policy.Sampling | policy.SchedulingGc -> [Seconds10, Seconds30, Seconds60]
    policy.Counters -> [Seconds10, Seconds30, Seconds60, Seconds300]
  }
}

/// The code of a probe kind, for the select.
pub fn probe_code(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Counters -> "counters"
    policy.Sampling -> "sampling"
    policy.CallTree -> "call_tree"
    policy.SchedulingGc -> "scheduling_gc"
  }
}

/// Parse a probe kind code written by `probe_code`.
pub fn parse_probe(code: String) -> Result(policy.ProbeKind, Nil) {
  case code {
    "counters" -> Ok(policy.Counters)
    "sampling" -> Ok(policy.Sampling)
    "call_tree" -> Ok(policy.CallTree)
    "scheduling_gc" -> Ok(policy.SchedulingGc)
    _ -> Error(Nil)
  }
}

/// The code of a filter kind, for the select.
pub fn filter_code(kind: FilterKind) -> String {
  case kind {
    FocusFilter -> "focus"
    IgnoreFilter -> "ignore"
    ShowFromFilter -> "show_from"
    HideFilter -> "hide"
    ShowFilter -> "show"
  }
}

/// Parse a filter kind code written by `filter_code`.
pub fn parse_filter(code: String) -> Result(FilterKind, Nil) {
  case code {
    "focus" -> Ok(FocusFilter)
    "ignore" -> Ok(IgnoreFilter)
    "show_from" -> Ok(ShowFromFilter)
    "hide" -> Ok(HideFilter)
    "show" -> Ok(ShowFilter)
    _ -> Error(Nil)
  }
}
