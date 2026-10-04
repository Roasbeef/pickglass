import fixture
import gleam/list
import gleam/option.{None}
import pickglass/marks
import pickglass/observation.{Observation}
import pickglass/probe_book
import pickglass/timeline_build
import pickglass_core/capture
import pickglass_core/measure.{Known, Missing}
import pickglass_core/policy
import pickglass_web/model

fn ring() -> List(observation.Observation) {
  // Newest first, as the hub's ring returns it.
  [
    fixture.observation(2, 5000),
    fixture.observation(1, 3000),
    fixture.observation(0, 1000),
  ]
}

fn track(page: model.TimelineModel, label: String) -> model.Track {
  let assert Ok(found) =
    list.find(page.tracks, fn(track) {
      case track {
        model.CounterTrack(label: l, ..) | model.SpanTrack(label: l, ..) ->
          l == label
      }
    })

  found
}

pub fn an_empty_ring_has_no_timeline_test() {
  assert timeline_build.build([], [], [], 2000, 0)
    == Error("the ring holds no observation yet")
}

pub fn times_are_milliseconds_from_the_first_pass_test() {
  let assert Ok(page) = timeline_build.build(ring(), [], [], 2000, 6000)
  let assert model.CounterTrack(steps:, ..) = track(page, "process count")

  assert list.map(steps, fn(step) { step.at_ms }) == [0, 2000, 4000]
  assert list.map(steps, fn(step) { step.value })
    == [Known(12), Known(12), Known(12)]

  // The window runs to the last pass plus one cadence.
  assert page.window_ms == 6000
}

pub fn utilisation_is_the_change_between_passes_and_the_first_has_none_test() {
  let assert Ok(page) = timeline_build.build(ring(), [], [], 2000, 6000)
  let assert model.CounterTrack(steps:, ..) =
    track(page, "scheduler utilisation")
  let assert [first, second, ..] = steps

  assert first.value == Missing(measure.CounterDisabled)

  // Active time rises by 200 over a total rise of 400 on scheduler 1 and
  // 100 over 400 on scheduler 2: 300 of 800.
  assert second.value == Known(3750)
}

pub fn the_run_queue_is_a_track_of_words_not_numbers_test() {
  let assert Ok(page) = timeline_build.build(ring(), [], [], 2000, 6000)
  let assert model.CounterTrack(steps:, ..) = track(page, "run queue")

  assert list.all(steps, fn(step) {
    step.value == Missing(measure.UnsupportedOnRuntime)
  })
}

pub fn every_memory_category_has_a_track_in_bytes_test() {
  let assert Ok(page) = timeline_build.build(ring(), [], [], 2000, 6000)
  let assert model.CounterTrack(steps:, ..) = track(page, "memory: total")

  assert list.map(steps, fn(step) { step.value })
    == [Known(1_002_000), Known(1_001_000), Known(1_000_000)]
    |> list.reverse
}

pub fn checkpoints_and_probes_are_spans_on_the_same_axis_test() {
  let probe = probe_book.started(7, policy.Counters, ["lists"], 2500, 30_000, 3)
  let mark = marks.take(capture.Checkpoint("idle-0", 0, 4000), None)
  let assert Ok(page) =
    timeline_build.build(ring(), [mark], [probe], 2000, 4500)

  let assert model.SpanTrack(spans: checkpoints, ..) =
    track(page, "checkpoints")
  let assert model.SpanTrack(spans: probes, ..) = track(page, "probes")

  assert list.map(checkpoints, fn(span) { #(span.at_ms, span.label) })
    == [#(3000, "idle-0")]

  // A running probe is as long as it has run so far.
  assert list.map(probes, fn(span) { #(span.at_ms, span.length_ms) })
    == [#(1500, 2000)]
}

pub fn a_failed_section_leaves_a_gap_with_its_reason_test() {
  let broken =
    Observation(
      ..fixture.observation(1, 3000),
      census: Error("the agent did not answer in time"),
    )
  let assert Ok(page) =
    timeline_build.build(
      [fixture.observation(2, 5000), broken, fixture.observation(0, 1000)],
      [],
      [],
      2000,
      6000,
    )

  assert list.map(page.gaps, fn(gap) { #(gap.from_ms, gap.to_ms, gap.reason) })
    == [#(2000, 4000, "the agent did not answer in time")]
}
