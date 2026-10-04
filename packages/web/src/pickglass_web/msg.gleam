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
import pickglass_web/key.{type Key}
import pickglass_web/model

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
  FedTimeline(model.TimelineModel)

  /// The compare page.
  FedCompare(model.CompareModel)

  /// The audit page.
  FedAudit(model.AuditModel)
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
  /// Ten seconds.
  Seconds10

  /// Thirty seconds.
  Seconds30

  /// One minute.
  Seconds60

  /// Five minutes.
  Seconds300
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

  /// The module pattern text in the plan form.
  DraftModules(String)

  /// The duration in the plan form.
  DraftDuration(DurationChoice)

  /// The target process in the plan form, by key.
  DraftTarget(Key)

  /// Send the plan form as a request, if it passes `update`'s checks.
  SubmitDraft

  /// The kind of the filter being added.
  FilterKindChosen(FilterKind)

  /// The pattern text of the filter being added.
  FilterPattern(String)

  /// Send the filter being added as a request, if its pattern compiles.
  SubmitFilter

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

  /// Confirm a plan the viewer showed.
  ConfirmPlan(plan: Key)

  /// Cancel a plan the viewer showed.
  CancelPlan(plan: Key)

  /// Stop a running probe.
  StopProbe(probe: Key)

  /// Compare against another checkpoint.
  ChooseBaseline(checkpoint: Key)

  /// Take a checkpoint now.
  TakeCheckpoint

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

  /// Drop every chain step from this index on.
  TruncateChain(from: Int)

  /// Export the profile in a format.
  ExportProfile(choice: ExportChoice)
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

/// The duration in milliseconds.
pub fn duration_ms(choice: DurationChoice) -> Int {
  case choice {
    Seconds10 -> 10_000
    Seconds30 -> 30_000
    Seconds60 -> 60_000
    Seconds300 -> 300_000
  }
}

/// The text of a duration choice, for the select and for its code.
pub fn duration_code(choice: DurationChoice) -> String {
  case choice {
    Seconds10 -> "10s"
    Seconds30 -> "30s"
    Seconds60 -> "60s"
    Seconds300 -> "300s"
  }
}

/// Parse a duration code written by `duration_code`.
pub fn parse_duration(code: String) -> Result(DurationChoice, Nil) {
  case code {
    "10s" -> Ok(Seconds10)
    "30s" -> Ok(Seconds30)
    "60s" -> Ok(Seconds60)
    "300s" -> Ok(Seconds300)
    _ -> Error(Nil)
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
