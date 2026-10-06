//// Comparing two captures: provenance decides whether a direction may be
//// stated, and the figures are the newest reading of each.

import fixture
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass/capture_build
import pickglass/capture_file
import pickglass/compare_build
import pickglass/compare_report
import pickglass/observation.{Observation}
import pickglass/probe_book
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{Known, Missing}
import pickglass_core/policy
import pickglass_core/provenance
import pickglass_core/wire
import pickglass_web/model

fn facts(workload: String) -> capture_build.Facts {
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
}

fn capture(
  workload: String,
  observations: List(observation.Observation),
) -> capture_file.Loaded {
  capture_with(workload, observations, [])
}

fn capture_with(
  workload: String,
  observations: List(observation.Observation),
  probes: List(probe_book.ProbeRecord),
) -> capture_file.Loaded {
  let assert Ok(#(header, records)) =
    capture_build.assemble(
      facts(workload),
      "cap-" <> workload,
      observations,
      measure.EveryMs(2000),
      [],
      [],
      probes,
      [],
    )
  let assert Ok(text) = capture_file.render(header, records)
  let assert Ok(loaded) = capture_file.parse(text)

  loaded
}

fn passes(total: Int) -> List(observation.Observation) {
  [
    fixture.observation(0, 1000),
    Observation(
      ..fixture.observation(1, 3000),
      memory: Ok(fixture.memory(total)),
    ),
  ]
}

// Three passes that all read `total`, so the figure did not vary.
fn steady(total: Int) -> List(observation.Observation) {
  list.map([0, 1, 2], fn(index) {
    Observation(
      ..fixture.observation(index, 1000 + 2000 * index),
      memory: Ok(fixture.memory(total)),
    )
  })
}

pub fn a_workload_mismatch_blocks_a_verdict_test() {
  let assert Ok(page) =
    compare_build.build(
      "idle.pgcap",
      capture("idle", passes(1_000_000)),
      "busy.pgcap",
      capture("busy", passes(2_000_000)),
    )
  let comparability = provenance.comparability(page.baseline, page.candidate)

  assert list.contains(
    provenance.blocking_fields(comparability),
    provenance.WorkloadField,
  )

  // The figures are still there, and each is withheld by core, not by us.
  let assert Ok(total) =
    list.find(page.rows, fn(row) { row.label == "memory: total" })

  assert total.baseline == Known(1_000_000)
  assert total.candidate == Known(2_000_000)
  assert provenance.compare_measurements(
      comparability,
      total.kind,
      total.baseline,
      total.candidate,
    )
    == provenance.Withheld(blocking: [provenance.WorkloadField])
}

pub fn matching_captures_are_comparable_and_a_direction_is_allowed_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture("idle", passes(1_000_000)),
      "b.pgcap",
      capture("idle", passes(2_000_000)),
    )
  let comparability = provenance.comparability(page.baseline, page.candidate)

  assert provenance.blocking_fields(comparability) == []

  let assert Ok(total) =
    list.find(page.rows, fn(row) { row.label == "memory: total" })

  assert provenance.compare_measurements(
      comparability,
      total.kind,
      total.baseline,
      total.candidate,
    )
    == provenance.Moved(provenance.Increased)
}

pub fn a_reading_a_capture_does_not_hold_is_a_word_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture("idle", passes(1_000_000)),
      "b.pgcap",
      capture("idle", passes(1_000_000)),
    )
  let assert Ok(os) =
    list.find(page.rows, fn(row) { row.label == "OS resident set (target)" })

  // Neither capture has OS readings; that is a word, never a zero.
  assert os.baseline == Missing(measure.CounterDisabled)
  assert os.candidate == Missing(measure.CounterDisabled)
  assert page.diff == None
}

pub fn the_figures_of_one_capture_are_listed_for_the_command_line_test() {
  let assert Ok(figures) =
    compare_build.figures(capture("idle", passes(1_000_000)))

  assert list.key_find(figures, "process count") == Ok(Known(12))
  assert list.key_find(figures, "memory: total") == Ok(Known(1_000_000))
}

pub fn the_text_report_names_the_blocking_field_and_withholds_directions_test() {
  let assert Ok(page) =
    compare_build.build(
      "idle.pgcap",
      capture("idle", passes(1_048_576 * 10)),
      "busy.pgcap",
      capture("busy", passes(1_048_576 * 20)),
    )
  let text = compare_report.render(page, "footer digest verified", "no footer")

  assert string.contains(text, "baseline:  idle.pgcap (footer digest verified)")
  assert string.contains(text, "candidate: busy.pgcap (no footer)")
  assert string.contains(text, "workload  differs, blocks:")
  assert string.contains(
    text,
    "verdict: MISMATCH, workload block a statement of direction",
  )

  // The figure is shown, and its direction is withheld by core.
  assert string.contains(text, "10.0 MiB")
  assert string.contains(text, "20.0 MiB")
  assert string.contains(text, "withheld (workload)")
  assert !string.contains(text, "higher")
}

pub fn matching_captures_state_a_direction_in_the_text_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture("idle", steady(1_048_576 * 10)),
      "b.pgcap",
      capture("idle", steady(1_048_576 * 20)),
    )
  let text = compare_report.render(page, "x", "y")

  assert string.contains(text, "verdict: comparable")
  assert string.contains(text, "  higher")
  assert !string.contains(text, "within variation")
}

// The captures' own passes show memory swinging by more than the difference
// between them, so no direction is stated and the band is printed.
pub fn a_difference_inside_the_variation_seen_states_no_direction_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture("idle", passes(1_048_576 * 10)),
      "b.pgcap",
      capture("idle", passes(1_048_576 * 20)),
    )
  let text = compare_report.render(page, "x", "y")
  let assert Ok(total) =
    list.find(page.rows, fn(row) { row.label == "memory: total" })

  assert total.baseline_band
    == Some(provenance.Band(low: 1_000_000, high: 1_048_576 * 10))
  assert string.contains(text, "within variation")
  assert string.contains(text, "varied inside each capture")
  assert !string.contains(text, "  higher")
}

// A sampled-stacks probe that ran at `hz`, with the same two stacks and
// `samples` samples spread over them.
fn sampled(hz: Int, samples: Int) -> probe_book.ProbeRecord {
  probe_book.started(11, policy.Sampling, [], 0, 10_000, 1, 1)
  |> probe_book.finish_stacks(sampled_snapshot(hz, samples), 1000)
}

fn sampled_snapshot(hz: Int, samples: Int) -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 11,
    state: wire.ProbeFinished,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: hz,
      achieved_millihz: hz * 1000,
      rounds: samples,
      samples:,
      elapsed_ms: 1000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 2,
      truncated_samples: 0,
    ),
    frames: [
      wire.StackFrame("m", "leaf", 1, wire.NoLocation),
      wire.StackFrame("m", "root", 1, wire.NoLocation),
    ],
    stacks: [
      wire.SampledStack(samples * 7 / 10, "running", [0, 1]),
      wire.SampledStack(samples * 3 / 10, "waiting", [1]),
    ],
  )
}

pub fn probes_sampled_at_different_rates_get_no_verdict_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture_with("idle", passes(1_000_000), [sampled(50, 500)]),
      "b.pgcap",
      capture_with("idle", passes(1_000_000), [sampled(100, 1000)]),
    )
  let assert Some(flame) = page.diff

  assert flame.sources
    == model.DifferentSources(
      "process_info current_stacktrace at 50 Hz",
      "process_info current_stacktrace at 100 Hz",
    )
}

pub fn a_longer_probe_at_the_same_rate_is_scaled_not_called_growth_test() {
  let assert Ok(page) =
    compare_build.build(
      "a.pgcap",
      capture_with("idle", passes(1_000_000), [sampled(50, 500)]),
      "b.pgcap",
      capture_with("idle", passes(1_000_000), [sampled(50, 1500)]),
    )
  let assert Some(flame) = page.diff

  assert flame.sources == model.SameSource

  // The same shape three times as long: every stack cancels once the
  // candidate is scaled to the baseline's total, so nothing is drawn as
  // grown. Unscaled, every box would be red.
  assert flame.layout.boxes == []
}

fn replayed(probe: probe_book.ProbeRecord) -> probe_book.ProbeRecord {
  let loaded = capture_with("idle", passes(1_000_000), [probe])
  let assert [found] = probe_book.of_records(loaded.capture.records)

  found
}

pub fn a_probe_read_from_a_capture_keeps_how_it_ended_test() {
  let cut =
    probe_book.started(11, policy.Sampling, [], 0, 10_000, 4, 1)
    |> probe_book.finish_stacks(
      wire.StacksSnapshot(
        ..sampled_snapshot(50, 500),
        stop: wire.SamplingBudget,
      ),
      1000,
    )
  let found = replayed(cut)
  let assert probe_book.Finished(outcome:, ..) = found.state

  assert outcome == measure.Partial(measure.Truncated(measure.BudgetReached))
  assert found.matched == 4
}

pub fn a_probe_from_a_capture_without_an_outcome_is_not_called_complete_test() {
  let unrecorded =
    probe_book.ProbeRecord(..sampled(50, 500), state: {
      let assert probe_book.Finished(cost:, ..) as done = sampled(50, 500).state

      probe_book.Finished(
        ..done,
        cost: capture.ProbeCost(
          ..cost,
          outcome: measure.Unrecorded,
          matched: None,
          counters: None,
        ),
      )
    })
  let found = replayed(unrecorded)
  let assert probe_book.Finished(outcome:, ..) = found.state

  assert outcome == measure.Unrecorded
}
