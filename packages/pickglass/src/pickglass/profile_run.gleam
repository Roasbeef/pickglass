//// `pickglass profile`: one stack probe from the command line.
////
//// The command is the same request the profile buttons make, made as the
//// local owner. It starts the parts a page would use (the audit log, the
//// observation hub and the service that holds the gate) and drives them
//// through the service's `Page`, so every pin, the plan, the confirm and the
//// release of the pins is decided by the gate and audited exactly as it is
//// from a browser. Nothing here talks to the agent except through them.
////
//// The steps are the operator's: attach, wait for two census passes so the
//// busiest processes can be ranked by reductions per second, choose the
//// processes (`profile_scope`, the rule the buttons use), plan, confirm, wait
//// for the probe to end and take its profile, wait for the service to
//// release the pins it took, and detach. Detach runs whether or not a step
//// failed, so a failed command leaves nothing pinned or sampling in the
//// target.
////
//// The summary says how much was sampled, how well, and what the numbers do
//// not mean: samples are taken at reduction safe points, so time in long
//// BIFs and NIFs is under-counted and widths are shares of samples, not of
//// time. A failure is one typed line, `profile failed (code): reason`, and
//// a non-zero exit status.
////
//// ## Flow
////
//// - `run` attaches, calls `profile` and detaches.
//// - `profile` is the sequence above, `observe` and `choose` its first two
////   steps, `sample` the plan, confirm and wait.
//// - `finish` writes the file and builds the summary (`summary`).

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import pickglass/attach
import pickglass/audit
import pickglass/capture_build
import pickglass/capture_file
import pickglass/cli
import pickglass/downloads
import pickglass/feeds
import pickglass/host
import pickglass/hub
import pickglass/internal/ffi_dist
import pickglass/observation.{type Observation}
import pickglass/probe_book.{type ProbeRecord}
import pickglass/profile_export
import pickglass/profile_scope
import pickglass/remote.{type Remote}
import pickglass/seam
import pickglass/secret
import pickglass/service
import pickglass_core/export/text
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile.{type Profile}
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/view/ui
import simplifile

/// Why a profile command failed. Each variant has a stable code, written
/// first in the message, so a script can tell them apart.
pub type Failure {
  /// The target could not be attached.
  AttachFailed(reason: String)

  /// The hub took no census, so there is nothing to choose from.
  NoObservation(reason: String)

  /// The scope names no process the last pass lists.
  NoProcesses(reason: String)

  /// The gate or the agent refused the plan, or a pin.
  PlanRefused(reason: String)

  /// The agent refused to start the probe after the confirm.
  StartRefused(reason: String)

  /// The probe ended without a profile.
  ProbeFailed(reason: String)

  /// The probe did not end in the time allowed.
  ProbeTimedOut(reason: String)

  /// The file could not be written.
  WriteFailed(reason: String)
}

/// The failure as the one line the command prints.
///
/// ## Examples
///
/// ```gleam
/// profile_run.describe(NoProcesses("the last pass lists no process"))
/// // -> "profile failed (no_processes): the last pass lists no process"
/// ```
pub fn describe(failure: Failure) -> String {
  let #(code, reason) = case failure {
    AttachFailed(reason:) -> #("attach_failed", reason)
    NoObservation(reason:) -> #("no_observation", reason)
    NoProcesses(reason:) -> #("no_processes", reason)
    PlanRefused(reason:) -> #("plan_refused", reason)
    StartRefused(reason:) -> #("start_refused", reason)
    ProbeFailed(reason:) -> #("probe_failed", reason)
    ProbeTimedOut(reason:) -> #("probe_timed_out", reason)
    WriteFailed(reason:) -> #("write_failed", reason)
  }

  "profile failed (" <> code <> "): " <> reason
}

/// The principal the command acts as: the local owner, holding every
/// capability, as an interactive `pickglass open` ticket does. The gate still
/// checks each command.
pub const principal_name = "cli-local-owner"

/// Run the command and return the process exit status.
///
/// ## Examples
///
/// ```gleam
/// profile_run.run(options, "0.1.0")
/// // -> 0
/// ```
pub fn run(options: cli.ProfileOptions, version: String) -> Int {
  case cli.connect(options.selector, options.agent_ebin) {
    Error(message) -> fail(AttachFailed(message))
    Ok(#(target, session)) -> {
      // Detach runs whether or not the profile was taken.
      let outcome = case remote.of_session(session) {
        Ok(remote) ->
          execute(options, version, target.node, target.os_pid, remote)
        Error(reason) -> Error(AttachFailed(reason))
      }
      let unload = attach.detach(session)

      case outcome {
        Ok(text) -> {
          io.println(text)
          io.println(unloaded(unload))

          0
        }
        Error(failure) -> fail(failure)
      }
    }
  }
}

fn fail(failure: Failure) -> Int {
  io.println_error("pickglass: " <> describe(failure))

  1
}

fn unloaded(unload: attach.Unload) -> String {
  case unload {
    attach.ModulesUnloaded ->
      "detached; the agent's modules are unloaded from the target"
    attach.ModulesRemain(count) ->
      "detached; "
      <> int.to_string(count)
      <> " agent modules were still loaded after the wait"
    attach.ModulesUnreadable ->
      "detached; the target could not be asked whether the agent unloaded"
  }
}

/// The sequence, over a remote. The parts it starts are linked to the
/// calling process and end with it. `run` calls it after attaching; tests
/// call it over a fake agent.
///
/// ## Examples
///
/// ```gleam
/// profile_run.execute(options, "0.1.0", "app@127.0.0.1", 4242, remote)
/// // -> Ok("profile of ...")
/// ```
pub fn execute(
  options: cli.ProfileOptions,
  version: String,
  node: String,
  os_pid: Int,
  remote: Remote,
) -> Result(String, Failure) {
  use log <- result.try(audit.start() |> result.map_error(AttachFailed))

  let clock = ffi_dist.system_time_ms
  let config = hub.Config(..hub.default_config(clock), cadence_ms: 1000)

  use the_hub <- result.try(
    hub.start_live(remote, config) |> result.map_error(AttachFailed),
  )
  use the_service <- result.try(
    service.start(
      service.Config(
        remote: Some(remote),
        hub: the_hub,
        audit: log,
        clock:,
        mode: seam.Live(
          node:,
          incarnation: identity.NodeIncarnation(
            node_digest: capture_build.sha256_hex(node),
            creation: 0,
            boot: remote.boot,
          ),
          os: identity.OsProcess(pid: os_pid, start: identity.UnreadableStart),
        ),
        saver: None,
        marks: [],
        probes: [],
      ),
    )
    |> result.map_error(AttachFailed),
  )

  let page =
    service.page_for(
      the_service,
      policy.Principal(
        id: policy.PrincipalId(principal_name),
        grants: set.from_list(host.operator_grants()),
      ),
    )

  use observations <- result.try(observe(page, options.target))
  use chosen <- result.try(choose(options.target, observations))
  use probe <- result.try(sample(page, options, chosen))

  let released = wait_for_release(page)

  use text <- result.try(finish(
    options,
    version,
    node,
    os_pid,
    remote,
    probe,
    chosen,
    list.reverse(hub.latest(the_hub)),
    audit.tail(log, audit.capacity),
  ))

  Ok(text <> "\n" <> released)
}

// ---------------------------------------------------------------- observe

// How long to wait for the census passes, in milliseconds.
const observe_deadline_ms = 30_000

// Two passes give reductions per second, which ranking the busiest needs. A
// single process needs only to be named, so one pass is enough there.
fn observe(
  page: seam.Page,
  target: cli.ProfileTarget,
) -> Result(List(Observation), Failure) {
  let needed = case target {
    cli.ProcessTarget(_) -> 1
    cli.OwnerTarget(_) | cli.TopTarget(_) -> 2
  }
  let updates = process.new_subject()

  use _ <- result.try(
    page.subscribe(updates) |> result.map_error(NoObservation),
  )

  wait_for_passes(page, updates, needed, observe_deadline_ms)
}

fn wait_for_passes(
  page: seam.Page,
  updates: process.Subject(hub.Update),
  needed: Int,
  remaining_ms: Int,
) -> Result(List(Observation), Failure) {
  let held = page.latest()

  case list.length(held) >= needed, remaining_ms > 0 {
    True, _ -> Ok(held)
    False, False ->
      Error(NoObservation(
        "the target gave no census within "
        <> int.to_string(observe_deadline_ms / 1000)
        <> " seconds",
      ))
    False, True ->
      case process.receive(updates, 1000) {
        Ok(hub.TargetLost(reason)) -> Error(NoObservation(reason))
        Ok(hub.Observed(_)) | Error(Nil) ->
          wait_for_passes(page, updates, needed, remaining_ms - 1000)
      }
  }
}

// ----------------------------------------------------------------- choose

// The processes to sample, by the rule the buttons use.
fn choose(
  target: cli.ProfileTarget,
  observations: List(Observation),
) -> Result(profile_scope.Chosen, Failure) {
  let #(rows, _) = feeds.rated_rows_of(observations, 8)

  let chosen = case target {
    cli.TopTarget(count) ->
      profile_scope.choose(
        profile_scope.candidates_of(rows),
        count,
        profile_scope.WholeNode,
      )
    cli.OwnerTarget(text) ->
      profile_scope.choose(
        profile_scope.candidates_of(list.filter(rows, owned_by(text))),
        seam.profile_limit,
        profile_scope.OwnerScope(text),
      )
    cli.ProcessTarget(pid_text) ->
      profile_scope.choose(
        [profile_scope.Candidate(pid_text:, rate: None, heap_bytes: 0)],
        1,
        profile_scope.OneProcess(pid_text),
      )
  }

  result.map_error(chosen, fn(refusal) {
    let profile_scope.NothingToProfile(reason:) = refusal

    NoProcesses(reason)
  })
}

// A row belongs to an owner when the owner's segments are a prefix of its
// path, so `session:abc` takes the processes of every strand beneath it.
fn owned_by(text: String) -> fn(model.ProcRow) -> Bool {
  fn(row: model.ProcRow) {
    case row.attribution, text {
      owner.Unattributed, "unknown" -> True
      owner.Unattributed, _ -> False
      owner.Attributed(..), "unknown" -> False
      owner.Attributed(winner:, ..), _ ->
        string.starts_with(
          owner.path_to_string(winner.path) <> "/",
          text <> "/",
        )
    }
  }
}

// ----------------------------------------------------------------- sample

// How long past the probe's own duration to wait for the viewer to take its
// result, in seconds. The service polls once a second.
const grace_s = 30

// Plan, confirm and wait. A refusal at either step is a failure with the
// gate's own reason.
fn sample(
  page: seam.Page,
  options: cli.ProfileOptions,
  chosen: profile_scope.Chosen,
) -> Result(ProbeRecord, Failure) {
  case
    page.profile(seam.PlanProfile(
      pids: chosen.pids,
      chosen: chosen.sentence,
      duration_ms: options.seconds * 1000,
      rate_hz: options.rate_hz,
    ))
  {
    seam.PlanReady(id, plan) -> {
      io.println(plan_line(chosen, options, policy.plan_scope(plan)))

      case page.submit(seam.ConfirmPlan(id)) {
        seam.ProbeStarted(probe_id, _) ->
          wait_for_probe(page, probe_id, options.seconds + grace_s)
        seam.Rejected(reason) -> Error(StartRefused(reason))
        _ -> Error(StartRefused("the viewer did not start the probe"))
      }
    }
    seam.Rejected(reason) -> Error(PlanRefused(reason))
    _ -> Error(PlanRefused("the viewer did not plan the probe"))
  }
}

fn plan_line(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  scope: policy.PlanScope,
) -> String {
  let count = list.length(scope.targets)

  "sampling "
  <> chosen.sentence
  <> ": "
  <> int.to_string(count)
  <> " processes pinned, "
  <> int.to_string(policy.sampling_rate_hz(options.rate_hz, count))
  <> " Hz each, "
  <> int.to_string(options.seconds)
  <> " s"
}

fn wait_for_probe(
  page: seam.Page,
  probe_id: String,
  seconds_left: Int,
) -> Result(ProbeRecord, Failure) {
  case list.find(page.probes(), fn(probe) { probe.id == probe_id }) {
    Ok(probe) ->
      case probe.state {
        probe_book.Finished(..) -> Ok(probe)
        probe_book.Running ->
          case seconds_left > 0 {
            True -> {
              process.sleep(1000)

              wait_for_probe(page, probe_id, seconds_left - 1)
            }
            False ->
              Error(ProbeTimedOut(
                "probe " <> probe_id <> " did not end in the time allowed",
              ))
          }
      }
    Error(Nil) ->
      Error(ProbeFailed("the viewer has no record of probe " <> probe_id))
  }
}

// The service releases the pins a profile took once the probe has ended. The
// command waits for that, bounded, so the detach that follows does not race
// the release.
fn wait_for_release(page: seam.Page) -> String {
  case wait_for_no_pins(page, 8) {
    True -> "pins released"
    False ->
      "some pins were still held when the wait ended; detaching releases them"
  }
}

fn wait_for_no_pins(page: seam.Page, attempts: Int) -> Bool {
  case list.any(page.pins(), fn(pin) { pin.status == seam.PinLive }) {
    False -> True
    True ->
      case attempts > 0 {
        True -> {
          process.sleep(500)

          wait_for_no_pins(page, attempts - 1)
        }
        False -> False
      }
  }
}

// ----------------------------------------------------------------- finish

fn finish(
  options: cli.ProfileOptions,
  version: String,
  node: String,
  os_pid: Int,
  remote: Remote,
  probe: ProbeRecord,
  chosen: profile_scope.Chosen,
  observations: List(Observation),
  entries: List(audit.Entry),
) -> Result(String, Failure) {
  case probe.state {
    probe_book.Running -> Error(ProbeFailed("the probe is still running"))
    probe_book.Finished(profile: None, outcome:, ..) ->
      Error(ProbeFailed(ui.truncation_text(outcome)))
    probe_book.Finished(profile: Some(found), outcome:, notes:, ..) -> {
      use column <- result.try(
        profile.column(found, 0)
        |> result.replace_error(ProbeFailed("the profile has no values")),
      )
      use written <- result.try(write(
        options,
        version,
        node,
        os_pid,
        remote,
        probe,
        found,
        column,
        observations,
        entries,
      ))

      Ok(summary(chosen, options, probe, outcome, notes, found, column, written))
    }
  }
}

// What was written, and where, for the summary. A text summary with no file
// writes nothing.
fn write(
  options: cli.ProfileOptions,
  version: String,
  node: String,
  os_pid: Int,
  remote: Remote,
  probe: ProbeRecord,
  found: Profile,
  column: profile.Column,
  observations: List(Observation),
  entries: List(audit.Entry),
) -> Result(Option(String), Failure) {
  let title = "probe-" <> probe.id
  let span_ms = case probe.state {
    probe_book.Finished(cost:, ..) ->
      option.unwrap(measure.to_option(cost.wall_ms), 0)
    probe_book.Running -> 0
  }

  case options.format {
    cli.TextFormat ->
      case options.out {
        None -> Ok(None)
        Some(path) ->
          text.export(found, column, text.default_config)
          |> result.replace_error(WriteFailed("the profile has no call stacks"))
          |> result.try(fn(made) { to_file(path, made.body) })
          |> result.map(Some)
      }
    cli.PgcapFormat -> {
      let path = option.unwrap(options.out, "pickglass-profile.pgcap")
      let facts =
        capture_build.Facts(
          pickglass_version: version,
          node:,
          os_pid:,
          boot: remote.boot,
          role: cli.role(options.selector),
          workload: "",
          top_k: 200,
          deadline_ms: observation.ask_deadline_ms,
          os_start: identity.UnreadableStart,
          clock: None,
        )

      use #(header, records) <- result.try(
        capture_build.assemble(
          facts,
          "cap-" <> secret.token(9),
          observations,
          measure.OneShot,
          [],
          entries,
          [probe],
        )
        |> result.map_error(WriteFailed),
      )
      use _ <- result.map(
        capture_file.write(path, header, records)
        |> result.map_error(WriteFailed),
      )

      Some(path)
    }
    cli.SpeedscopeFormat | cli.CollapsedFormat | cli.ChromeFormat -> {
      let choice = case options.format {
        cli.CollapsedFormat -> msg.AsCollapsed
        cli.ChromeFormat -> msg.AsChromeTrace
        _ -> msg.AsSpeedscope
      }

      use built <- result.try(
        profile_export.make(choice, title, span_ms, found, column)
        |> result.map_error(fn(refused) { WriteFailed(refused.reason) }),
      )
      let path =
        option.unwrap(options.out, "pickglass-" <> title <> extension(built))

      use _ <- result.map(to_file(path, built.download.body))

      Some(path)
    }
  }
}

// The default file name keeps the export's own extension, so a speedscope
// file is `.speedscope.json` and speedscope.app opens it by name.
fn extension(built: profile_export.Built) -> String {
  let downloads.Download(file_name:, ..) = built.download

  case string.split_once(file_name, ".") {
    Ok(#(_, rest)) -> "." <> rest
    Error(Nil) -> ""
  }
}

fn to_file(path: String, body: String) -> Result(String, Failure) {
  simplifile.write(path, body)
  |> result.map(fn(_) { path })
  |> result.map_error(fn(error) {
    WriteFailed(
      "cannot write " <> path <> ": " <> simplifile.describe_error(error),
    )
  })
}

// ---------------------------------------------------------------- summary

/// The text the command prints: what was sampled, the coverage and its
/// caveats, the heaviest functions and where the file went. A text format
/// prints the call tree as well.
fn summary(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  outcome: measure.Outcome,
  notes: List(String),
  found: Profile,
  column: profile.Column,
  written: Option(String),
) -> String {
  let samples = profile.total(found, column)

  let lines = [
    "profile of " <> chosen.sentence,
    "probe "
      <> probe.id
      <> ": "
      <> int.to_string(samples)
      <> " samples over "
      <> int.to_string(options.seconds)
      <> " s, "
      <> ui.truncation_text(outcome),
    "coverage: "
      <> case list.find(notes, string.starts_with(_, "Sampled")) {
      Ok(sampled) -> sampled
      Error(Nil) -> "no coverage note"
    },
    "caveats: sampled at reduction safe points; long BIFs and NIFs are under-counted, and widths are shares of samples, not of time.",
    ..list.map(
      list.filter(notes, fn(note) { !string.starts_with(note, "Sampled") }),
      fn(note) { "  " <> note },
    )
  ]

  let body = case options.format {
    cli.TextFormat ->
      case text.export(found, column, text.default_config) {
        Ok(made) -> made.body
        Error(_) -> text.functions(found, column, 15)
      }
    cli.SpeedscopeFormat
    | cli.CollapsedFormat
    | cli.ChromeFormat
    | cli.PgcapFormat -> text.functions(found, column, 15)
  }

  let destination = case written, options.format {
    Some(path), cli.SpeedscopeFormat ->
      "wrote " <> path <> " (open it at https://www.speedscope.app)"
    Some(path), _ -> "wrote " <> path
    None, _ -> ""
  }

  string.join([string.join(lines, "\n"), "", body, destination], "\n")
}
