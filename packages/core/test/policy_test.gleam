import gleam/list
import gleam/set
import pg_data_gen as gen
import pickglass_core/identity.{type LivePin, type PinToken}
import pickglass_core/policy.{
  type Command, type Principal, Administer, Allowed, Audited, Denied, Export,
  Observe, Perturb, PlanFirst, Principal, PrincipalId, Profile, Summarize,
}

// A policy decision is tested against the gate's documented behavior,
// never by constructing an `Authorized`: the type is opaque, so a test (or
// any other module) that wrote `Authorized(command:, by:, at_ms:)` would
// not compile. That is the forgery guarantee, and it is enforced by the
// compiler rather than by a test.

fn boot(text: String) -> identity.BootId {
  let assert Ok(id) = identity.boot_id(text) as "valid boot id"
  id
}

fn token(serial: Int) -> PinToken {
  let assert Ok(token) = identity.pin(boot("aaaa"), serial) as "valid pin"
  token
}

fn live(serial: Int) -> LivePin {
  let assert Ok(live) = identity.check_pin(token(serial), boot("aaaa"))
    as "same boot"
  live
}

fn principal(name: String, grants: List(policy.Capability)) -> Principal {
  Principal(id: PrincipalId(name), grants: set.from_list(grants))
}

fn owner_principal() -> Principal {
  principal("owner", policy.all_capabilities)
}

fn spec(kind: policy.ProbeKind) -> policy.ProbeSpec {
  policy.ProbeSpec(
    kind:,
    targets: [token(1)],
    modules: ["loom_session"],
    duration_ms: 1000,
    rate_hz: 50,
  )
}

fn estimate() -> policy.Estimate {
  policy.Estimate(
    events_low: 10,
    events_high: 1000,
    bytes_high: 4096,
    wall_ms: 1000,
  )
}

/// One command per constructor, with every probe kind.
fn all_commands() -> List(Command) {
  [
    policy.ReadCensus(50),
    policy.ReadOwners,
    policy.ReadMemory,
    policy.ReadSupervision,
    policy.ReadEtsTables,
    policy.ReadBinaries(token(1)),
    policy.ReadAudit(10),
    policy.PinProcess("<0.1.0>"),
    policy.UnpinProcess(token(1)),
    policy.ReadProcess(token(1)),
    policy.StartProbe(spec(policy.Counters)),
    policy.StartProbe(spec(policy.Sampling)),
    policy.StartProbe(spec(policy.CallTree)),
    policy.StartProbe(spec(policy.SchedulingGc)),
    policy.StopProbe("p1"),
    policy.TargetedGc(token(1)),
    policy.SelfMeasure(token(1)),
    policy.ExportCapture("c1", policy.Pprof),
    policy.Checkpoint("before"),
    policy.Detach,
  ]
}

fn subsets(items: List(a)) -> List(List(a)) {
  case items {
    [] -> [[]]
    [first, ..rest] -> {
      let without = subsets(rest)
      list.append(without, list.map(without, fn(s) { [first, ..s] }))
    }
  }
}

// For every command and every set of grants, `authorize` admits exactly
// the direct commands whose required capabilities are all granted, and
// every decision carries an audit entry that agrees with it.
pub fn authorize_admits_exactly_the_granted_direct_commands_test() {
  use grants <- list.each(subsets(policy.all_capabilities))
  use command <- list.each(all_commands())
  let who = principal("p", grants)
  let Audited(result:, entry:) = policy.authorize(who, command, [live(1)], 5)
  let granted =
    list.all(policy.required_capabilities(command), fn(c) {
      list.contains(grants, c)
    })
  let direct = policy.confirmation_of(command) == policy.Direct

  assert is_ok(result) == { granted && direct }
  assert entry.principal == "p"
  assert entry.at_ms == 5
  assert entry.command == policy.describe(command)
  assert { entry.decision == Allowed } == is_ok(result)
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn every_command_requires_some_capability_test() {
  use command <- list.each(all_commands())
  assert policy.required_capabilities(command) != []
}

pub fn capability_assignments_test() {
  assert policy.required_capabilities(policy.TargetedGc(token(1))) == [Perturb]
  assert policy.required_capabilities(policy.SelfMeasure(token(1)))
    == [Summarize]
  assert policy.required_capabilities(policy.ExportCapture("c", policy.Pprof))
    == [Export]
  assert policy.required_capabilities(policy.Detach) == [Administer]
  assert policy.required_capabilities(policy.ReadMemory) == [Observe]
  assert policy.required_capabilities(policy.Checkpoint("a")) == [Observe]
  assert policy.perturbation_of(policy.Checkpoint("a")) == policy.Passive
  assert policy.describe(policy.Checkpoint("a")) == "checkpoint name=a"
  assert policy.required_capabilities(policy.StopProbe("p")) == [Profile]
}

pub fn missing_capabilities_are_named_in_the_denial_test() {
  let Audited(result:, entry:) =
    policy.authorize(principal("p", [Observe]), policy.Detach, [], 1)

  assert result == Error(policy.MissingCapability([Administer]))
  assert entry.decision == Denied("missing capability administer")
}

// A probe or targeted GC is never one step, even for a principal granted
// everything.
pub fn plan_first_commands_are_refused_by_authorize_test() {
  let Audited(result:, ..) =
    policy.authorize(
      owner_principal(),
      policy.TargetedGc(token(1)),
      [live(1)],
      1,
    )

  assert result == Error(policy.PlanRequired)
  assert policy.confirmation_of(policy.StartProbe(spec(policy.Counters)))
    == PlanFirst
}

// A command naming a pin is refused unless that pin was revalidated; a
// revalidation of a different pin does not count.
pub fn commands_naming_pins_need_a_matching_live_pin_test() {
  let command = policy.ReadProcess(token(1))

  let none = policy.authorize(owner_principal(), command, [], 1)
  assert none.result == Error(policy.TargetNotRevalidated(token(1)))

  let other = policy.authorize(owner_principal(), command, [live(2)], 1)
  assert other.result == Error(policy.TargetNotRevalidated(token(1)))

  let right =
    policy.authorize(owner_principal(), command, [live(2), live(1)], 1)
  assert is_ok(right.result)
}

// A pin from another incarnation cannot become a `LivePin`, so it can never
// satisfy this check.
pub fn a_pin_from_another_boot_cannot_be_revalidated_test() {
  let assert Ok(stale) = identity.pin(boot("old"), 1) as "valid pin"

  assert identity.check_pin(stale, boot("aaaa"))
    == Error(identity.OtherIncarnation("old", "aaaa"))
}

// A release must work after the process died, so it needs no live pin.
pub fn unpin_needs_no_live_pin_test() {
  let Audited(result:, ..) =
    policy.authorize(owner_principal(), policy.UnpinProcess(token(9)), [], 1)

  assert is_ok(result)
}

pub fn authorized_records_who_and_when_test() {
  let assert Audited(result: Ok(authorized), ..) =
    policy.authorize(owner_principal(), policy.ReadOwners, [], 77)
    as "owner may read"

  assert policy.authorized_command(authorized) == policy.ReadOwners
  assert policy.authorized_by(authorized) == PrincipalId("owner")
  assert policy.authorized_at(authorized) == 77
}

// ---------------------------------------------------------------- plans

fn plan_of(command: Command, who: Principal) -> policy.Plan {
  let assert Audited(result: Ok(plan), ..) =
    policy.plan(who, command, [live(1)], estimate(), 1000)
    as "plans"
  plan
}

pub fn a_plan_carries_scope_cost_class_digest_and_expiry_test() {
  let plan =
    plan_of(policy.StartProbe(spec(policy.CallTree)), owner_principal())

  assert policy.plan_scope(plan)
    == policy.PlanScope([token(1)], ["loom_session"], 1000)
  assert policy.plan_estimate(plan) == estimate()
  assert policy.plan_perturbation(plan) == policy.Tracing
  assert policy.plan_expires_at(plan) == 1000 + policy.plan_ttl_ms
  assert policy.plan_principal(plan) == PrincipalId("owner")
  assert policy.plan_command(plan) == policy.StartProbe(spec(policy.CallTree))
  assert policy.plan_digest(plan) != policy.PlanDigest("")
}

// A table listing is a read that needs no plan. Reading a process's binaries
// builds a tuple per reference in the target, so it is planned and confirmed
// and is a polling read, and it names its pin.
pub fn ets_and_binaries_reads_are_classed_test() {
  assert policy.required_capabilities(policy.ReadEtsTables) == [Observe]
  assert policy.confirmation_of(policy.ReadEtsTables) == policy.Direct
  assert policy.perturbation_of(policy.ReadEtsTables) == policy.Passive
  assert policy.command_pins(policy.ReadEtsTables) == []

  let read = policy.ReadBinaries(token(1))

  assert policy.required_capabilities(read) == [Observe]
  assert policy.confirmation_of(read) == policy.PlanFirst
  assert policy.perturbation_of(read) == policy.Polling
  assert policy.command_pins(read) == [token(1)]
  assert policy.command_name(read) == "read_binaries"
  assert policy.describe(read)
    == "read_binaries pin=" <> identity.pin_to_string(token(1))
}

pub fn a_binaries_read_is_planned_then_confirmed_test() {
  let plan = plan_of(policy.ReadBinaries(token(1)), owner_principal())
  let Audited(result:, ..) =
    policy.confirm(plan, owner_principal(), [live(1)], estimate(), 2000)

  let assert Ok(authorized) = result as "confirms"
  assert policy.authorized_command(authorized) == policy.ReadBinaries(token(1))
}

pub fn perturbation_classes_test() {
  assert policy.perturbation_of(policy.TargetedGc(token(1))) == policy.ForcedGc
  assert policy.perturbation_of(policy.StartProbe(spec(policy.Sampling)))
    == policy.Polling
  assert policy.perturbation_of(policy.ReadMemory) == policy.Passive

  // Counters send no trace message; the other trace probes do.
  assert policy.perturbation_of(policy.StartProbe(spec(policy.Counters)))
    == policy.Counting
  assert policy.perturbation_of(policy.StartProbe(spec(policy.CallTree)))
    == policy.Tracing
  assert policy.perturbation_of(policy.StartProbe(spec(policy.SchedulingGc)))
    == policy.Tracing
  assert policy.perturbation_code(policy.Counting) == "counting"
}

pub fn confirm_authorizes_the_planned_command_test() {
  let command = policy.TargetedGc(token(1))
  let plan = plan_of(command, owner_principal())
  let Audited(result:, entry:) =
    policy.confirm(plan, owner_principal(), [live(1)], estimate(), 2000)

  let assert Ok(authorized) = result as "confirms"
  assert policy.authorized_command(authorized) == command
  assert entry.stage == policy.ConfirmStage
  assert entry.decision == Allowed
}

pub fn confirm_refuses_a_different_principal_test() {
  let plan = plan_of(policy.TargetedGc(token(1)), owner_principal())
  let intruder = principal("intruder", policy.all_capabilities)
  let Audited(result:, entry:) =
    policy.confirm(plan, intruder, [live(1)], estimate(), 2000)

  assert result == Error(policy.WrongPrincipal)
  assert entry.decision == Denied("plan belongs to another principal")
}

pub fn confirm_refuses_an_expired_plan_test() {
  let plan = plan_of(policy.TargetedGc(token(1)), owner_principal())
  let expiry = policy.plan_expires_at(plan)

  let before =
    policy.confirm(plan, owner_principal(), [live(1)], estimate(), expiry - 1)
  assert is_ok(before.result)

  let at =
    policy.confirm(plan, owner_principal(), [live(1)], estimate(), expiry)
  assert at.result == Error(policy.PlanExpired)
}

pub fn confirm_refuses_a_changed_estimate_test() {
  let plan = plan_of(policy.TargetedGc(token(1)), owner_principal())
  let changed = policy.Estimate(..estimate(), events_high: 2000)
  let Audited(result:, ..) =
    policy.confirm(plan, owner_principal(), [live(1)], changed, 2000)

  assert result == Error(policy.PlanChanged)
}

// A pin that is no longer live at confirmation time stops the action even
// though the plan was valid.
pub fn confirm_refuses_a_pin_that_is_no_longer_live_test() {
  let plan = plan_of(policy.TargetedGc(token(1)), owner_principal())
  let Audited(result:, ..) =
    policy.confirm(plan, owner_principal(), [], estimate(), 2000)

  assert result == Error(policy.TargetNotRevalidated(token(1)))
}

// A grant revoked between plan and confirm stops the action.
pub fn confirm_rechecks_grants_test() {
  let plan = plan_of(policy.TargetedGc(token(1)), owner_principal())
  let demoted = principal("owner", [Observe])
  let Audited(result:, ..) =
    policy.confirm(plan, demoted, [live(1)], estimate(), 2000)

  assert result == Error(policy.MissingCapability([Perturb]))
}

pub fn plan_refuses_direct_commands_and_missing_grants_test() {
  let direct =
    policy.plan(owner_principal(), policy.ReadMemory, [], estimate(), 1)
  assert direct.result == Error(policy.NotPlannable)

  let weak =
    policy.plan(
      principal("p", [Observe]),
      policy.TargetedGc(token(1)),
      [live(1)],
      estimate(),
      1,
    )
  assert weak.result == Error(policy.MissingCapability([Perturb]))
  assert weak.entry.stage == policy.PlanStage
  assert weak.entry.decision == Denied("missing capability perturb")
}

pub fn plan_refuses_an_unrevalidated_target_test() {
  let Audited(result:, ..) =
    policy.plan(
      owner_principal(),
      policy.TargetedGc(token(1)),
      [],
      estimate(),
      1,
    )

  assert result == Error(policy.TargetNotRevalidated(token(1)))
}

// ---------------------------------------------------------------- specs

pub fn probe_specs_are_bounded_test() {
  let ok = spec(policy.Counters)

  assert policy.validate_spec(ok) == Ok(Nil)
  assert policy.validate_spec(policy.ProbeSpec(..ok, targets: []))
    == Error(policy.NoTargets)
  assert policy.validate_spec(policy.ProbeSpec(..ok, modules: []))
    == Error(policy.NoModules)
  assert policy.validate_spec(policy.ProbeSpec(..ok, duration_ms: 0))
    == Error(policy.BadDuration(policy.max_probe_duration_ms))
  assert policy.validate_spec(
      policy.ProbeSpec(..ok, duration_ms: policy.max_probe_duration_ms + 1),
    )
    == Error(policy.BadDuration(policy.max_probe_duration_ms))
  assert policy.validate_spec(
      policy.ProbeSpec(..ok, targets: list.repeat(token(1), 9)),
    )
    == Error(policy.TooManyTargets(8))
  assert policy.validate_spec(
      policy.ProbeSpec(
        ..ok,
        modules: list.repeat("m", policy.max_probe_modules + 1),
      ),
    )
    == Error(policy.TooManyModules(policy.max_probe_modules))
}

// Sampling needs no modules and allows more targets than a trace.
pub fn sampling_limits_differ_from_trace_limits_test() {
  let sampling =
    policy.ProbeSpec(
      kind: policy.Sampling,
      targets: list.repeat(token(1), 16),
      modules: [],
      duration_ms: 1000,
      rate_hz: 50,
    )

  assert policy.validate_spec(sampling) == Ok(Nil)
  assert policy.validate_spec(
      policy.ProbeSpec(..sampling, targets: list.repeat(token(1), 17)),
    )
    == Error(policy.TooManyTargets(16))
}

pub fn an_invalid_spec_cannot_be_planned_test() {
  let bad = policy.ProbeSpec(..spec(policy.Counters), duration_ms: 0)
  let Audited(result:, entry:) =
    policy.plan(
      owner_principal(),
      policy.StartProbe(bad),
      [live(1)],
      estimate(),
      1,
    )

  assert result
    == Error(
      policy.InvalidSpec(policy.BadDuration(policy.max_probe_duration_ms)),
    )
  assert entry.decision != Allowed
}

// ------------------------------------------------------------- properties

// Whatever the principal and command, a decision and its audit entry
// agree, and a denial's reason is the denial's text.
pub fn property_every_decision_is_audited_consistently_test() {
  use #(grants, index) <- gen.check(gen.tuple2(
    gen.small_list(
      gen.one_of(Observe, [Summarize, Profile, Perturb, Export, Administer]),
    ),
    gen.non_negative(),
  ))
  let commands = all_commands()
  let command = case list.drop(commands, index % list.length(commands)) {
    [first, ..] -> first
    [] -> policy.Detach
  }
  let Audited(result:, entry:) =
    policy.authorize(principal("p", grants), command, [live(1)], 3)

  case result {
    Ok(_) -> {
      assert entry.decision == Allowed
    }
    Error(denial) -> {
      assert entry.decision == Denied(policy.denial_text(denial))
    }
  }
}

pub fn a_sampling_probe_is_limited_to_what_the_agent_runs_test() {
  let sampling = spec(policy.Sampling)

  assert policy.max_duration_ms(policy.Sampling) == 60_000
  assert policy.validate_spec(policy.ProbeSpec(..sampling, duration_ms: 60_000))
    == Ok(Nil)
  assert policy.validate_spec(
      policy.ProbeSpec(..sampling, duration_ms: 300_000),
    )
    == Error(policy.BadDuration(60_000))
  assert policy.max_duration_ms(policy.Counters) == policy.max_probe_duration_ms
}

// The agent runs a call tree probe for at most ten seconds over at most four
// processes and eight patterns, and an events probe for at most a minute over
// eight processes. A plan for more would describe a scope the agent does not
// run, so the limits are checked before the agent is asked.
pub fn trace_probes_are_limited_to_what_the_agent_runs_test() {
  let calls = spec(policy.CallTree)

  assert policy.max_duration_ms(policy.CallTree) == 10_000
  assert policy.validate_spec(policy.ProbeSpec(..calls, duration_ms: 10_000))
    == Ok(Nil)
  assert policy.validate_spec(policy.ProbeSpec(..calls, duration_ms: 10_001))
    == Error(policy.BadDuration(10_000))
  assert policy.validate_spec(
      policy.ProbeSpec(..calls, targets: list.repeat(token(1), 5)),
    )
    == Error(policy.TooManyTargets(4))
  assert policy.validate_spec(
      policy.ProbeSpec(..calls, modules: list.repeat("m", 9)),
    )
    == Error(policy.TooManyModules(8))

  let events = spec(policy.SchedulingGc)

  assert policy.max_duration_ms(policy.SchedulingGc) == 60_000
  assert policy.validate_spec(
      policy.ProbeSpec(..events, targets: list.repeat(token(1), 8), modules: []),
    )
    == Ok(Nil)
  assert policy.validate_spec(
      policy.ProbeSpec(..events, duration_ms: 60_001, modules: []),
    )
    == Error(policy.BadDuration(60_000))
}

// A sampling probe carries the rate it asked for, and the agent's ceiling is
// shared by its targets, so the plan can say what will really run.
pub fn a_sampling_rate_is_bounded_and_shared_between_targets_test() {
  let sampling = spec(policy.Sampling)

  assert policy.validate_spec(policy.ProbeSpec(..sampling, rate_hz: 0))
    == Error(policy.BadRate(1000))
  assert policy.validate_spec(policy.ProbeSpec(..sampling, rate_hz: 1001))
    == Error(policy.BadRate(1000))
  assert policy.validate_spec(policy.ProbeSpec(..sampling, rate_hz: 1000))
    == Ok(Nil)

  // A trace probe has no rate to check.
  assert policy.validate_spec(
      policy.ProbeSpec(..spec(policy.Counters), rate_hz: 0),
    )
    == Ok(Nil)

  assert policy.sampling_rate_hz(100, 1) == 100
  assert policy.sampling_rate_hz(100, 10) == 100
  assert policy.sampling_rate_hz(100, 16) == 62
  assert policy.sampling_rate_hz(5000, 1) == 1000
  assert policy.sampling_rate_hz(0, 4) == 1
  assert policy.target_limit(policy.Sampling) == 16
}

// The rate is part of what a plan binds to: a plan for another rate is a
// different plan.
pub fn the_rate_is_part_of_the_plan_digest_test() {
  let at_50 = policy.StartProbe(spec(policy.Sampling))
  let at_100 =
    policy.StartProbe(policy.ProbeSpec(..spec(policy.Sampling), rate_hz: 100))

  assert policy.describe(at_50) != policy.describe(at_100)
}
