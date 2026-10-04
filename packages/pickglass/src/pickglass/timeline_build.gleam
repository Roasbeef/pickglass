//// The timeline page from the ring.
////
//// The ring holds one observation per pass, so a timeline is a view of it
//// over time: scheduler utilisation between passes, the process count, each
//// memory category, with the operator's checkpoints and the probes that ran
//// laid over them as spans. Nothing here reads the target; every point is a
//// reading some pass took, at the time that pass began, and a pass that
//// failed to read a section leaves a `Missing` step and a gap, not a
//// plausible interpolation.
////
//// Times on the page are milliseconds from the first pass in the window.
//// Passes are taken on the viewer's wall clock, so a step's width is the
//// time to the next pass, and the last step is as wide as the cadence.
////
//// The run queue is a track whose steps are all missing: the agent does not
//// read it yet, and a track that says so is better than one that is absent
//// and leaves the operator wondering. When the agent reports it the steps
//// are filled from the same place.

import gleam/int
import gleam/list
import gleam/option.{None, Some}
import pickglass/marks.{type Mark}
import pickglass/observation.{type Observation}
import pickglass/panel
import pickglass/probe_book.{type ProbeRecord}
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/policy
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/model

/// The categories that get a track of their own, in the order shown.
const category_tracks = [
  "total", "processes", "system", "binary", "ets", "atom", "code",
]

/// Build the timeline. `observations` is newest first, as the ring returns
/// it. `Error` when the ring holds nothing to draw.
///
/// ## Examples
///
/// ```gleam
/// timeline_build.build(observations, marks, probes, 2000, 1_000_000)
/// ```
pub fn build(
  observations: List(Observation),
  marks: List(Mark),
  probes: List(ProbeRecord),
  cadence_ms: Int,
  now_ms: Int,
) -> Result(model.TimelineModel, String) {
  case list.reverse(observations) {
    [] -> Error("the ring holds no observation yet")
    [first, ..] as oldest -> {
      let origin = first.at_ms
      let width = int.max(1, cadence_ms)
      let times =
        list.map(oldest, fn(observation) { observation.at_ms - origin })
      let last_at = case list.last(times) {
        Ok(at) -> at
        Error(Nil) -> 0
      }

      Ok(model.TimelineModel(
        info: panel.info(panel.Facts(
          source: "the viewer's ring of observations",
          method: "one reading per collection pass",
          cadence_ms:,
          scope: "passes",
          requested: list.length(oldest),
          achieved: list.length(list.filter(oldest, observation.answered)),
          outcome: measure.Complete,
          gap_ms: None,
          took_ms: None,
        )),
        window_ms: last_at + width,
        clock_note: "the viewer's wall clock at the start of each pass",
        tracks: list.flatten([
          [utilisation_track(oldest, times, width)],
          [run_queue_track(times, width)],
          [
            counter_track(
              "process count",
              unit.Count,
              oldest,
              times,
              width,
              fn(observation) {
                case observation.memory {
                  Ok(memory) -> Known(memory.process_count)
                  Error(_) -> Missing(measure.DecodeFailed)
                }
              },
            ),
          ],
          list.map(category_tracks, fn(category) {
            counter_track(
              "memory: " <> category,
              unit.Bytes,
              oldest,
              times,
              width,
              fn(observation) { category_of(observation, category) },
            )
          }),
          [probe_track(probes, origin, now_ms)],
          [mark_track(marks, origin, width)],
        ]),
        gaps: gaps_of(oldest, times, width),
      ))
    }
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

fn steps_of(
  times: List(Int),
  width: Int,
  values: List(Measurement),
) -> List(model.Step) {
  let widths = list.map2(times, list.drop(times, 1), fn(at, next) { next - at })

  list.index_map(list.zip(times, values), fn(pair, index) {
    model.Step(
      at_ms: pair.0,
      width_ms: case list.drop(widths, index) {
        [span, ..] -> int.max(1, span)
        [] -> width
      },
      value: pair.1,
    )
  })
}

fn counter_track(
  label: String,
  u: unit.Unit,
  observations: List(Observation),
  times: List(Int),
  width: Int,
  read: fn(Observation) -> Measurement,
) -> model.Track {
  model.CounterTrack(
    label:,
    unit: u,
    steps: steps_of(times, width, list.map(observations, read)),
  )
}

// Utilisation between a pass and the one before it: the change in active
// scheduler time over the change in total, in parts per million, because a
// nearly idle node is below the 0.01% a smaller scale resolves. The first
// pass has no pass before it and so no reading, and a pair where wall time
// was not collected has none either.
fn utilisation_track(
  observations: List(Observation),
  times: List(Int),
  width: Int,
) -> model.Track {
  let pairs =
    list.map2(
      [None, ..list.map(observations, Some)],
      observations,
      fn(before, after) {
        case before {
          None -> Missing(measure.CounterDisabled)
          Some(earlier) -> utilisation(earlier, after)
        }
      },
    )

  model.CounterTrack(
    label: "scheduler utilisation",
    unit: unit.Ratio(per: 1_000_000),
    steps: steps_of(times, width, pairs),
  )
}

fn utilisation(before: Observation, after: Observation) -> Measurement {
  case before.scheduler, after.scheduler {
    Ok(first), Ok(second) -> {
      let active =
        total_of(second, fn(r) { r.active })
        - total_of(first, fn(r) { r.active })
      let total =
        total_of(second, fn(r) { r.total }) - total_of(first, fn(r) { r.total })

      case total > 0 && active >= 0 {
        True -> Known(active * 1_000_000 / total)
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

fn run_queue_track(times: List(Int), width: Int) -> model.Track {
  model.CounterTrack(
    label: "run queue",
    unit: unit.Count,
    steps: steps_of(
      times,
      width,
      list.map(times, fn(_) { Missing(measure.NotCollected) }),
    ),
  )
}

// A probe is a span from the time its start was confirmed for as long as it
// ran; one still running is as long as it has run so far. A probe read back
// from a capture has no start time and so no span.
fn probe_track(
  probes: List(ProbeRecord),
  origin: Int,
  now_ms: Int,
) -> model.Track {
  model.SpanTrack(
    label: "probes",
    spans: list.filter_map(list.reverse(probes), fn(probe) {
      case probe.started_ms {
        0 -> Error(Nil)
        started -> {
          let ended = case probe.state {
            probe_book.Running -> now_ms
            probe_book.Finished(ended_ms:, ..) -> ended_ms
          }

          Ok(model.Span(
            at_ms: started - origin,
            length_ms: int.max(1, ended - started),
            label: kind_text(probe.kind) <> " " <> probe.id,
          ))
        }
      }
    }),
  )
}

fn kind_text(kind: policy.ProbeKind) -> String {
  case kind {
    policy.Counters -> "counters probe"
    policy.Sampling -> "stack probe"
    policy.CallTree -> "call tree probe"
    policy.SchedulingGc -> "scheduling probe"
  }
}

// A checkpoint is an instant; it is drawn as a span one cadence wide so it
// has an extent to select.
fn mark_track(marks: List(Mark), origin: Int, width: Int) -> model.Track {
  model.SpanTrack(
    label: "checkpoints",
    spans: list.map(marks, fn(mark) {
      model.Span(
        at_ms: mark.checkpoint.system_ms - origin,
        length_ms: width,
        label: mark.checkpoint.name,
      )
    }),
  )
}

// A pass where the census or the scheduler reading failed is a stretch the
// charts have nothing for, from that pass to the next.
fn gaps_of(
  observations: List(Observation),
  times: List(Int),
  width: Int,
) -> List(model.CoverageGap) {
  list.zip(observations, times)
  |> list.filter_map(fn(pair) {
    let #(observation, at) = pair

    case observation.census, observation.scheduler {
      Ok(_), Ok(_) -> Error(Nil)
      Error(reason), _ | _, Error(reason) ->
        Ok(model.CoverageGap(
          from_ms: at,
          to_ms: at + width,
          dropped: NotApplicable,
          reason:,
        ))
    }
  })
}
