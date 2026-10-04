//// Checkpoints and the changes measured against them.

import fixture
import gleam/option.{None, Some}
import pickglass/deltas
import pickglass/marks
import pickglass/observation.{Observation}
import pickglass/os_reader
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure.{Known, Missing}
import pickglass_core/wire

fn at(seq: Int, at_ms: Int, total: Int) -> observation.Observation {
  Observation(
    ..fixture.observation(seq, at_ms),
    memory: Ok(fixture.memory(total)),
  )
}

fn with_rss(
  observation: observation.Observation,
  rss: measure.Measurement,
) -> observation.Observation {
  Observation(
    ..observation,
    os: Ok([
      os_reader.Reading(
        pid: 1,
        role: "target",
        rss:,
        anon: Missing(measure.UnsupportedOnPlatform),
        cpu_ms: Known(5),
        start: identity.UnreadableStart,
      ),
    ]),
  )
}

pub fn a_memory_category_change_is_the_difference_of_two_readings_test() {
  let before = at(0, 1000, 1_000_000)
  let after = at(1, 3000, 1_300_000)

  assert deltas.memory(after, before, "total") == Known(300_000)
  assert deltas.memory(after, before, "processes") == Known(150_000)
}

pub fn a_category_the_baseline_lacks_has_no_change_test() {
  let before = at(0, 1000, 1_000_000)
  let after = at(1, 3000, 1_300_000)

  assert deltas.memory(after, before, "binary")
    == Missing(measure.UnsupportedOnRuntime)
}

pub fn a_failed_memory_reading_gives_a_word_not_a_difference_test() {
  let before = Observation(..at(0, 1000, 1), memory: Error("down"))
  let after = at(1, 3000, 2)

  assert deltas.memory(after, before, "total") == Missing(measure.DecodeFailed)
}

pub fn the_resident_set_change_needs_both_readings_test() {
  let before = with_rss(at(0, 1000, 1), Known(1000))
  let after = with_rss(at(1, 3000, 1), Known(1800))
  let unread = with_rss(at(2, 5000, 1), Missing(measure.UnsupportedOnPlatform))

  assert deltas.os_rss(after, before) == Known(800)
  assert deltas.os_rss(unread, before) == Missing(measure.UnsupportedOnPlatform)

  // No OS reading at all is never a zero.
  assert deltas.os_rss(after, at(3, 7000, 1))
    == Missing(measure.CounterDisabled)
}

pub fn a_mark_keeps_the_observation_it_was_taken_against_test() {
  let newest = at(4, 9000, 5)
  let mark = marks.take(capture.Checkpoint("idle-0", 0, 9100), Some(newest))

  assert mark.baseline == Some(newest)
  assert mark.checkpoint.name == "idle-0"
}

pub fn a_replayed_checkpoint_finds_the_pass_just_before_it_test() {
  let observations = [at(0, 1000, 1), at(1, 3000, 1), at(2, 5000, 1)]
  let found =
    marks.from_capture(
      [
        capture.Checkpoint("early", 0, 500),
        capture.Checkpoint("middle", 0, 4000),
        capture.Checkpoint("late", 0, 9000),
      ],
      observations,
    )

  let baselines =
    found
    |> list_map(fn(mark) {
      option.map(mark.baseline, fn(observation) { observation.at_ms })
    })

  // Before the first pass there is no baseline; otherwise the newest pass
  // that began no later than the checkpoint.
  assert baselines == [None, Some(3000), Some(5000)]
}

pub fn the_chosen_mark_is_the_named_one_or_the_newest_test() {
  let first = marks.take(capture.Checkpoint("a", 0, 1), None)
  let second = marks.take(capture.Checkpoint("b", 0, 2), None)

  assert marks.chosen([], None) == None
  assert marks.chosen([first, second], None) == Some(#(1, second))
  assert marks.chosen([first, second], Some(0)) == Some(#(0, first))

  // A choice that is gone falls back to the newest.
  assert marks.chosen([first, second], Some(7)) == Some(#(1, second))
}

pub fn a_census_is_complete_only_when_it_listed_everything_it_scanned_test() {
  let complete = at(0, 1000, 1)
  let cut =
    Observation(
      ..complete,
      census: Ok(
        wire.CensusSnapshot(
          coverage: wire.CensusCoverage(
            scanned: 10,
            total: 50,
            stop: wire.ScanBudgetReached,
            elapsed_ms: 1,
          ),
          rows: [],
          owners: [],
        ),
      ),
    )

  assert deltas.census_complete(complete)
  assert !deltas.census_complete(cut)
  assert !deltas.census_complete(Observation(..complete, census: Error("x")))
}

import gleam/list

fn list_map(items: List(a), f: fn(a) -> b) -> List(b) {
  list.map(items, f)
}
