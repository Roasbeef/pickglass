//// The requests a page's application sends, resolved against the viewer's
//// data: the filter chain, exports, baselines, compared captures, and the
//// probe controls.

import fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import harness
import pickglass/capture_build
import pickglass/capture_file
import pickglass/downloads
import pickglass/feeds
import pickglass/probe_book
import pickglass/profile_from_stacks.{Frame, Stack}
import pickglass/seam
import pickglass/service
import pickglass/web_mount
import pickglass_core/analysis/transform
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/layout/flame
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/provenance
import pickglass_core/wire
import pickglass_web/chart/flame as flame_chart
import pickglass_web/key
import pickglass_web/model
import pickglass_web/msg
import simplifile

fn frame(name: String) -> profile_from_stacks.Frame {
  Frame("loom@runtime", name, 1, None, None)
}

// A finished sampling probe with a profile of three stacks.
fn sampled() -> probe_book.ProbeRecord {
  let assert Ok(built) =
    profile_from_stacks.build(
      profile_from_stacks.Aggregated(
        method: "process_info current_stacktrace",
        rate_hz: 50,
        depth_limit: 16,
        completeness: profile_from_stacks.AllStacks,
        stacks: [
          Stack(
            [frame("leaf"), frame("mid"), frame("root")],
            6,
            Some("running"),
          ),
          Stack(
            [frame("other"), frame("mid"), frame("root")],
            3,
            Some("running"),
          ),
          Stack([frame("lone"), frame("root")], 1, Some("running")),
        ],
      ),
    )

  probe_book.ProbeRecord(
    id: "9",
    kind: policy.Sampling,
    modules: [],
    started_ms: 1000,
    duration_ms: 10_000,
    matched: 0,
    state: probe_book.Finished(
      ended_ms: 11_000,
      outcome: measure.Complete,
      cost: capture.ProbeCost(
        probe: "9",
        enabled: ["current_stacktrace"],
        events: measure.NotApplicable,
        collector_reductions: measure.NotApplicable,
        bytes: measure.NotApplicable,
        wall_ms: measure.Known(10_000),
        outcome: measure.Complete,
        matched: Some(1),
      ),
      profile: Some(built),
      notes: [],
    ),
    detail: probe_book.NoDetail,
  )
}

fn state_on(page: seam.Page, slug: String) -> web_mount.State {
  let assert Ok(state) = web_mount.new_state(page, slug, 0)

  state
}

fn profile_rig(grants: List(policy.Capability)) -> #(harness.Rig, seam.Page) {
  let rig =
    harness.replay_with([fixture.observation(0, 1000)], [sampled()], None)

  #(rig, harness.page(rig, "alice", grants))
}

fn drawn(state: web_mount.State) -> model.ProfileModel {
  let assert Ok(found) =
    list.find_map(web_mount.fed(state), fn(feed) {
      case feed {
        msg.FedProfile(data) -> Ok(data)
        _ -> Error(Nil)
      }
    })

  found
}

pub fn a_typed_filter_changes_the_chain_and_the_totals_test() {
  let #(_, page) = profile_rig(harness.all)
  let state = state_on(page, "profile")

  assert drawn(state).chain == []

  let state = web_mount.ask(state, msg.AddFilter(msg.FocusFilter, "mid"))
  let data = drawn(state)
  let assert [report] = data.chain

  assert report.total_before == 10
  assert report.total_after == 9
  assert web_mount.chain_of(state) != []
}

pub fn focus_here_builds_the_step_from_the_function_behind_the_key_test() {
  let #(_, page) = profile_rig(harness.all)
  let state = state_on(page, "profile")
  let assert model.HasStacks(layout:, ..) = drawn(state).stacks
  let assert Ok(leaf_box) =
    list.find(layout.boxes, fn(box) {
      case box.frame {
        flame.Function(id:) ->
          profile.name_of(drawn(state).profile, id) == "loom@runtime:leaf/1"
        _ -> False
      }
    })

  let state =
    web_mount.ask(
      state,
      msg.AddFilterAt(msg.FocusFilter, flame_chart.box_key(leaf_box)),
    )

  // The pattern is an exact match on the function the viewer drew, so no
  // function name came from the browser.
  assert web_mount.chain_of(state)
    == [transform.Focus(pattern: "^loom@runtime:leaf/1$")]
  assert { drawn(state).chain |> list.length } == 1
}

pub fn a_key_the_profile_never_drew_adds_no_step_test() {
  let #(_, page) = profile_rig(harness.all)
  let state =
    web_mount.ask(
      state_on(page, "profile"),
      msg.AddFilterAt(msg.FocusFilter, key.make("box.forged")),
    )

  assert web_mount.chain_of(state) == []
}

pub fn truncating_keeps_the_steps_before_the_index_test() {
  let #(_, page) = profile_rig(harness.all)
  let state =
    state_on(page, "profile")
    |> web_mount.ask(msg.AddFilter(msg.FocusFilter, "root"))
    |> web_mount.ask(msg.AddFilter(msg.HideFilter, "mid"))
    |> web_mount.ask(msg.AddFilter(msg.IgnoreFilter, "lone"))

  assert list.length(web_mount.chain_of(state)) == 3
  assert list.length(
      web_mount.chain_of(web_mount.ask(state, msg.TruncateChain(1))),
    )
    == 1
  assert web_mount.chain_of(web_mount.ask(state, msg.TruncateChain(0))) == []
}

pub fn the_chain_is_the_pages_own_test() {
  let #(_, page) = profile_rig(harness.all)
  let first = state_on(page, "profile")
  let second = state_on(page, "profile")
  let first = web_mount.ask(first, msg.AddFilter(msg.FocusFilter, "mid"))

  assert web_mount.chain_of(first) != []
  assert web_mount.chain_of(second) == []
}

fn ready(state: web_mount.State) -> model.ExportNote {
  let assert [note, ..] = web_mount.exports_of(state)

  note
}

pub fn an_export_is_a_one_time_download_of_the_filtered_profile_test() {
  let #(rig, page) = profile_rig(harness.all)
  let state =
    state_on(page, "profile")
    |> web_mount.ask(msg.AddFilter(msg.IgnoreFilter, "lone"))
    |> web_mount.ask(msg.ExportProfile(msg.AsCollapsed))
  let assert model.ExportReady(label:, ticket:, losses:) = ready(state)

  assert label == "Collapsed stacks"
  assert losses != []

  let assert Ok(file) =
    service.take_download(rig.service, key.to_string(ticket))

  // The `lone` stack was filtered out, so the file has two lines and the
  // counts are the filtered ones.
  assert file.file_name == "probe-9.collapsed"
  assert string.contains(
    file.body,
    "loom@runtime:root/1;loom@runtime:mid/1;loom@runtime:leaf/1 6",
  )
  assert !string.contains(file.body, "lone")

  // The ticket was consumed by the first fetch.
  assert service.take_download(rig.service, key.to_string(ticket))
    == Error(downloads.UnknownTicket)
}

pub fn the_other_formats_are_offered_too_test() {
  let #(rig, page) = profile_rig(harness.all)
  let state =
    state_on(page, "profile")
    |> web_mount.ask(msg.ExportProfile(msg.AsSpeedscope))
    |> web_mount.ask(msg.ExportProfile(msg.AsChromeTrace))
  let assert [
    model.ExportReady(label: trace, ticket: trace_ticket, ..),
    model.ExportReady(label: speed, ticket: speed_ticket, ..),
  ] = web_mount.exports_of(state)

  assert trace == "Chrome trace"
  assert speed == "Speedscope"

  let assert Ok(speedscope) =
    service.take_download(rig.service, key.to_string(speed_ticket))
  let assert Ok(chrome) =
    service.take_download(rig.service, key.to_string(trace_ticket))

  assert string.contains(speedscope.body, "speedscope")
  assert string.contains(chrome.body, "traceEvents")
}

pub fn a_format_that_needs_stacks_is_refused_for_counters_with_a_reason_test() {
  // A probe closed with a counters snapshot, as the service's poll does.
  let counters_rig =
    harness.replay_with(
      [fixture.observation(0, 1000)],
      [counters_probe()],
      None,
    )
  let state =
    state_on(harness.page(counters_rig, "alice", harness.all), "profile")
    |> web_mount.ask(msg.ExportProfile(msg.AsCollapsed))
    |> web_mount.ask(msg.ExportProfile(msg.AsChromeTrace))
  let assert [
    model.ExportReady(label: "Chrome trace", ..),
    model.ExportRefused(label: "Collapsed stacks", reason:),
  ] = web_mount.exports_of(state)

  assert string.contains(reason, "no call stacks (traced counters)")
}

fn counters_probe() -> probe_book.ProbeRecord {
  probe_book.finish_counters(
    probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2),
    wire.CountersSnapshot(
      probe_id: 7,
      state: wire.ProbeFinished,
      matched_functions: 2,
      elapsed_ms: 30_000,
      functions: 2,
      with_calls: 1,
      invalidated: 0,
      rows: [wire.FunctionRow("lists", "map", 2, 10, 5)],
    ),
    31_000,
  )
}

pub fn an_export_without_the_capability_is_refused_in_words_test() {
  let #(_, page) = profile_rig([policy.Observe])
  let state =
    state_on(page, "profile")
    |> web_mount.ask(msg.ExportProfile(msg.AsSpeedscope))

  let assert model.ExportRefused(label: "Speedscope", reason:) = ready(state)

  assert string.contains(reason, "missing capability export")
}

pub fn choosing_a_checkpoint_changes_what_the_page_compares_against_test() {
  let rig = harness.replay([fixture.observation(0, 1000)], None)
  let page = harness.page(rig, "alice", harness.all)
  let _ = page.submit(seam.Checkpoint("one"))
  let _ = page.submit(seam.Checkpoint("two"))
  let state = state_on(page, "overview")

  assert web_mount.baseline_of(state) == None

  let state = web_mount.ask(state, msg.ChooseBaseline(feeds.checkpoint_key(0)))

  assert web_mount.baseline_of(state) == Some(0)

  // A key that names no checkpoint changes nothing.
  assert web_mount.baseline_of(web_mount.ask(
      state,
      msg.ChooseBaseline(key.make("cp.9")),
    ))
    == Some(0)
}

pub fn taking_a_checkpoint_resets_the_page_to_the_newest_test() {
  let rig = harness.replay([fixture.observation(0, 1000)], None)
  let page = harness.page(rig, "alice", harness.all)
  let _ = page.submit(seam.Checkpoint("one"))
  let state =
    state_on(page, "overview")
    |> web_mount.ask(msg.ChooseBaseline(feeds.checkpoint_key(0)))
    |> web_mount.ask(msg.TakeCheckpoint(""))

  assert web_mount.baseline_of(state) == None
  assert list.length(page.checkpoints()) == 2
}

fn save_capture(dir: String, workload: String, total_seq: Int) -> String {
  let facts =
    capture_build.Facts(
      pickglass_version: "test",
      node: "fake@127.0.0.1",
      os_pid: 1,
      boot: fixture.boot(),
      role: "loomd",
      workload:,
      top_k: 200,
      deadline_ms: 15_000,
      os_start: identity.UnreadableStart,
      clock: None,
    )
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts,
      "cap-" <> workload,
      [fixture.observation(total_seq, 1000)],
      measure.EveryMs(2000),
      [],
      [],
      [],
      [],
    )
  let path = dir <> "/" <> workload <> ".pgcap"
  let assert Ok(Nil) = capture_file.write(path, header, records)

  path
}

pub fn two_chosen_captures_are_read_and_compared_test() {
  let dir = "build/mount_test_out"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let first = save_capture(dir, "idle", 0)
  let second = save_capture(dir, "busy", 5)
  let rig =
    harness.replay(
      [fixture.observation(0, 1000)],
      Some(service.Saver(directory: dir, facts: facts(), cadence_ms: 2000)),
    )
  let page = harness.page(rig, "alice", harness.all)
  let state = state_on(page, "compare")

  let state =
    state
    |> web_mount.ask(msg.ChooseBaseline(feeds.capture_key("idle.pgcap")))

  // One file chosen is not a comparison.
  assert web_mount.comparison_of(state) == None

  let state =
    web_mount.ask(state, msg.ChooseCandidate(feeds.capture_key("busy.pgcap")))
  let assert Some(Ok(page_model)) = web_mount.comparison_of(state)

  assert page_model.baseline_name == "idle.pgcap"
  assert page_model.candidate_name == "busy.pgcap"

  // The two were taken for different workloads, which core says blocks a
  // verdict.
  assert list.contains(
    provenance.blocking_fields(provenance.comparability(
      page_model.baseline,
      page_model.candidate,
    )),
    provenance.WorkloadField,
  )

  // The page is fed both the offers and the comparison.
  assert list.any(web_mount.fed(state), fn(feed) {
    case feed {
      msg.FedCompare(_) -> True
      _ -> False
    }
  })

  let _ = simplifile.delete(first)
  let _ = simplifile.delete(second)
}

fn facts() -> capture_build.Facts {
  capture_build.Facts(
    pickglass_version: "test",
    node: "fake@127.0.0.1",
    os_pid: 1,
    boot: fixture.boot(),
    role: "loomd",
    workload: "",
    top_k: 200,
    deadline_ms: 15_000,
    os_start: identity.UnreadableStart,
    clock: None,
  )
}

pub fn a_capture_the_viewer_does_not_offer_is_not_read_test() {
  let dir = "build/mount_test_out_two"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let rig =
    harness.replay(
      [fixture.observation(0, 1000)],
      Some(service.Saver(directory: dir, facts: facts(), cadence_ms: 2000)),
    )
  let state =
    state_on(harness.page(rig, "alice", harness.all), "compare")
    |> web_mount.ask(msg.ChooseBaseline(feeds.capture_key("../etc/passwd")))

  assert web_mount.comparison_of(state) == None
}

pub fn a_file_that_is_not_a_capture_is_a_stated_failure_test() {
  let dir = "build/mount_test_out_three"
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
  let assert Ok(Nil) = simplifile.write(dir <> "/bad.pgcap", "not a capture")
  let good = save_capture(dir, "good", 0)
  let rig =
    harness.replay(
      [fixture.observation(0, 1000)],
      Some(service.Saver(directory: dir, facts: facts(), cadence_ms: 2000)),
    )
  let state =
    state_on(harness.page(rig, "alice", harness.all), "compare")
    |> web_mount.ask(msg.ChooseBaseline(feeds.capture_key("bad.pgcap")))
    |> web_mount.ask(msg.ChooseCandidate(feeds.capture_key("good.pgcap")))
  let assert Some(Error(reason)) = web_mount.comparison_of(state)

  assert string.contains(reason, "not a readable capture")

  let _ = simplifile.delete(good)
}

pub fn a_running_probe_is_stopped_by_its_key_test() {
  let rig = harness.live(fixture.healthy_with_open_probe, None)
  let page = harness.page(rig, "alice", harness.all)
  let assert seam.PinIssued(token, _) = page.submit(seam.PinProcess("<0.5.0>"))
  let assert seam.PlanReady(id, _) =
    page.submit(seam.PlanProbe(policy.Counters, [token], ["lists"], 30_000, 0))
  let assert seam.ProbeStarted(..) = page.submit(seam.ConfirmPlan(id))
  let state = state_on(page, "probes")

  // A key that is not a running probe does nothing.
  let _ = web_mount.ask(state, msg.StopProbe(feeds.probe_key("99")))

  assert list.all(fixture.drain(rig.seen, 50), fn(request) {
    request != wire.AskStopCounters(99)
  })

  let _ = web_mount.ask(state, msg.StopProbe(feeds.probe_key("7")))

  assert list.contains(fixture.drain(rig.seen, 100), wire.AskStopCounters(7))
}

pub fn a_typed_checkpoint_name_is_kept_and_an_empty_one_is_numbered_test() {
  let rig = harness.replay([fixture.observation(0, 1000)], None)
  let page = harness.page(rig, "alice", harness.all)
  let _ =
    state_on(page, "overview")
    |> web_mount.ask(msg.TakeCheckpoint("idle-0"))
    |> web_mount.ask(msg.TakeCheckpoint("  "))

  let names = list.map(page.checkpoints(), fn(mark) { mark.checkpoint.name })

  assert names == ["idle-0", "checkpoint-2"]
}

pub fn detaching_from_the_page_loses_the_target_and_says_so_test() {
  let rig = harness.live(fixture.healthy, None)
  let page = harness.page(rig, "alice", harness.all)

  assert page.lost() == None

  let state = web_mount.ask(state_on(page, "overview"), msg.DetachViewer)

  assert web_mount.refusal_of(state) == None
  assert page.lost() == Some("you detached it")
}
