//// What the service keeps for the pages: probes and their profiles,
//// checkpoints with their baselines, one-time downloads, and the capture
//// files the compare page offers.

import fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/capture_build
import pickglass/capture_file
import pickglass/downloads
import pickglass/probe_book
import pickglass/remote
import pickglass/seam
import pickglass/service
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/wire
import simplifile

fn counters(state: wire.ProbeState) -> wire.CountersSnapshot {
  wire.CountersSnapshot(
    probe_id: 7,
    state:,
    matched_functions: 3,
    elapsed_ms: 30_004,
    functions: 3,
    with_calls: 2,
    invalidated: 0,
    rows: [
      wire.FunctionRow("lists", "map", 2, 10, 5),
      wire.FunctionRow("lists", "foldl", 3, 4, 9),
    ],
  )
}

// A healthy agent whose probe has already run to its deadline when it is
// read, so the service's poll finds it ended.
fn ended(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.AskReadCounters(7) ->
      Ok(wire.CountersReport(counters(wire.ProbeFinished)))
    wire.AskStopCounters(7) ->
      Ok(wire.CountersReport(counters(wire.ProbeStopped)))
    other -> fixture.healthy(other)
  }
}

fn start_probe(page: seam.Page) -> Nil {
  let assert seam.PinIssued(token, _) = page.submit(seam.PinProcess("<0.5.0>"))
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(policy.Counters, [token], ["lists"], 30_000))
  let assert seam.ProbeStarted("7", 3) = page.submit(seam.ConfirmPlan(id))

  Nil
}

fn facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 1,
    boot: fixture.boot(),
    role: "test",
    workload: "",
    top_k: 10,
    deadline_ms: 1000,
    os_start: identity.UnreadableStart,
    clock: None,
  )
}

pub fn a_started_probe_is_recorded_as_running_test() {
  let rig = harness.live(fixture.healthy_with_open_probe, None)
  let page = harness.page(rig, "alice", harness.all)

  start_probe(page)

  let assert [probe] = page.probes()

  assert probe.id == "7"
  assert probe.kind == policy.Counters
  assert probe.modules == ["lists"]
  assert probe.matched == 3
  assert probe_book.is_running(probe)
}

pub fn an_ended_probe_is_taken_into_a_profile_before_the_agent_forgets_it_test() {
  let rig = harness.live(ended, None)
  let page = harness.page(rig, "alice", harness.all)

  start_probe(page)

  // The service asks once a second whether a running probe has ended.
  let assert Ok(done) = wait_for_profile(page, 30)
  let assert probe_book.Finished(profile: Some(found), ..) = done.state

  assert profile.source(found) == profile.TracedCounters

  // The agent was told to release the ended probe.
  assert list.contains(fixture.drain(rig.seen, 50), wire.AskStopCounters(7))
}

fn wait_for_profile(
  page: seam.Page,
  attempts: Int,
) -> Result(probe_book.ProbeRecord, Nil) {
  case probe_book.latest_profiled(page.probes()) {
    Ok(#(probe, _)) -> Ok(probe)
    Error(Nil) ->
      case attempts {
        0 -> Error(Nil)
        _ -> {
          sleep(100)

          wait_for_profile(page, attempts - 1)
        }
      }
  }
}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

pub fn stopping_a_probe_closes_its_record_with_the_last_snapshot_test() {
  let rig = harness.live(ended, None)
  let page = harness.page(rig, "alice", harness.all)

  start_probe(page)

  let assert seam.ProbeStopped(snapshot) = page.submit(seam.StopProbe("7"))

  assert snapshot.probe_id == 7

  let assert [probe] = page.probes()

  assert !probe_book.is_running(probe)
}

pub fn a_probe_the_agent_forgot_is_closed_as_lost_test() {
  // The plain healthy agent answers a read with `no_such_probe`.
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)

  start_probe(page)
  sleep(1500)

  let assert [probe] = page.probes()
  let assert probe_book.Finished(outcome:, profile: None, ..) = probe.state

  assert string.contains(string.inspect(outcome), "no_such_probe")
}

pub fn a_checkpoint_needs_only_observe_and_keeps_the_newest_observation_test() {
  let rig =
    harness.replay(
      [fixture.observation(0, 1000), fixture.observation(1, 3000)],
      None,
    )
  let observer = harness.page(rig, "viewer", [policy.Observe])

  assert observer.submit(seam.Checkpoint("before"))
    == seam.Done("checkpoint recorded")

  let assert [mark] = observer.checkpoints()
  let assert Some(baseline) = mark.baseline

  assert mark.checkpoint.name == "before"
  assert baseline.seq == 1
  assert list.any(harness.trail(rig), fn(line) {
    string.contains(line, "checkpoint name=before")
  })
}

pub fn a_page_that_may_not_observe_cannot_take_a_checkpoint_test() {
  let rig = harness.replay([fixture.observation(0, 1000)], None)
  let nobody = harness.page(rig, "nobody", [policy.Export])

  assert string.contains(
    rejected(nobody.submit(seam.Checkpoint("x"))),
    "missing capability observe",
  )
  assert nobody.checkpoints() == []
}

fn rejected(reply: seam.Reply) -> String {
  let assert seam.Rejected(reason) = reply

  reason
}

fn offered() -> downloads.Download {
  downloads.Download(
    file_name: "probe-7.collapsed",
    content_type: "text/plain",
    body: "a;b 3\n",
  )
}

pub fn an_export_is_a_download_that_can_be_fetched_once_test() {
  let rig = harness.live(ended, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.DownloadReady(ticket) =
    page.submit(seam.ExportProfile("7", policy.CollapsedStacks, offered()))

  assert service.take_download(rig.service, ticket) == Ok(offered())
  assert service.take_download(rig.service, ticket)
    == Error(downloads.UnknownTicket)
  assert list.any(harness.trail(rig), fn(line) {
    string.contains(line, "export_capture capture=probe-7 format=collapsed")
  })
}

pub fn an_export_needs_the_export_capability_test() {
  let rig = harness.live(ended, None)
  let page = harness.page(rig, "reader", [policy.Observe])

  assert string.contains(
    rejected(page.submit(seam.ExportProfile("7", policy.Speedscope, offered()))),
    "missing capability export",
  )
}

pub fn a_made_up_ticket_gets_nothing_test() {
  let rig = harness.live(ended, None)

  assert service.take_download(rig.service, "forged")
    == Error(downloads.UnknownTicket)
}

pub fn saved_captures_are_offered_and_read_back_with_their_probes_test() {
  let dir = "build/service_feeds_test_out"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let rig =
    harness.live(
      ended,
      Some(service.Saver(directory: dir, facts: facts(), cadence_ms: 2000)),
    )
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.PinIssued(_, _) = page.submit(seam.PinProcess("<0.5.0>"))

  // A pass so the capture has a memory report to describe the runtime.
  let assert Ok(Nil) = collect_a_pass(rig)

  start_probe(page)

  let assert Ok(_) = wait_for_profile(page, 30)
  let assert seam.CaptureSaved(path) = page.submit(seam.SaveCapture)
  let assert Ok(loaded) = capture_file.read(path)

  // The probe's profile and its cost are in the file.
  assert list.any(loaded.capture.records, fn(record) {
    case record {
      capture.ProfileRecord(_) -> True
      _ -> False
    }
  })
  assert list.any(loaded.capture.records, fn(record) {
    case record {
      capture.ProbeCostRecord(_) -> True
      _ -> False
    }
  })

  // The file is offered by name, and only by a name the listing holds.
  let name = file_name(path)

  assert list.contains(page.captures(), name)
  assert page.read_capture(name) |> is_ok
  assert page.read_capture("../escape.pgcap") |> is_ok == False

  let blind = harness.page(rig, "blind", [policy.Export])

  assert blind.captures() == []
  let _ = simplifile.delete(path)
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn file_name(path: String) -> String {
  let assert Ok(name) = list.last(string.split(path, "/"))

  name
}

fn collect_a_pass(rig: harness.Rig) -> Result(Nil, Nil) {
  let page = harness.page(rig, "collector", harness.all)
  let updates = fixture.updates()

  let assert Ok(Nil) = page.subscribe(updates)
  sleep(300)

  case page.latest() {
    [] -> Error(Nil)
    _ -> Ok(Nil)
  }
}
