import gleam/list
import gleam/option.{None, Some}
import pickglass/probe_book
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/wire

fn snapshot(state: wire.ProbeState, invalidated: Int) -> wire.CountersSnapshot {
  wire.CountersSnapshot(
    probe_id: 7,
    state:,
    matched_functions: 2,
    elapsed_ms: 30_004,
    functions: 2,
    with_calls: 1,
    invalidated:,
    rows: [wire.FunctionRow("lists", "map", 2, 10, 5)],
  )
}

fn running() -> probe_book.ProbeRecord {
  probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 2)
}

pub fn a_started_probe_runs_and_counts_down_test() {
  let probe = running()

  assert probe_book.is_running(probe)
  assert probe_book.remaining_ms(probe, 11_000) == 20_000
  assert probe_book.remaining_ms(probe, 99_000) == 0
}

pub fn finishing_takes_the_result_into_a_profile_test() {
  let done =
    probe_book.finish_counters(
      running(),
      snapshot(wire.ProbeFinished, 0),
      31_000,
    )
  let assert probe_book.Finished(outcome:, cost:, profile: Some(found), ..) =
    done.state

  assert !probe_book.is_running(done)
  assert outcome == measure.Complete
  assert cost.wall_ms == measure.Known(30_004)
  assert cost.events == measure.NotApplicable
  assert profile.source(found) == profile.TracedCounters
  assert probe_book.remaining_ms(done, 5000) == 0
}

pub fn invalidated_functions_make_the_snapshot_suspect_test() {
  let done =
    probe_book.finish_counters(
      running(),
      snapshot(wire.ProbeFinished, 2),
      31_000,
    )
  let assert probe_book.Finished(notes:, ..) = done.state

  assert list.any(notes, fn(note) {
    note
    == "2 traced functions were invalidated by a module reload; this snapshot is suspect."
  })
}

pub fn a_lost_probe_has_a_reason_and_no_profile_test() {
  let lost = probe_book.finish_lost(running(), "the target went away", 5000)
  let assert probe_book.Finished(outcome:, profile:, cost:, ..) = lost.state

  assert outcome == measure.Errored("the target went away")
  assert profile == None
  assert cost.wall_ms == measure.Missing(measure.ProcessExited)
}

pub fn the_latest_profiled_probe_skips_lost_and_running_ones_test() {
  let good =
    probe_book.finish_counters(
      probe_book.started(5, policy.Counters, [], 0, 1, 1),
      snapshot(wire.ProbeFinished, 0),
      10,
    )
  let lost = probe_book.finish_lost(running(), "gone", 20)

  let assert Ok(#(found, _)) =
    probe_book.latest_profiled([running(), lost, good])

  assert found.id == "5"
  assert probe_book.latest_profiled([running(), lost]) == Error(Nil)
}

pub fn finished_probes_survive_a_capture_round_trip_test() {
  let done =
    probe_book.finish_counters(
      running(),
      snapshot(wire.ProbeFinished, 0),
      31_000,
    )
  let records = probe_book.to_records([running(), done])

  // The probe that was still running is not a capture's business.
  assert list.length(records) == 2

  let assert [back] = probe_book.of_records(records)
  let assert probe_book.Finished(profile: Some(found), cost:, ..) = back.state
  let assert probe_book.Finished(
    profile: Some(original),
    cost: original_cost,
    ..,
  ) = done.state

  assert back.id == "7"
  assert back.kind == policy.Counters
  assert found == original
  assert cost == original_cost
  assert cost.probe == original_cost.probe
}

pub fn the_bound_drops_the_oldest_finished_probes_and_never_a_running_one_test() {
  // Newest first: a running probe, then three finished ones, the oldest
  // finished one last, and an old probe that is still running.
  let finished = fn(id) {
    probe_book.finish_lost(
      probe_book.started(id, policy.Counters, ["lists"], 1000, 30_000, 2),
      "gone",
      2000,
    )
  }
  let probes = [
    probe_book.started(9, policy.Counters, ["lists"], 1000, 30_000, 2),
    finished(8),
    finished(7),
    finished(6),
    probe_book.started(5, policy.Counters, ["lists"], 1000, 30_000, 2),
  ]
  let #(kept, dropped) = probe_book.bound(probes, 2)

  assert list.map(kept, fn(probe) { probe.id }) == ["9", "8", "7", "5"]
  assert dropped == 1
  assert probe_book.bound(probes, 3) == #(probes, 0)
}
