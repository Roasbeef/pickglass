//// Who may do what to the target, decided in one pure place.
////
//// Pickglass's viewer holds a credential that grants full control of the
//// target, so the gate that matters sits in the viewer, between the browser
//// and the agent link. This module is that gate. Every viewer-to-agent
//// action is a constructor of the closed `Command` type, so there is no way
//// to ask for an arbitrary call, a term, or a message body. Each command
//// declares the capabilities it needs in `required_capabilities`, an
//// exhaustive `case`: adding a command without deciding its capability
//// fails the build.
////
//// The only way to obtain an `Authorized(Command)` is this module's
//// `authorize` or `confirm`. The type is opaque, so code in any other
//// module cannot construct one, and the link to the agent accepts nothing
//// else. A principal is set once when the browser connects and is never
//// read from an event. A command that names a pinned process also needs a
//// `LivePin` from `identity.check_pin`, so a token from another agent boot
//// is refused here before the agent sees it.
////
//// Probes and targeted collections are never one click. `plan` checks the
//// command and returns a `Plan` carrying the scope, cost estimate,
//// perturbation class, a digest and an expiry. `confirm` produces the
//// `Authorized` only for the same principal, before expiry, when the scope
//// and cost still match the digest. A plan is not a ticket that can be
//// replayed by this module: the caller that stores plans removes one when
//// it is confirmed.
////
//// Every decision, allow or deny, at every stage returns an `AuditEntry`
//// beside its result. There is no path through this module that decides
//// without producing one.
////
//// ## Flow
////
//// - `authorize` admits direct commands such as reads and pins.
//// - `plan` then `confirm` admit probes and targeted GC.
//// - Each returns an `Audited` value: the decision and its audit entry.

import gleam/int
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import pickglass_core/identity.{type LivePin, type PinToken}

// ------------------------------------------------------------ principals

/// The stable identifier of a principal, such as a viewer session.
pub type PrincipalId {
  PrincipalId(text: String)
}

/// A class of action a principal may be granted.
pub type Capability {
  /// Read gauges, census, ownership, memory, supervision, audit; pin and
  /// unpin processes.
  Observe

  /// Ask a process for a summary of itself, such as a size measurement,
  /// which runs code inside that process.
  Summarize

  /// Run a trace or sampling probe on pinned processes.
  Profile

  /// Do something that changes the target's behavior, such as forcing a
  /// garbage collection.
  Perturb

  /// Write captures and derived exports.
  Export

  /// Control the agent itself, such as detaching it.
  Administer
}

/// Every capability, for tests that enumerate grant sets.
pub const all_capabilities: List(Capability) = [
  Observe,
  Summarize,
  Profile,
  Perturb,
  Export,
  Administer,
]

/// The stable code of a capability.
pub fn capability_code(capability: Capability) -> String {
  case capability {
    Observe -> "observe"
    Summarize -> "summarize"
    Profile -> "profile"
    Perturb -> "perturb"
    Export -> "export"
    Administer -> "administer"
  }
}

/// Who is acting and what they were granted. Built once, at admission of
/// the connection, from the viewer's own authentication; never from an
/// event payload.
pub type Principal {
  Principal(id: PrincipalId, grants: Set(Capability))
}

// -------------------------------------------------------------- commands

/// The kind of probe a command starts.
pub type ProbeKind {
  /// Per-function counts, time and allocation on pinned processes.
  Counters

  /// Polled stack samples of pinned processes.
  Sampling

  /// A traced call tree on pinned processes and named modules.
  CallTree

  /// Scheduling and garbage-collection events of pinned processes.
  SchedulingGc
}

/// What a probe will do. Targets are pin tokens; modules are names the
/// agent resolves to modules that are already loaded.
pub type ProbeSpec {
  ProbeSpec(
    kind: ProbeKind,
    targets: List(PinToken),
    modules: List(String),
    duration_ms: Int,
  )
}

/// The formats a capture can be exported in.
pub type ExportFormat {
  CaptureFile
  CollapsedStacks
  Speedscope
  ChromeTrace
  Pprof
}

/// Every action the viewer can take on the target or on its own data.
/// There is no constructor that names a function to call, carries a term,
/// or reads message contents.
pub type Command {
  /// Read the top `k` processes of a census.
  ReadCensus(k: Int)

  /// Read the per-owner aggregate.
  ReadOwners

  /// Read the node's memory categories.
  ReadMemory

  /// Walk the supervision tree.
  ReadSupervision

  /// Read the last `n` agent audit entries.
  ReadAudit(n: Int)

  /// Pin a process, named by the pid text a census row showed.
  PinProcess(pid_text: String)

  /// Release a pin. This needs no live check: a pin whose process died is
  /// still released.
  UnpinProcess(token: PinToken)

  /// Read one pinned process's detail.
  ReadProcess(token: PinToken)

  /// Start a probe. Authorized only through `plan` and `confirm`.
  StartProbe(spec: ProbeSpec)

  /// Stop a running probe by the id the agent issued.
  StopProbe(probe_id: String)

  /// Force a garbage collection of one pinned process. Authorized only
  /// through `plan` and `confirm`.
  TargetedGc(token: PinToken)

  /// Ask a pinned process to measure a term it holds.
  SelfMeasure(token: PinToken)

  /// Write a derived export of a stored capture.
  ExportCapture(capture_id: String, format: ExportFormat)

  /// Record a named checkpoint in the viewer's live capture. It reads
  /// nothing from the target and writes no file: it is a marker in the
  /// viewer's own data, which later readings are compared against.
  Checkpoint(name: String)

  /// Detach the agent: it destroys its sessions and exits.
  Detach
}

/// The capabilities a command needs, all of them. Exhaustive on purpose.
///
/// ## Examples
///
/// ```gleam
/// policy.required_capabilities(TargetedGc(token))
/// // -> [Perturb]
/// ```
pub fn required_capabilities(command: Command) -> List(Capability) {
  case command {
    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | UnpinProcess(_)
    | ReadProcess(_)
    | Checkpoint(_) -> [Observe]

    StartProbe(spec:) -> probe_capabilities(spec.kind)
    StopProbe(_) -> [Profile]
    TargetedGc(_) -> [Perturb]
    SelfMeasure(_) -> [Summarize]
    ExportCapture(..) -> [Export]
    Detach -> [Administer]
  }
}

fn probe_capabilities(kind: ProbeKind) -> List(Capability) {
  case kind {
    Counters | Sampling | CallTree | SchedulingGc -> [Profile]
  }
}

/// Whether a command is a single step or needs a plan first.
pub type Confirmation {
  /// `authorize` admits it directly.
  Direct

  /// It has a cost the operator must see and accept: `plan`, then
  /// `confirm`.
  PlanFirst
}

/// Which commands need a plan.
pub fn confirmation_of(command: Command) -> Confirmation {
  case command {
    StartProbe(_) | TargetedGc(_) | SelfMeasure(_) -> PlanFirst

    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | UnpinProcess(_)
    | ReadProcess(_)
    | StopProbe(_)
    | ExportCapture(..)
    | Checkpoint(_)
    | Detach -> Direct
  }
}

/// How much a command disturbs the target.
pub type Perturbation {
  /// Reads only.
  Passive

  /// Polls target processes.
  Polling

  /// Switches on the VM's per-function call counters (`call_count`,
  /// `call_time`) with a silent trace pattern. No trace message is ever
  /// sent: the cost is the emulator's counting overhead on the matched
  /// functions, and the result is one bounded snapshot.
  Counting

  /// Sets trace flags or patterns that make the VM send a trace message for
  /// each event to a collector.
  Tracing

  /// Forces a garbage collection.
  ForcedGc
}

/// The stable code of a perturbation class.
pub fn perturbation_code(class: Perturbation) -> String {
  case class {
    Passive -> "passive"
    Polling -> "polling"
    Counting -> "counting"
    Tracing -> "tracing"
    ForcedGc -> "forced_gc"
  }
}

/// The perturbation class of a command.
pub fn perturbation_of(command: Command) -> Perturbation {
  case command {
    StartProbe(spec:) -> probe_perturbation(spec.kind)
    TargetedGc(_) -> ForcedGc
    SelfMeasure(_) -> Polling

    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | UnpinProcess(_)
    | ReadProcess(_)
    | StopProbe(_)
    | ExportCapture(..)
    | Checkpoint(_)
    | Detach -> Passive
  }
}

fn probe_perturbation(kind: ProbeKind) -> Perturbation {
  case kind {
    Sampling -> Polling
    Counters -> Counting
    CallTree | SchedulingGc -> Tracing
  }
}

/// The pins a command acts on, each of which must be revalidated before
/// the command is authorized.
pub fn command_pins(command: Command) -> List(PinToken) {
  case command {
    StartProbe(spec:) -> spec.targets
    TargetedGc(token:) | SelfMeasure(token:) | ReadProcess(token:) -> [token]

    // A release must work on a pin whose process has died.
    UnpinProcess(_) -> []

    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | StopProbe(_)
    | ExportCapture(..)
    | Checkpoint(_)
    | Detach -> []
  }
}

/// A short stable name for a command, for audit and logs.
pub fn command_name(command: Command) -> String {
  case command {
    ReadCensus(_) -> "read_census"
    ReadOwners -> "read_owners"
    ReadMemory -> "read_memory"
    ReadSupervision -> "read_supervision"
    ReadAudit(_) -> "read_audit"
    PinProcess(_) -> "pin_process"
    UnpinProcess(_) -> "unpin_process"
    ReadProcess(_) -> "read_process"
    StartProbe(_) -> "start_probe"
    StopProbe(_) -> "stop_probe"
    TargetedGc(_) -> "targeted_gc"
    SelfMeasure(_) -> "self_measure"
    ExportCapture(..) -> "export_capture"
    Checkpoint(_) -> "checkpoint"
    Detach -> "detach"
  }
}

/// The command with its arguments as one line, for audit entries and plan
/// digests.
///
/// ## Examples
///
/// ```gleam
/// policy.describe(ReadCensus(k: 50))
/// // -> "read_census k=50"
/// ```
pub fn describe(command: Command) -> String {
  let arguments = case command {
    ReadCensus(k:) -> ["k=" <> int.to_string(k)]
    ReadAudit(n:) -> ["n=" <> int.to_string(n)]
    PinProcess(pid_text:) -> ["pid=" <> pid_text]
    UnpinProcess(token:)
    | ReadProcess(token:)
    | TargetedGc(token:)
    | SelfMeasure(token:) -> ["pin=" <> identity.pin_to_string(token)]
    StartProbe(spec:) -> describe_spec(spec)
    StopProbe(probe_id:) -> ["probe=" <> probe_id]
    Checkpoint(name:) -> ["name=" <> name]
    ExportCapture(capture_id:, format:) -> [
      "capture=" <> capture_id,
      "format=" <> export_code(format),
    ]
    ReadOwners | ReadMemory | ReadSupervision | Detach -> []
  }

  string.join([command_name(command), ..arguments], " ")
}

fn describe_spec(spec: ProbeSpec) -> List(String) {
  [
    "kind=" <> probe_code(spec.kind),
    "targets="
      <> string.join(list.map(spec.targets, identity.pin_to_string), ","),
    "modules=" <> string.join(spec.modules, ","),
    "duration_ms=" <> int.to_string(spec.duration_ms),
  ]
}

/// The stable code of a probe kind.
pub fn probe_code(kind: ProbeKind) -> String {
  case kind {
    Counters -> "counters"
    Sampling -> "sampling"
    CallTree -> "call_tree"
    SchedulingGc -> "scheduling_gc"
  }
}

/// The stable code of an export format.
pub fn export_code(format: ExportFormat) -> String {
  case format {
    CaptureFile -> "capture"
    CollapsedStacks -> "collapsed"
    Speedscope -> "speedscope"
    ChromeTrace -> "chrome_trace"
    Pprof -> "pprof"
  }
}

// ----------------------------------------------------------- spec checks

/// Why a probe spec was refused.
pub type SpecError {
  /// A probe needs at least one pinned target.
  NoTargets

  /// More targets than the probe kind allows.
  TooManyTargets(limit: Int)

  /// More modules than a probe may name.
  TooManyModules(limit: Int)

  /// A counters or call-tree probe must name the modules to trace.
  NoModules

  /// The duration is not between one millisecond and the maximum.
  BadDuration(max_ms: Int)
}

/// The most modules a probe may name.
pub const max_probe_modules = 16

/// The longest a probe of any kind may run.
pub const max_probe_duration_ms = 300_000

/// The longest a probe of this kind may run. The agent cuts a stack sampling
/// probe to a minute, so a plan for longer would describe a scope the agent
/// does not run; the limit here is what the agent enforces.
///
/// ## Examples
///
/// ```gleam
/// policy.max_duration_ms(Sampling)
/// // -> 60_000
/// ```
pub fn max_duration_ms(kind: ProbeKind) -> Int {
  case kind {
    Sampling -> 60_000
    Counters | CallTree | SchedulingGc -> max_probe_duration_ms
  }
}

fn target_limit(kind: ProbeKind) -> Int {
  case kind {
    Sampling -> 16
    Counters | CallTree | SchedulingGc -> 8
  }
}

fn needs_modules(kind: ProbeKind) -> Bool {
  case kind {
    Counters | CallTree -> True
    Sampling | SchedulingGc -> False
  }
}

/// Check that a probe spec is within the limits the agent will also
/// enforce.
///
/// ## Examples
///
/// ```gleam
/// policy.validate_spec(ProbeSpec(Sampling, [], [], 1000))
/// // -> Error(NoTargets)
/// ```
pub fn validate_spec(spec: ProbeSpec) -> Result(Nil, SpecError) {
  let targets = list.length(spec.targets)
  let limit = target_limit(spec.kind)
  let longest = max_duration_ms(spec.kind)

  case
    targets,
    list.length(spec.modules),
    needs_modules(spec.kind),
    spec.duration_ms
  {
    0, _, _, _ -> Error(NoTargets)
    n, _, _, _ if n > limit -> Error(TooManyTargets(limit:))
    _, m, _, _ if m > max_probe_modules ->
      Error(TooManyModules(limit: max_probe_modules))
    _, 0, True, _ -> Error(NoModules)
    _, _, _, d if d < 1 || d > longest -> Error(BadDuration(max_ms: longest))
    _, _, _, _ -> Ok(Nil)
  }
}

fn spec_error_text(error: SpecError) -> String {
  case error {
    NoTargets -> "no targets"
    TooManyTargets(limit:) -> "more than " <> int.to_string(limit) <> " targets"
    TooManyModules(limit:) -> "more than " <> int.to_string(limit) <> " modules"
    NoModules -> "no modules named"
    BadDuration(max_ms:) ->
      "duration outside 1.." <> int.to_string(max_ms) <> " ms"
  }
}

// ---------------------------------------------------------------- denial

/// Why a command was not admitted.
pub type Denial {
  /// The principal lacks these capabilities.
  MissingCapability(missing: List(Capability))

  /// The command names a pin that was not revalidated against the current
  /// agent incarnation.
  TargetNotRevalidated(token: PinToken)

  /// The command needs `plan` and `confirm`; `authorize` will not admit it.
  PlanRequired

  /// `plan` was asked about a command that does not need a plan.
  NotPlannable

  /// The probe spec is outside its limits.
  InvalidSpec(error: SpecError)

  /// A different principal tried to confirm the plan.
  WrongPrincipal

  /// The plan's expiry has passed.
  PlanExpired

  /// The scope or cost no longer matches what the plan showed.
  PlanChanged
}

/// A one-line reason for a denial, for audit entries.
pub fn denial_text(denial: Denial) -> String {
  case denial {
    MissingCapability(missing:) ->
      "missing capability "
      <> string.join(list.map(missing, capability_code), ",")
    TargetNotRevalidated(token:) ->
      "pin not revalidated " <> identity.pin_to_string(token)
    PlanRequired -> "plan required"
    NotPlannable -> "command does not take a plan"
    InvalidSpec(error:) -> "invalid spec: " <> spec_error_text(error)
    WrongPrincipal -> "plan belongs to another principal"
    PlanExpired -> "plan expired"
    PlanChanged -> "scope or cost changed since the plan"
  }
}

// ----------------------------------------------------------------- audit

/// Which gate made a decision.
pub type Stage {
  AuthorizeStage
  PlanStage
  ConfirmStage
}

/// The stable code of a stage.
pub fn stage_code(stage: Stage) -> String {
  case stage {
    AuthorizeStage -> "authorize"
    PlanStage -> "plan"
    ConfirmStage -> "confirm"
  }
}

/// What a gate decided.
pub type AuditDecision {
  Allowed

  /// Refused; the string is `denial_text` of the reason.
  Denied(reason: String)
}

/// One decision, recorded.
pub type AuditEntry {
  AuditEntry(
    /// When the decision was made, in the caller's clock.
    at_ms: Int,
    stage: Stage,
    principal: String,
    /// `describe` of the command.
    command: String,
    decision: AuditDecision,
  )
}

/// A decision and the audit entry that records it. Every gate returns this
/// shape, so a decision cannot be made without an entry.
pub type Audited(a) {
  Audited(result: Result(a, Denial), entry: AuditEntry)
}

fn audited(
  stage: Stage,
  principal: Principal,
  command: Command,
  now_ms: Int,
  result: Result(a, Denial),
) -> Audited(a) {
  let decision = case result {
    Ok(_) -> Allowed
    Error(denial) -> Denied(reason: denial_text(denial))
  }

  Audited(
    result:,
    entry: AuditEntry(
      at_ms: now_ms,
      stage:,
      principal: principal.id.text,
      command: describe(command),
      decision:,
    ),
  )
}

// ------------------------------------------------------------ authorized

/// A command a principal is allowed to run. Opaque: only `authorize` and
/// `confirm` in this module can build one, so any function that takes an
/// `Authorized(Command)` can rely on a decision having been made.
pub opaque type Authorized(a) {
  Authorized(command: a, by: PrincipalId, at_ms: Int)
}

/// The command an `Authorized` admits.
pub fn authorized_command(authorized: Authorized(a)) -> a {
  authorized.command
}

/// The principal that was admitted.
pub fn authorized_by(authorized: Authorized(a)) -> PrincipalId {
  authorized.by
}

/// When the decision was made.
pub fn authorized_at(authorized: Authorized(a)) -> Int {
  authorized.at_ms
}

// Checks shared by every gate: grants, then pin revalidation, then spec
// limits. Order is fixed so a denial names the first thing wrong.
fn admit(
  principal: Principal,
  command: Command,
  revalidated: List(LivePin),
) -> Result(Nil, Denial) {
  use _ <- result.try(check_grants(principal, command))
  use _ <- result.try(check_pins(command, revalidated))
  check_spec(command)
}

fn check_grants(principal: Principal, command: Command) -> Result(Nil, Denial) {
  let missing =
    list.filter(required_capabilities(command), fn(capability) {
      !set.contains(principal.grants, capability)
    })

  case missing {
    [] -> Ok(Nil)
    _ -> Error(MissingCapability(missing:))
  }
}

fn check_pins(
  command: Command,
  revalidated: List(LivePin),
) -> Result(Nil, Denial) {
  let live = list.map(revalidated, identity.live_token)

  case
    list.find(command_pins(command), fn(token) { !list.contains(live, token) })
  {
    Ok(token) -> Error(TargetNotRevalidated(token:))
    Error(Nil) -> Ok(Nil)
  }
}

fn check_spec(command: Command) -> Result(Nil, Denial) {
  case command {
    StartProbe(spec:) ->
      validate_spec(spec) |> result.map_error(fn(error) { InvalidSpec(error:) })

    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | UnpinProcess(_)
    | ReadProcess(_)
    | StopProbe(_)
    | TargetedGc(_)
    | SelfMeasure(_)
    | ExportCapture(..)
    | Checkpoint(_)
    | Detach -> Ok(Nil)
  }
}

/// Admit a command that needs no plan.
///
/// A command that needs a plan is refused with `PlanRequired`; a command
/// naming pins is refused unless each pin is among `revalidated`.
///
/// ## Examples
///
/// ```gleam
/// let outcome = policy.authorize(principal, ReadOwners, [], now_ms)
/// // outcome.result == Ok(_) when the principal has Observe
/// // outcome.entry records the decision either way
/// ```
pub fn authorize(
  principal: Principal,
  command: Command,
  revalidated: List(LivePin),
  now_ms: Int,
) -> Audited(Authorized(Command)) {
  let result = case confirmation_of(command) {
    PlanFirst -> Error(PlanRequired)
    Direct ->
      admit(principal, command, revalidated)
      |> result.map(fn(_) {
        Authorized(command:, by: principal.id, at_ms: now_ms)
      })
  }

  audited(AuthorizeStage, principal, command, now_ms, result)
}

// ------------------------------------------------------------ plan/confirm

/// How long a plan stays valid.
pub const plan_ttl_ms = 60_000

/// What the operator is shown before confirming: the agent's estimate of
/// the cost of the action.
pub type Estimate {
  Estimate(
    /// The fewest events the action is expected to produce.
    events_low: Int,
    /// The most events expected.
    events_high: Int,
    /// The most bytes the action is expected to hold.
    bytes_high: Int,
    /// How long the action is expected to run.
    wall_ms: Int,
  )
}

/// What a plan will act on.
pub type PlanScope {
  PlanScope(targets: List(PinToken), modules: List(String), duration_ms: Int)
}

/// The text that fixes everything a confirmation binds to. Equal text
/// means equal scope and cost. It is not hashed: comparing the whole text
/// is exact, and it is short.
pub type PlanDigest {
  PlanDigest(canonical: String)
}

/// A planned action awaiting confirmation. Opaque so it can only come from
/// `plan`.
pub opaque type Plan {
  Plan(
    principal: PrincipalId,
    command: Command,
    scope: PlanScope,
    estimate: Estimate,
    class: Perturbation,
    digest: PlanDigest,
    expires_at_ms: Int,
  )
}

fn scope_of(command: Command) -> PlanScope {
  case command {
    StartProbe(spec:) ->
      PlanScope(
        targets: spec.targets,
        modules: spec.modules,
        duration_ms: spec.duration_ms,
      )

    ReadCensus(_)
    | ReadOwners
    | ReadMemory
    | ReadSupervision
    | ReadAudit(_)
    | PinProcess(_)
    | UnpinProcess(_)
    | ReadProcess(_)
    | StopProbe(_)
    | TargetedGc(_)
    | SelfMeasure(_)
    | ExportCapture(..)
    | Checkpoint(_)
    | Detach ->
      PlanScope(targets: command_pins(command), modules: [], duration_ms: 0)
  }
}

fn digest_of(
  principal: PrincipalId,
  command: Command,
  estimate: Estimate,
) -> PlanDigest {
  PlanDigest(canonical: string.join(
    [
      principal.text,
      describe(command),
      perturbation_code(perturbation_of(command)),
      int.to_string(estimate.events_low),
      int.to_string(estimate.events_high),
      int.to_string(estimate.bytes_high),
      int.to_string(estimate.wall_ms),
    ],
    "|",
  ))
}

/// Plan a probe or targeted GC.
///
/// The same capability, revalidation and spec checks as `authorize` run
/// here, so the operator is never shown a plan they could not confirm. A
/// command that does not need a plan is refused with `NotPlannable`.
///
/// ## Examples
///
/// ```gleam
/// let planned = policy.plan(principal, TargetedGc(token), [live], estimate, now_ms)
/// // planned.result == Ok(plan), planned.entry is the audit entry
/// ```
pub fn plan(
  principal: Principal,
  command: Command,
  revalidated: List(LivePin),
  estimate: Estimate,
  now_ms: Int,
) -> Audited(Plan) {
  let result = case confirmation_of(command) {
    Direct -> Error(NotPlannable)
    PlanFirst ->
      admit(principal, command, revalidated)
      |> result.map(fn(_) {
        Plan(
          principal: principal.id,
          command:,
          scope: scope_of(command),
          estimate:,
          class: perturbation_of(command),
          digest: digest_of(principal.id, command, estimate),
          expires_at_ms: now_ms + plan_ttl_ms,
        )
      })
  }

  audited(PlanStage, principal, command, now_ms, result)
}

/// Confirm a plan.
///
/// The confirming principal must be the one that planned. The plan must
/// not have expired. The grants, pins and spec are checked again, because
/// they may have changed since the plan, and `estimate` is the estimate
/// recomputed now: if it no longer produces the plan's digest the scope or
/// cost moved and the operator must plan again.
///
/// ## Examples
///
/// ```gleam
/// let confirmed = policy.confirm(plan, principal, [live], estimate, now_ms)
/// // confirmed.result == Ok(authorized) only if every check passes
/// ```
pub fn confirm(
  plan: Plan,
  principal: Principal,
  revalidated: List(LivePin),
  estimate: Estimate,
  now_ms: Int,
) -> Audited(Authorized(Command)) {
  let result = {
    use _ <- result.try(check_confirmer(plan, principal))
    use _ <- result.try(check_fresh(plan, now_ms))
    use _ <- result.try(admit(principal, plan.command, revalidated))
    use _ <- result.try(check_digest(plan, estimate))

    Ok(Authorized(command: plan.command, by: principal.id, at_ms: now_ms))
  }

  audited(ConfirmStage, principal, plan.command, now_ms, result)
}

fn check_confirmer(plan: Plan, principal: Principal) -> Result(Nil, Denial) {
  case plan.principal == principal.id {
    True -> Ok(Nil)
    False -> Error(WrongPrincipal)
  }
}

fn check_fresh(plan: Plan, now_ms: Int) -> Result(Nil, Denial) {
  case now_ms < plan.expires_at_ms {
    True -> Ok(Nil)
    False -> Error(PlanExpired)
  }
}

fn check_digest(plan: Plan, estimate: Estimate) -> Result(Nil, Denial) {
  case digest_of(plan.principal, plan.command, estimate) == plan.digest {
    True -> Ok(Nil)
    False -> Error(PlanChanged)
  }
}

/// The command a plan would run.
pub fn plan_command(plan: Plan) -> Command {
  plan.command
}

/// The principal that made the plan.
pub fn plan_principal(plan: Plan) -> PrincipalId {
  plan.principal
}

/// What the plan will act on, for the confirmation dialog.
pub fn plan_scope(plan: Plan) -> PlanScope {
  plan.scope
}

/// The cost estimate the operator saw.
pub fn plan_estimate(plan: Plan) -> Estimate {
  plan.estimate
}

/// How much the plan will disturb the target.
pub fn plan_perturbation(plan: Plan) -> Perturbation {
  plan.class
}

/// The digest `confirm` will recompute.
pub fn plan_digest(plan: Plan) -> PlanDigest {
  plan.digest
}

/// When the plan stops being confirmable.
pub fn plan_expires_at(plan: Plan) -> Int {
  plan.expires_at_ms
}
