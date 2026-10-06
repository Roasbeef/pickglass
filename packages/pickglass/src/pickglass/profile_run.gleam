//// `pickglass profile`: one probe from the command line.
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
//// time. By default only the samples taken while a process was running or
//// runnable are counted, and the summary states how the whole set split
//// between those and the samples taken while a process waited, because on an
//// idle node the waits would otherwise be the heaviest functions;
//// `--include-waiting` counts them all. A profile with no running sample says
//// so plainly and writes no file of nothing.
////
//// With `--trace-calls` the command traces the calls of the named modules
//// instead and builds a call tree with exact counts and times, over the same
//// plan, confirm and release path. The summary then says how the probe ended
//// and what it dropped, and that untraced time counts as the caller's.
////
//// With `--allocation` the command counts, for the functions of the named
//// modules, the calls, the call time and the words allocated on the process
//// heap, over the same path. The result is one total per function and has no
//// call stacks, so it is written as a capture or as text and never as a flame
//// graph. `allocation_report` words it: allocated words beside the target's
//// word size, the processes and window, the functions the VM could not read,
//// and that the words are cumulative allocation and not retained heap. A
//// failure is one typed line, `profile failed (code): reason`, and a non-zero
//// exit status.
////
//// ## Flow
////
//// - `run` attaches, calls `execute` and detaches.
//// - `execute` is the sequence above, `observe` and `choose` its first two
////   steps, `sample` the plan, confirm and wait.
//// - `finish` writes the file and builds the summary (`summary`); an
////   allocation count's text is built by the allocation_report module.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import pickglass/allocation_profile
import pickglass/allocation_report.{type Report}
import pickglass/attach
import pickglass/audit
import pickglass/calltrace_profile
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
import pickglass_core/capture
import pickglass_core/export/text
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/policy
import pickglass_core/profile.{type Profile}
import pickglass_core/profile/activity
import pickglass_web/model
import pickglass_web/msg
import pickglass_web/view/profile as profile_view
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
    attach.OtherViewersRemain(count) ->
      "detached; the agent stays on the target for the other viewers ("
      <> int.to_string(count)
      <> " attached)"
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
  execute_within(options, version, node, os_pid, remote, grace_s)
}

/// `execute` with the grace, in seconds, the command waits past the probe's
/// own duration to be told how it ended. A test of the timeout shortens it.
///
/// ## Examples
///
/// ```gleam
/// profile_run.execute_within(options, "0.1.0", "app@127.0.0.1", 4242, remote, 0)
/// // -> Error(ProbeTimedOut(..)) when the probe has not ended
/// ```
pub fn execute_within(
  options: cli.ProfileOptions,
  version: String,
  node: String,
  os_pid: Int,
  remote: Remote,
  grace_s: Int,
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
  use chosen <- result.try(choose(options.target, options.method, observations))
  use probe <- result.try(sample(page, options, chosen, grace_s))

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
  method: cli.ProfileMethod,
  observations: List(Observation),
) -> Result(profile_scope.Chosen, Failure) {
  let #(rows, _) = feeds.rated_rows_of(observations, 8)

  let owner_limit = case method {
    cli.SampleStacks(..) -> seam.profile_limit
    cli.TraceCalls(..) -> seam.trace_limit
    cli.CountAllocation(..) -> seam.allocation_limit
  }

  let chosen = case target {
    cli.TopTarget(count) -> {
      let #(others, own) = profile_scope.without_own(rows)

      profile_scope.choose_excluding(
        profile_scope.candidates_of(others),
        count,
        profile_scope.WholeNode,
        own,
      )
    }
    cli.OwnerTarget(text) ->
      profile_scope.choose(
        profile_scope.candidates_of(list.filter(rows, owned_by(text))),
        owner_limit,
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

/// How long past the probe's own duration to wait for the viewer to take its
/// result, in seconds. The service polls once a second. The agent ends the
/// probe at its deadline whether or not anyone waits, so the grace only bounds
/// how long this command waits to be told.
pub const grace_s = 30

// Plan, confirm and wait. A refusal at either step is a failure with the
// gate's own reason.
fn sample(
  page: seam.Page,
  options: cli.ProfileOptions,
  chosen: profile_scope.Chosen,
  grace_s: Int,
) -> Result(ProbeRecord, Failure) {
  case page.profile(plan_request(options, chosen)) {
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

// The profile request of the method the command line chose.
fn plan_request(
  options: cli.ProfileOptions,
  chosen: profile_scope.Chosen,
) -> seam.ProfileRequest {
  case options.method {
    cli.SampleStacks(rate_hz:, ..) ->
      seam.PlanProfile(
        pids: chosen.pids,
        chosen: chosen.sentence,
        duration_ms: options.seconds * 1000,
        rate_hz:,
      )
    cli.TraceCalls(modules:) ->
      seam.PlanCallTrace(
        pids: chosen.pids,
        chosen: chosen.sentence,
        duration_ms: options.seconds * 1000,
        modules:,
      )
    cli.CountAllocation(modules:) ->
      seam.PlanAllocation(
        pids: chosen.pids,
        chosen: chosen.sentence,
        duration_ms: options.seconds * 1000,
        modules:,
      )
  }
}

fn plan_line(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  scope: policy.PlanScope,
) -> String {
  let count = list.length(scope.targets)

  case options.method {
    cli.SampleStacks(rate_hz:, ..) ->
      "sampling "
      <> chosen.sentence
      <> ": "
      <> int.to_string(count)
      <> " processes pinned, "
      <> int.to_string(policy.sampling_rate_hz(rate_hz, count))
      <> " Hz each, "
      <> int.to_string(options.seconds)
      <> " s"
    cli.TraceCalls(modules:) ->
      "tracing calls of "
      <> string.join(modules, ", ")
      <> " in "
      <> chosen.sentence
      <> ": "
      <> int.to_string(count)
      <> " processes pinned, "
      <> int.to_string(options.seconds)
      <> " s"
    cli.CountAllocation(modules:) ->
      "counting calls, call time and allocated words of "
      <> string.join(modules, ", ")
      <> " in "
      <> chosen.sentence
      <> ": "
      <> int.to_string(count)
      <> " processes pinned, "
      <> int.to_string(options.seconds)
      <> " s"
  }
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

// What the probe measured, as the command reports it: the whole profile, the
// column the views and the summary read, and how its samples split by what the
// processes were doing.
type Measured {
  Measured(
    whole: Profile,
    column: profile.Column,
    /// The samples the files and the summary count.
    shown: Profile,
    samples: model.ActivityView,
    /// An allocation count's report, which is its summary and its text file.
    /// The other methods have none.
    allocation: Option(Report),
  )
}

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
      use measured <- result.try(measure_of(
        options,
        probe,
        found,
        chosen,
        observations,
      ))
      use written <- result.try(write(
        options,
        version,
        node,
        os_pid,
        remote,
        probe,
        measured,
        observations,
        entries,
      ))

      Ok(summary(chosen, options, probe, outcome, notes, measured, written))
    }
  }
}

// The column a method reads: a stack profile's sample count, a call tree's
// exclusive time (the one whose sums are the widths of a flame's boxes). A
// stack profile is cut to the samples the command line asked to count.
fn measure_of(
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  found: Profile,
  chosen: profile_scope.Chosen,
  observations: List(Observation),
) -> Result(Measured, Failure) {
  case options.method {
    cli.SampleStacks(samples: inclusion, ..) -> {
      use column <- result.map(
        profile.column(found, 0)
        |> result.replace_error(ProbeFailed("the profile has no values")),
      )

      Measured(
        whole: found,
        column:,
        shown: activity.restrict(found, inclusion),
        samples: case activity.has_status(found) {
          True ->
            model.Statuses(
              inclusion:,
              split: activity.split(found, column),
              processes: Some(probe.matched),
            )
          False -> model.NoStatuses
        },
        allocation: None,
      )
    }
    cli.TraceCalls(..) -> {
      use column <- result.map(
        profile.column_named(found, calltrace_profile.exclusive_column)
        |> result.replace_error(ProbeFailed("the profile has no exclusive time")),
      )

      Measured(
        whole: found,
        column:,
        shown: found,
        samples: model.NoStatuses,
        allocation: None,
      )
    }
    cli.CountAllocation(modules:) -> {
      use column <- result.try(
        profile.column_named(found, allocation_profile.words_column)
        |> result.replace_error(ProbeFailed(
          "the profile has no allocated words",
        )),
      )
      use report <- result.map(allocation_of(
        probe,
        found,
        chosen,
        modules,
        observations,
      ))

      Measured(
        whole: found,
        column:,
        shown: found,
        samples: model.NoStatuses,
        allocation: Some(report),
      )
    }
  }
}

// The allocation report of a finished probe. The facts are what the probe
// kept of what it could and could not read; a probe that finished without
// them is not one this command started, and its numbers would have nothing to
// be read against, so it is a failure and not a report that guesses.
fn allocation_of(
  probe: ProbeRecord,
  found: Profile,
  chosen: profile_scope.Chosen,
  modules: List(String),
  observations: List(Observation),
) -> Result(Report, Failure) {
  case probe.state {
    probe_book.Finished(
      cost: capture.ProbeCost(counters: Some(facts), wall_ms:, ..),
      outcome:,
      ..,
    ) ->
      Ok(allocation_report.Report(
        scope: chosen.sentence,
        probe: probe.id,
        modules:,
        matched: Some(probe.matched),
        facts:,
        observed_ms: wall_ms,
        outcome:,
        word_size: word_size_of(observations),
        rows: allocation_report.rows(found),
      ))
    probe_book.Finished(..) | probe_book.Running ->
      Error(ProbeFailed("the probe kept no allocation facts"))
  }
}

// The size of a word on the target, from the newest census pass that read
// memory. Without one the report shows words and derives no bytes.
fn word_size_of(observations: List(Observation)) -> Option(Int) {
  observations
  |> list.reverse
  |> list.find_map(fn(observation) {
    result.map(observation.memory, fn(memory) { memory.word_size })
  })
  |> option.from_result
}

// Whether the command counted only running and runnable samples and the
// processes had none: every sample was a wait.
fn all_waiting(measured: Measured) -> Bool {
  case measured.samples {
    model.Statuses(inclusion: activity.OnSchedulerOnly, split:, ..) ->
      split.on_scheduler == 0 && split.unstated == 0 && split.waiting > 0
    model.Statuses(inclusion: activity.IncludeWaiting, ..) | model.NoStatuses ->
      False
  }
}

// What was written, and where, for the summary. A text summary with no file
// writes nothing, and neither does a profile of processes that never ran: a
// file of nothing is not a profile, and the capture, which holds every
// sample, is still written.
fn write(
  options: cli.ProfileOptions,
  version: String,
  node: String,
  os_pid: Int,
  remote: Remote,
  probe: ProbeRecord,
  measured: Measured,
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
          [],
        )
        |> result.map_error(WriteFailed),
      )
      use _ <- result.map(
        capture_file.write(path, header, records)
        |> result.map_error(WriteFailed),
      )

      Some(path)
    }
    cli.TextFormat ->
      case measured.allocation, options.out, all_waiting(measured) {
        Some(report), Some(path), _ ->
          to_file(path, allocation_report.render(report, text_rows) <> "\n")
          |> result.map(Some)
        Some(_), None, _ -> Ok(None)
        None, None, _ | None, _, True -> Ok(None)
        None, Some(path), False ->
          text.export(measured.shown, measured.column, text.default_config)
          |> result.replace_error(WriteFailed("the profile has no call stacks"))
          |> result.try(fn(made) { to_file(path, made.body) })
          |> result.map(Some)
      }
    cli.SpeedscopeFormat | cli.CollapsedFormat | cli.ChromeFormat ->
      case all_waiting(measured) {
        True -> Ok(None)
        False -> {
          let choice = case options.format {
            cli.CollapsedFormat -> msg.AsCollapsed
            cli.ChromeFormat -> msg.AsChromeTrace
            _ -> msg.AsSpeedscope
          }

          use built <- result.try(
            profile_export.make(
              choice,
              title,
              span_ms,
              measured.shown,
              measured.column,
              measured.samples,
            )
            |> result.map_error(fn(refused) { WriteFailed(refused.reason) }),
          )
          let path =
            option.lazy_unwrap(options.out, fn() {
              "pickglass-" <> title <> extension(built)
            })

          use _ <- result.map(to_file(path, built.download.body))

          Some(path)
        }
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

/// The text the command prints: what was sampled or traced, the coverage and
/// its caveats, the heaviest functions and where the file went. A text format
/// prints the call tree as well.
fn summary(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  outcome: measure.Outcome,
  notes: List(String),
  measured: Measured,
  written: Option(String),
) -> String {
  case measured.allocation {
    Some(report) -> allocation_summary(report, options.format, written)
    None ->
      sampled_summary(chosen, options, probe, outcome, notes, measured, written)
  }
}

// How many functions the text format lists: every one the agent kept. The
// summary of the other formats lists the fifteen largest.
const text_rows = 200

// An allocation count's summary is its report, and says where the capture
// went and what reads it.
fn allocation_summary(
  report: Report,
  format: cli.ProfileFormat,
  written: Option(String),
) -> String {
  let shown = case format {
    cli.TextFormat -> text_rows
    cli.PgcapFormat
    | cli.SpeedscopeFormat
    | cli.CollapsedFormat
    | cli.ChromeFormat -> 15
  }

  let destination = case written, format {
    Some(path), cli.PgcapFormat ->
      "wrote "
      <> path
      <> " (a capture: pickglass view opens it, and pickglass compare reads it against another)"
    Some(path), _ -> "wrote " <> path
    None, _ -> ""
  }

  string.join([allocation_report.render(report, shown), "", destination], "\n")
}

fn sampled_summary(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  outcome: measure.Outcome,
  notes: List(String),
  measured: Measured,
  written: Option(String),
) -> String {
  let lines = case options.method {
    cli.SampleStacks(..) ->
      stack_lines(chosen, options, probe, outcome, notes, measured)
    cli.TraceCalls(modules:) ->
      call_lines(chosen, options, probe, outcome, notes, measured, modules)
    cli.CountAllocation(..) -> []
  }

  let body = case all_waiting(measured), options.format {
    True, _ -> ""
    False, cli.TextFormat ->
      case text.export(measured.shown, measured.column, text.default_config) {
        Ok(made) -> made.body
        Error(_) -> text.functions(measured.shown, measured.column, 15)
      }
    False, _ -> text.functions(measured.shown, measured.column, 15)
  }

  let destination = case written, options.format {
    Some(path), cli.SpeedscopeFormat ->
      "wrote " <> path <> " (open it at https://www.speedscope.app)"
    Some(path), _ -> "wrote " <> path
    None, _ ->
      case all_waiting(measured), options.format {
        True, cli.PgcapFormat -> ""
        True, _ ->
          "no file was written: no sample caught a process running (--include-waiting writes the waiting samples)"
        False, _ -> ""
      }
  }

  string.join([string.join(lines, "\n"), "", body, destination], "\n")
}

// The summary of a stack profile: how many samples were counted and how the
// whole set split, then the coverage and the caveats.
fn stack_lines(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  outcome: measure.Outcome,
  notes: List(String),
  measured: Measured,
) -> List(String) {
  let counted = profile.total(measured.shown, measured.column)

  list.flatten([
    [
      "profile of " <> chosen.sentence,
      "probe "
        <> probe.id
        <> ": "
        <> int.to_string(counted)
        <> " samples counted over "
        <> int.to_string(options.seconds)
        <> " s, "
        <> ui.truncation_text(outcome),
    ],
    sample_lines(measured),
    [
      "coverage: "
        <> case list.find(notes, string.starts_with(_, "Sampled")) {
        Ok(sampled) -> sampled
        Error(Nil) -> "no coverage note"
      },
      "caveats: sampled at reduction safe points; long BIFs and NIFs are under-counted, and widths are shares of samples, not of time.",
    ],
    list.map(
      list.filter(notes, fn(note) { !string.starts_with(note, "Sampled") }),
      fn(note) { "  " <> note },
    ),
  ])
}

// How the samples split, and which of them the command counted. A profile
// whose processes never ran says so in a sentence of its own.
fn sample_lines(measured: Measured) -> List(String) {
  case measured.samples {
    model.NoStatuses -> []
    model.Statuses(inclusion:, split:, processes:) ->
      list.flatten([
        [
          "samples: "
          <> profile_view.split_text(split)
          <> "; counting "
          <> activity.inclusion_text(inclusion)
          <> case inclusion {
            activity.OnSchedulerOnly -> " (--include-waiting counts the rest)"
            activity.IncludeWaiting -> ""
          },
        ],
        case all_waiting(measured) {
          True -> [profile_view.idle_text(processes)]
          False -> []
        },
      ])
  }
}

// The summary of a call trace: how it ended and what it lost, then the
// caveats the folding carries.
fn call_lines(
  chosen: profile_scope.Chosen,
  options: cli.ProfileOptions,
  probe: ProbeRecord,
  outcome: measure.Outcome,
  notes: List(String),
  measured: Measured,
  modules: List(String),
) -> List(String) {
  let calls = case
    profile.column_named(measured.whole, calltrace_profile.calls_column)
  {
    Ok(column) -> profile.total(measured.whole, column)
    Error(Nil) -> 0
  }

  list.flatten([
    [
      "traced calls of "
        <> string.join(modules, ", ")
        <> " in "
        <> chosen.sentence,
      "probe "
        <> probe.id
        <> ": "
        <> int.to_string(calls)
        <> " calls over "
        <> int.to_string(list.length(profile.functions(measured.whole)))
        <> " functions in "
        <> int.to_string(options.seconds)
        <> " s, "
        <> ui.truncation_text(outcome),
    ],
    list.map(notes, fn(note) { "  " <> note }),
  ])
}
