//// The seam between a page and the viewer: what a page may ask for, what it
//// is given, and how its asks become `policy` commands.
////
//// A page is a Lustre server-component application. The web package builds
//// it as a closed `Msg` type whose browser events decode to *requests*: pin
//// a process, plan a probe, confirm a plan, navigate, edit a filter chain.
//// None of those is an authorized command. This module is where requests
//// become commands, and it is the only place that does:
////
//// - `Request` is the closed set of things a page can ask the viewer to do.
////   There is no constructor that carries a principal, a grant, a plan's
////   digest, or a term for the agent. Targets are pin tokens, which are
////   text a page copied from a pin it was shown.
//// - `intent` turns a request into a policy command and says whether it is
////   direct, needs a plan, or acts on a plan. A malformed token or an
////   invalid name is refused here, before `policy` sees it.
//// - `Page` is what the host hands a page's application when it starts: a
////   bundle of closures bound to one principal at WebSocket admission. A
////   page has no way to name another principal, because none of its
////   closures takes one.
//// - `Mount` starts a page's application and carries Lustre's frames; the
////   host's socket and the application meet only here.
////
//// Everything a page reads comes through `Page`: the newest observations,
//// a subscription to new ones, its pending plans and the pins. A page never
//// starts a collection; the hub does, once per cadence, whoever is watching.
////
//// The web package is not mounted yet. The integration is to give the web
//// application the `Page` as its start argument (`mount_app`), and to
//// translate each of its request messages into a `Request` here.
////
//// ## Flow
////
//// - A page calls the submit closure of its `Page` with a `Request`.
//// - `intent` names the command and what follows it, using `token_of` and
////   `valid_name` to refuse a malformed token or name before the gate.
//// - The service authorizes, executes, and answers with a `Reply`.

import gleam/erlang/process.{type Subject}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pickglass/audit
import pickglass/capture_file
import pickglass/downloads
import pickglass/hub
import pickglass/marks.{type Mark}
import pickglass/observation.{type Observation}
import pickglass/probe_book.{type ProbeRecord}
import pickglass_core/identity
import pickglass_core/policy.{type Command, type PrincipalId}
import pickglass_core/wire

/// The longest checkpoint name accepted, in characters.
pub const max_name_length = 64

/// The id the viewer gives the capture of its own live window, which is what
/// a save or a checkpoint is authorized as exporting.
pub const live_capture = "live"

/// Everything a page may ask the viewer to do.
pub type Request {
  /// Pin a process by the pid text a census row showed.
  PinProcess(pid_text: String)

  /// Release a pin, named by the token text a pin card showed.
  UnpinProcess(token: String)

  /// Ask for a plan for a probe over pinned processes. The viewer offers no
  /// probe over every process, so there is no way to ask for one. `rate_hz`
  /// is samples per second per process for a sampling probe and zero for any
  /// other kind.
  PlanProbe(
    kind: policy.ProbeKind,
    targets: List(String),
    modules: List(String),
    duration_ms: Int,
    rate_hz: Int,
  )

  /// Ask for a plan for a garbage collection of one pinned process.
  PlanTargetedGc(token: String)

  /// Ask for a plan for asking one pinned process to measure itself.
  PlanSelfMeasure(token: String)

  /// Ask for a plan to read the reference-counted binaries one pinned process
  /// holds. The read is costly for a process holding many, so it waits for
  /// Confirm like a probe.
  PlanReadBinaries(token: String)

  /// Read one pinned process in detail.
  ReadProcess(token: String)

  /// Walk the spawn edges of the node.
  ReadSupervision

  /// Confirm a plan this page's principal made, by the id its card showed.
  ConfirmPlan(plan_id: String)

  /// Withdraw a plan.
  CancelPlan(plan_id: String)

  /// Stop a running probe by the id it was started with.
  StopProbe(probe_id: String)

  /// Record a named checkpoint in the live capture.
  Checkpoint(name: String)

  /// Write the live window to a capture file.
  SaveCapture

  /// Offer a file the viewer built from a probe's profile as a one-time
  /// download. It is authorized as an export of that probe in `format`; the
  /// body is the viewer's own data and carries nothing from the browser.
  ExportProfile(
    probe_id: String,
    format: policy.ExportFormat,
    download: downloads.Download,
  )

  /// Read the newest audit entries.
  ReadAudit(count: Int)

  /// Detach from the target.
  Detach
}

/// The longest a one-click stack profile may name, mirrored from the agent's
/// limit for one stack probe so a page never asks for more than it will run.
pub const profile_limit = 16

/// The longest a one-click call trace may name: the agent's limit for one
/// call tree probe.
pub const trace_limit = 4

/// How long a one-click profile samples unless the plan card says otherwise.
pub const profile_duration_ms = 10_000

/// How fast a one-click profile samples unless the plan card says otherwise,
/// in samples per second per process.
pub const profile_rate_hz = 100

/// The longest a one-click recording of scheduling and collections may name:
/// the agent's limit for one events probe.
pub const recording_limit = 8

/// How long a one-click recording runs unless the plan card says otherwise.
pub const recording_duration_ms = 10_000

/// How long a one-click call trace runs unless the plan card says otherwise.
/// A trace sends one message per call, so its window is short.
pub const trace_duration_ms = 5000

/// How a profile button measures the processes it chose.
pub type ProfileMethod {
  /// Poll the stacks of the processes at this many samples per second each.
  ByStacks(rate_hz: Int)

  /// Trace the calls of these modules in the processes. The processes are
  /// chosen first and the modules named by the operator, because the agent
  /// will not trace every function of a node.
  ByCalls(modules: List(String))

  /// Record when the processes run on a scheduler and when they collect
  /// garbage, as slices on a timeline.
  ByEvents
}

/// A one-click profile. Unlike a `Request` it is not one command: pinning the
/// processes that are not pinned and planning the probe over them are several
/// commands, each decided by the gate and audited on its own, and the service
/// composes them so that what it pinned for the profile is released when the
/// profile is done.
pub type ProfileRequest {
  /// Pin the processes (pid texts the viewer read from its own census) and
  /// plan one stack probe over them. `chosen` is the sentence that says how
  /// they were chosen, kept for the plan card. The plan waits for Confirm, as
  /// any plan does.
  PlanProfile(
    pids: List(String),
    chosen: String,
    duration_ms: Int,
    rate_hz: Int,
  )

  /// Pin the processes and plan a call trace of these modules over them. The
  /// same rules as `PlanProfile`, with the call trace's limit of
  /// `trace_limit` processes.
  PlanCallTrace(
    pids: List(String),
    chosen: String,
    duration_ms: Int,
    modules: List(String),
  )

  /// Pin the processes and plan a scheduling and collection recording over
  /// them. The same rules as `PlanProfile`, with the events probe's limit of
  /// `recording_limit` processes.
  PlanRecording(pids: List(String), chosen: String, duration_ms: Int)

  /// Plan the same processes again for another duration and method, replacing
  /// the pending plan a profile button made. A plan can change from stacks to
  /// calls or back, and keeps the pins it holds.
  ReplanProfile(plan_id: String, duration_ms: Int, method: ProfileMethod)
}

/// What the viewer remembers of a pending profile plan, for its card.
pub type ProfileNote {
  ProfileNote(
    plan_id: String,
    /// How the processes were chosen.
    chosen: String,
    duration_ms: Int,
    method: ProfileMethod,
    /// How many processes the plan names.
    processes: Int,
  )
}

/// The reason the service records when the operator detached the viewer, as
/// a phrase that follows "not attached to the node:". The strip leaves the
/// reason out of its own sentence when it is this one, since the operator
/// already knows what they did.
pub const detached_by_operator = "you detached it"

/// What the viewer answers.
pub type Reply {
  /// The request succeeded and has nothing to return.
  Done(message: String)

  /// A pin was issued.
  PinIssued(token: String, pid_text: String)

  /// A plan is waiting for this principal's confirmation. `id` is the
  /// viewer's id for it and `plan` is what `policy.plan` returned.
  PlanReady(id: String, plan: policy.Plan)

  /// A counters probe started.
  ProbeStarted(probe_id: String, matched_functions: Int)

  /// A counters probe stopped, with its last reading.
  ProbeStopped(snapshot: wire.CountersSnapshot)

  /// A stack probe stopped, with what it sampled.
  StacksStopped(snapshot: wire.StacksSnapshot)

  /// A call tree probe stopped, with what it traced.
  CalltraceStopped(snapshot: wire.CalltraceSnapshot)

  /// A scheduling and collection probe stopped, with what it recorded.
  EventsStopped(snapshot: wire.EventsSnapshot)

  /// A targeted collection ran, with the heap before and after.
  Collected(snapshot: wire.CollectionSnapshot)

  /// A process measured itself.
  Measured(snapshot: wire.MeasureSnapshot)

  /// One process in detail.
  ProcessRead(detail: wire.ProcessDetail)

  /// The spawn edges of the node.
  SupervisionRead(snapshot: wire.SupervisionSnapshot)

  /// The binaries one process holds.
  BinariesRead(snapshot: wire.BinariesSnapshot)

  /// The newest audit entries, newest first.
  AuditTail(entries: List(audit.Entry))

  /// A capture was written.
  CaptureSaved(path: String)

  /// A download is waiting at this ticket, to be fetched once.
  DownloadReady(ticket: String)

  /// The request was refused. The text is the gate's reason, a validation
  /// message, or what the agent said.
  Rejected(reason: String)
}

/// What a targeted collection or a self-measure left behind, kept so the
/// process's page can show it after the request returned.
pub type ProcessResult {
  /// A garbage collection ran and read the heap before and after.
  GcRan(snapshot: wire.CollectionSnapshot, at_ms: Int)

  /// A process measured itself.
  SelfMeasured(snapshot: wire.MeasureSnapshot, at_ms: Int)

  /// A process's binaries were read.
  BinariesRan(snapshot: wire.BinariesSnapshot, at_ms: Int)

  /// A read of a process's binaries was confirmed and the agent refused or
  /// failed it, for example a process that holds too many. `token` names the
  /// pin it was made over and `reason` is the agent's, in its words.
  BinariesRefused(token: String, reason: String, at_ms: Int)
}

/// Whether a pin can still be used.
pub type PinStatus {
  PinLive
  PinGone(reason: String)
}

/// A pin as a page shows it.
pub type PinCard {
  PinCard(token: String, pid_text: String, status: PinStatus, pinned_at_ms: Int)
}

/// Where the observations come from.
pub type Mode {
  /// A live target.
  Live(
    node: String,
    incarnation: identity.NodeIncarnation,
    os: identity.OsProcess,
  )

  /// A capture file, with no target. `source` is its file name.
  Viewing(
    source: String,
    incarnation: identity.NodeIncarnation,
    os: identity.OsProcess,
  )
}

/// What the host hands a page's application at start. Every closure is
/// bound to the principal fixed at WebSocket admission.
pub type Page {
  Page(
    /// The principal's id, for display.
    principal: PrincipalId,
    /// The grants, for deciding which controls to draw. Drawing a control is
    /// cosmetic: the gate checks the grant again on every request.
    grants: List(policy.Capability),
    mode: Mode,
    /// The ring's observations, newest first.
    latest: fn() -> List(Observation),
    /// Subscribe a subject to new observations. `Error` when the principal
    /// may not observe.
    subscribe: fn(Subject(hub.Update)) -> Result(Nil, String),
    /// Ask the viewer to do something, as this principal.
    submit: fn(Request) -> Reply,
    /// Ask the viewer for a one-click profile, as this principal. The answer
    /// is `PlanReady` or `Rejected`.
    profile: fn(ProfileRequest) -> Reply,
    /// The pending profile plans of this principal, with how each was chosen.
    profile_notes: fn() -> List(ProfileNote),
    /// The plans this principal has pending, as `(id, plan)`.
    plans: fn() -> List(#(String, policy.Plan)),
    /// The checkpoints recorded in the live capture with the observations
    /// they are compared against, oldest first.
    checkpoints: fn() -> List(Mark),
    /// The probes, newest first.
    probes: fn() -> List(ProbeRecord),
    /// What targeted collections and self-measures returned, newest first.
    results: fn() -> List(ProcessResult),
    /// The names of the capture files that can be compared, newest first.
    /// Empty when the principal may not observe.
    captures: fn() -> List(String),
    /// Read one of those files. `Error` says why it could not be read.
    read_capture: fn(String) -> Result(capture_file.Loaded, String),
    /// The newest audit entries, newest first.
    audit: fn(Int) -> List(audit.Entry),
    /// The pins, oldest first.
    pins: fn() -> List(PinCard),
    /// Why the target is gone, once it has been attached and is not: the
    /// operator detached, or the node went away. `None` while it answers and
    /// for a capture file, which never had one.
    lost: fn() -> Option(String),
  )
}

// ------------------------------------------------------------------ intent

/// What a request needs from the gate.
pub type Intent {
  /// Authorize the command, run it, then do the follow-up if the command is
  /// one the viewer answers itself.
  Run(command: Command, follow: Follow)

  /// Plan the command and hold the plan for confirmation.
  Plan(command: Command)

  /// Confirm a plan by id.
  Confirm(plan_id: String)

  /// Withdraw a plan by id.
  Cancel(plan_id: String)
}

/// What the viewer does itself after a command that never reaches the agent.
pub type Follow {
  NoFollow
  AddCheckpoint(name: String)
  StoreDownload(download: downloads.Download)
  WriteCapture
  TailAudit(count: Int)
}

/// The most audit entries a page may ask for at once.
pub const max_audit_count = 200

/// Turn a request into an intent, or refuse it with a reason. Nothing here
/// authorizes anything: the result is what the gate will be asked.
///
/// ## Examples
///
/// ```gleam
/// seam.intent(PinProcess("<0.12.0>"))
/// // -> Ok(Run(policy.PinProcess("<0.12.0>"), NoFollow))
///
/// seam.intent(PlanTargetedGc("not a token"))
/// // -> Error("malformed pin token")
/// ```
pub fn intent(request: Request) -> Result(Intent, String) {
  case request {
    PinProcess(pid_text) -> Ok(Run(policy.PinProcess(pid_text), NoFollow))
    UnpinProcess(token) ->
      token_of(token)
      |> result.map(fn(token) { Run(policy.UnpinProcess(token), NoFollow) })
    PlanProbe(kind, targets, modules, duration_ms, rate_hz) -> {
      use tokens <- result.try(result.all(list.map(targets, token_of)))

      Ok(
        Plan(
          policy.StartProbe(policy.ProbeSpec(
            kind:,
            targets: tokens,
            modules:,
            duration_ms:,
            rate_hz:,
          )),
        ),
      )
    }
    PlanTargetedGc(token) ->
      token_of(token)
      |> result.map(fn(token) { Plan(policy.TargetedGc(token)) })
    PlanSelfMeasure(token) ->
      token_of(token)
      |> result.map(fn(token) { Plan(policy.SelfMeasure(token)) })
    PlanReadBinaries(token) ->
      token_of(token)
      |> result.map(fn(token) { Plan(policy.ReadBinaries(token)) })
    ReadProcess(token) ->
      token_of(token)
      |> result.map(fn(token) { Run(policy.ReadProcess(token), NoFollow) })
    ReadSupervision -> Ok(Run(policy.ReadSupervision, NoFollow))
    ConfirmPlan(id) -> Ok(Confirm(id))
    CancelPlan(id) -> Ok(Cancel(id))
    StopProbe(id) -> Ok(Run(policy.StopProbe(id), NoFollow))
    Checkpoint(name) -> {
      use name <- result.try(valid_name(name))

      Ok(Run(policy.Checkpoint(name), AddCheckpoint(name)))
    }
    SaveCapture ->
      Ok(Run(
        policy.ExportCapture(live_capture, policy.CaptureFile),
        WriteCapture,
      ))
    ExportProfile(probe_id, format, download) ->
      Ok(Run(
        policy.ExportCapture("probe-" <> probe_id, format),
        StoreDownload(download),
      ))
    ReadAudit(count) ->
      case count >= 1 && count <= max_audit_count {
        True -> Ok(Run(policy.ReadAudit(count), TailAudit(count)))
        False -> Error("an audit read is between 1 and 200 entries")
      }
    Detach -> Ok(Run(policy.Detach, NoFollow))
  }
}

fn token_of(text: String) -> Result(identity.PinToken, String) {
  identity.parse_pin(text) |> result.replace_error("malformed pin token")
}

fn valid_name(name: String) -> Result(String, String) {
  let trimmed = string.trim(name)
  let printable =
    string.to_utf_codepoints(trimmed)
    |> list.all(fn(point) { string.utf_codepoint_to_int(point) >= 32 })

  case
    string.length(trimmed) >= 1 && string.length(trimmed) <= max_name_length,
    printable
  {
    True, True -> Ok(trimmed)
    _, _ -> Error("a checkpoint name is 1 to 64 printable characters")
  }
}

// ------------------------------------------------------------------- mount

/// A started page application and the two things the socket does with it.
pub type Running {
  Running(
    /// Hand it one text frame from the browser.
    forward: fn(String) -> Nil,
    /// Stop it. The socket calls this when the browser goes away.
    shutdown: fn() -> Nil,
  )
}

/// Start the application for one page of the viewer: the `Page` the
/// principal was admitted with, the page's route slug (`overview`, `owners`,
/// ...), and where to send each frame for the browser, already encoded.
/// `Error` when the application did not start.
pub type Mount =
  fn(Page, String, fn(Json) -> Nil) -> Result(Running, String)
