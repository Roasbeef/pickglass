//// Two captures as the compare page's model.
////
//// A comparison is only as good as the match between the two captures, so
//// the model carries both headers' provenance whole and the page asks core
//// (`provenance.comparability`) which fields differ and which of those block
//// a verdict. This module only reads the figures worth comparing out of each
//// capture and, when both captures hold a sampled-stacks profile, merges the
//// two for the differential flame.
////
//// The figures are the newest reading of each capture, which is the state
//// the capture ended in: memory categories, the process count, the target's
//// OS resident set, and the mean scheduler utilisation over the capture. The
//// utilisation is a change over an interval and so only compares when both
//// captures were taken at the same cadence, which core's per-column verdict
//// enforces; the page does not decide that.
////
//// A reading a capture does not hold is `Missing`, and a figure with no
//// reading on either side shows the word and takes no verdict.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import pickglass/capture_build
import pickglass/capture_file.{type Loaded}
import pickglass/deltas
import pickglass/observation.{type Observation}
import pickglass/observation_codec
import pickglass/probe_book
import pickglass_core/analysis/diff
import pickglass_core/layout/flame
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/profile.{type Profile}
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/model

/// Read two captures into the compare page's model. `names` are what the
/// page shows for each.
///
/// ## Examples
///
/// ```gleam
/// compare_build.build("a.pgcap", a, "b.pgcap", b)
/// ```
pub fn build(
  baseline_name: String,
  baseline: Loaded,
  candidate_name: String,
  candidate: Loaded,
) -> Result(model.CompareModel, String) {
  use before <- result.try(observations_of(baseline))
  use after <- result.try(observations_of(candidate))

  Ok(model.CompareModel(
    baseline_name:,
    candidate_name:,
    baseline: baseline.capture.header.provenance,
    candidate: candidate.capture.header.provenance,
    rows: rows_of(before, after),
    diff: diff_of(baseline, candidate),
  ))
}

fn observations_of(loaded: Loaded) -> Result(List(Observation), String) {
  observation_codec.of_records(
    loaded.capture.records,
    capture_build.runtime_of(loaded.capture.header),
  )
}

fn rows_of(
  before: List(Observation),
  after: List(Observation),
) -> List(model.CompareRow) {
  let newest = fn(observations) { list.last(observations) }

  let figure = fn(label, kind, u, read) {
    model.CompareRow(
      label:,
      kind:,
      unit: u,
      baseline: reading(newest(before), read),
      candidate: reading(newest(after), read),
    )
  }

  list.flatten([
    list.map(
      ["total", "processes", "system", "binary", "ets", "atom", "code"],
      fn(category) {
        figure(
          "memory: " <> category,
          measure.Gauge,
          unit.Bytes,
          fn(observation) { category_of(observation, category) },
        )
      },
    ),
    [
      figure("process count", measure.Gauge, unit.Count, fn(observation) {
        case observation.memory {
          Ok(memory) -> Known(memory.process_count)
          Error(_) -> Missing(measure.DecodeFailed)
        }
      }),
      figure(
        "OS resident set (target)",
        measure.Gauge,
        unit.Bytes,
        deltas.target_rss,
      ),
      model.CompareRow(
        label: "scheduler utilisation (mean)",
        kind: measure.DeltaOverInterval,
        unit: unit.Ratio(per: 10_000),
        baseline: mean_utilisation(before),
        candidate: mean_utilisation(after),
      ),
    ],
  ])
}

fn reading(
  observation: Result(Observation, Nil),
  read: fn(Observation) -> Measurement,
) -> Measurement {
  case observation {
    Ok(found) -> read(found)
    Error(Nil) -> NotApplicable
  }
}

fn category_of(observation: Observation, category: String) -> Measurement {
  case observation.memory {
    Ok(memory) ->
      case list.key_find(memory.categories, category) {
        Ok(bytes) -> Known(bytes)
        Error(Nil) -> Missing(measure.UnsupportedOnRuntime)
      }
    Error(_) -> Missing(measure.DecodeFailed)
  }
}

// The change in active scheduler time over the change in total, from the
// first pass to the last, in parts per ten thousand. A capture of one pass
// has no interval.
fn mean_utilisation(observations: List(Observation)) -> Measurement {
  case observations, list.last(observations) {
    [first, ..], Ok(last) -> utilisation_between(first, last)
    _, _ -> NotApplicable
  }
}

fn utilisation_between(first: Observation, last: Observation) -> Measurement {
  case first.scheduler, last.scheduler {
    Ok(start), Ok(end) -> {
      let active =
        total_of(end, fn(r) { r.active }) - total_of(start, fn(r) { r.active })
      let total =
        total_of(end, fn(r) { r.total }) - total_of(start, fn(r) { r.total })

      case total > 0 && active >= 0 {
        True -> Known(active * 10_000 / total)
        False -> Missing(measure.CounterDisabled)
      }
    }
    _, _ -> Missing(measure.CounterDisabled)
  }
}

fn total_of(
  snapshot: wire.SchedulerSnapshot,
  pick: fn(wire.SchedulerReading) -> Int,
) -> Int {
  list.fold(snapshot.readings, 0, fn(sum, reading) { sum + pick(reading) })
}

// The differential flame needs a sampled-stacks profile in each capture;
// counters profiles have no stacks to merge. The newest such profile of
// each capture is used.
fn diff_of(
  baseline: Loaded,
  candidate: Loaded,
) -> option.Option(model.DiffFlame) {
  case stack_profile(baseline), stack_profile(candidate) {
    Some(base), Some(other) ->
      case differential(base, other) {
        Ok(drawn) -> Some(drawn)
        Error(_) -> None
      }
    _, _ -> None
  }
}

fn stack_profile(loaded: Loaded) -> option.Option(Profile) {
  probe_book.of_records(loaded.capture.records)
  |> list.find_map(fn(probe) {
    case probe.state {
      probe_book.Finished(profile: Some(found), ..) ->
        case profile.source(found) {
          profile.SampledStacks(..) -> Ok(found)
          profile.TracedCalls
          | profile.TracedCounters
          | profile.AllocationCounts -> Error(Nil)
        }
      probe_book.Finished(profile: None, ..) | probe_book.Running -> Error(Nil)
    }
  })
  |> option.from_result
}

fn differential(
  base: Profile,
  other: Profile,
) -> Result(model.DiffFlame, String) {
  use merged <- result.try(
    diff.merge(base, other, diff.Unnormalized)
    |> result.replace_error("the two profiles do not share value types"),
  )
  use column <- result.try(
    profile.column_named(merged, "samples")
    |> result.replace_error("the profiles have no samples column"),
  )
  use layout <- result.map(
    flame.layout(
      merged,
      column,
      flame.Config(..flame.default_config, mode: flame.Differential),
    )
    |> result.replace_error("the merged profile has no call stacks"),
  )

  model.DiffFlame(profile: merged, layout:)
}

/// The figures of one capture, for the command line to print beside the
/// other's. Each is `#(label, reading)`.
///
/// ## Examples
///
/// ```gleam
/// compare_build.figures(loaded)
/// ```
pub fn figures(loaded: Loaded) -> Result(List(#(String, Measurement)), String) {
  use observations <- result.map(observations_of(loaded))

  rows_of(observations, observations)
  |> list.map(fn(row) { #(row.label, row.baseline) })
}
