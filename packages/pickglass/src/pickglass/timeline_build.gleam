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
//// A scheduling and collection probe, and a call tree probe that kept call
//// slices, are not readings of passes. Each saw every event of its traced
//// processes, and its slices count from the probe's own start, so they are
//// built as a model of their own (`events_of`, `calls_of`) and drawn on an
//// axis of their own: the newest probe of each kind in the book is the one
//// the page shows.
////
//// The run queue is a track whose steps are all missing: the agent does not
//// read it yet, and a track that says so is better than one that is absent
//// and leaves the operator wondering. When the agent reports it the steps
//// are filled from the same place.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import pickglass/marks.{type Mark}
import pickglass/observation.{type Observation}
import pickglass/panel
import pickglass/probe_book.{type ProbeRecord}
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/policy
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/model
import pickglass_web/timeline_model

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
) -> Result(timeline_model.TimelineModel, String) {
  build_labelled(observations, marks, probes, cadence_ms, now_ms, fn(pid) {
    pid
  })
}

/// Build the timeline with a label for each traced process. `label_of` turns
/// a pid text into the words a track is named with, for instance the pid
/// and its owner; the pid alone is what `build` uses.
///
/// ## Examples
///
/// ```gleam
/// timeline_build.build_labelled(observations, [], probes, 2000, now, fn(pid) {
///   pid <> " session s-12"
/// })
/// ```
pub fn build_labelled(
  observations: List(Observation),
  marks: List(Mark),
  probes: List(ProbeRecord),
  cadence_ms: Int,
  now_ms: Int,
  label_of: fn(String) -> String,
) -> Result(timeline_model.TimelineModel, String) {
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

      Ok(
        timeline_model.TimelineModel(
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
          events: newest_events(probes, label_of),
          calls: newest_calls(probes, label_of),
          exports: [],
        ),
      )
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
) -> List(timeline_model.Step) {
  let widths = list.map2(times, list.drop(times, 1), fn(at, next) { next - at })

  list.index_map(list.zip(times, values), fn(pair, index) {
    timeline_model.Step(
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
) -> timeline_model.Track {
  timeline_model.CounterTrack(
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
) -> timeline_model.Track {
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

  timeline_model.CounterTrack(
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

fn run_queue_track(times: List(Int), width: Int) -> timeline_model.Track {
  timeline_model.CounterTrack(
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
) -> timeline_model.Track {
  timeline_model.SpanTrack(
    label: "probes",
    spans: list.filter_map(list.reverse(probes), fn(probe) {
      case probe.started_ms {
        0 -> Error(Nil)
        started -> {
          let ended = case probe.state {
            probe_book.Running -> now_ms
            probe_book.Finished(ended_ms:, ..) -> ended_ms
          }

          Ok(timeline_model.Span(
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
fn mark_track(
  marks: List(Mark),
  origin: Int,
  width: Int,
) -> timeline_model.Track {
  timeline_model.SpanTrack(
    label: "checkpoints",
    spans: list.map(marks, fn(mark) {
      timeline_model.Span(
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
) -> List(timeline_model.CoverageGap) {
  list.zip(observations, times)
  |> list.filter_map(fn(pair) {
    let #(observation, at) = pair

    case observation.census, observation.scheduler {
      Ok(_), Ok(_) -> Error(Nil)
      Error(reason), _ | _, Error(reason) ->
        Ok(timeline_model.CoverageGap(
          from_ms: at,
          to_ms: at + width,
          dropped: NotApplicable,
          reason:,
        ))
    }
  })
}

// ------------------------------------------------------ tracing probes

// The newest finished scheduling probe, from a book that lists newest first.
fn newest_events(
  probes: List(ProbeRecord),
  label_of: fn(String) -> String,
) -> Option(timeline_model.EventsTimeline) {
  list.find_map(probes, fn(probe) {
    case probe.state, probe.detail {
      probe_book.Finished(outcome:, ..), probe_book.SchedulingDetail(snapshot:)
      -> Ok(events_of(probe, snapshot, outcome, label_of))
      _, _ -> Error(Nil)
    }
  })
  |> option.from_result
}

// The newest finished call tree probe that kept call slices.
fn newest_calls(
  probes: List(ProbeRecord),
  label_of: fn(String) -> String,
) -> Option(timeline_model.CallsTimeline) {
  list.find_map(probes, fn(probe) {
    case probe.state, probe.detail {
      probe_book.Finished(outcome:, ..), probe_book.CallSlices(snapshot:) ->
        Ok(calls_of(probe, snapshot, outcome, label_of))
      _, _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// A scheduling and collection probe's result as the page's timeline model.
/// One track per traced process, in the order the probe named them, each with
/// the totals the probe counted and the slices it kept; the node-wide
/// threshold events as markers; and the sentences about how the probe
/// ended.
///
/// ## Examples
///
/// ```gleam
/// timeline_build.events_of(probe, snapshot, measure.Complete, fn(pid) { pid })
/// ```
pub fn events_of(
  probe: ProbeRecord,
  snapshot: wire.EventsSnapshot,
  outcome: measure.Outcome,
  label_of: fn(String) -> String,
) -> timeline_model.EventsTimeline {
  let meter = snapshot.meter
  let notes = case probe.state {
    probe_book.Finished(notes:, ..) -> notes
    probe_book.Running -> []
  }

  timeline_model.EventsTimeline(
    probe: probe.id,
    info: trace_info(
      "agent trace session",
      "running and garbage_collection events, folded in the agent",
      meter.trace,
      outcome,
    ),
    window_ns: probe.duration_ms * 1_000_000,
    observed_ns: meter.trace.elapsed_ms * 1_000_000,
    tracks: list.index_map(snapshot.processes, fn(process, index) {
      timeline_model.TracedTrack(
        label: label_of(process.pid_text),
        runs: process.runs,
        run_ns: process.run_ns,
        minor_gcs: process.minor_gcs,
        major_gcs: process.major_gcs,
        gc_ns: process.gc_ns,
        slices: list.filter_map(snapshot.slices, fn(slice) {
          case slice.process == index {
            True ->
              Ok(timeline_model.ActivitySlice(
                start_ns: slice.start_ns,
                duration_ns: slice.duration_ns,
                kind: activity_kind(slice.kind),
              ))
            False -> Error(Nil)
          }
        }),
      )
    }),
    long: list.map(snapshot.long, fn(event) {
      case event {
        wire.LongGc(pid_text:, duration_ms:, heap_words:) ->
          timeline_model.LongGcMarker(
            process: pid_text,
            duration_ms:,
            heap_words:,
          )
        wire.LongSchedule(pid_text:, duration_ms:, function:) ->
          timeline_model.LongScheduleMarker(
            process: pid_text,
            duration_ms:,
            function:,
          )
      }
    }),
    long_gc_ms: meter.long_gc_ms,
    long_schedule_ms: meter.long_schedule_ms,
    long_seen: meter.long_events_seen,
    notes:,
  )
}

fn activity_kind(kind: wire.ActivityKind) -> timeline_model.ActivityKind {
  case kind {
    wire.RunSlice -> timeline_model.RunActivity
    wire.MinorGcSlice -> timeline_model.MinorGcActivity
    wire.MajorGcSlice -> timeline_model.MajorGcActivity
  }
}

/// A call tree probe's slices as the page's call timeline: a track per
/// traced process, each call named by its function.
///
/// ## Examples
///
/// ```gleam
/// timeline_build.calls_of(probe, snapshot, measure.Complete, fn(pid) { pid })
/// ```
pub fn calls_of(
  probe: ProbeRecord,
  snapshot: wire.CalltraceSnapshot,
  outcome: measure.Outcome,
  label_of: fn(String) -> String,
) -> timeline_model.CallsTimeline {
  let notes = case probe.state {
    probe_book.Finished(notes:, ..) -> notes
    probe_book.Running -> []
  }
  let frames = snapshot.frames
  let name_of = fn(index) {
    case list.drop(frames, index) {
      [frame, ..] ->
        frame.module
        <> ":"
        <> frame.function
        <> "/"
        <> int.to_string(frame.arity)
      [] -> "?"
    }
  }

  timeline_model.CallsTimeline(
    probe: probe.id,
    info: trace_info(
      "agent trace session",
      "call and return_to, folded in the agent",
      snapshot.meter.trace,
      outcome,
    ),
    window_ns: probe.duration_ms * 1_000_000,
    observed_ns: snapshot.meter.trace.elapsed_ms * 1_000_000,
    tracks: list.index_map(snapshot.processes, fn(pid, index) {
      timeline_model.CallTrack(
        label: label_of(pid),
        calls: list.filter_map(snapshot.slices, fn(slice) {
          case slice.process == index {
            True ->
              Ok(timeline_model.CallBox(
                name: name_of(slice.frame),
                start_ns: slice.start_ns,
                duration_ns: slice.duration_ns,
                depth: slice.depth,
              ))
            False -> Error(Nil)
          }
        }),
      )
    }),
    notes:,
  )
}

// The title-bar line of a tracing probe: what it folded against its budget,
// how it ended, and how many events arrived after the stop.
fn trace_info(
  source: String,
  method: String,
  meter: wire.TraceMeter,
  outcome: measure.Outcome,
) -> model.PanelInfo {
  let line =
    panel.info(panel.Facts(
      source:,
      method:,
      cadence_ms: 0,
      scope: "events folded",
      requested: meter.max_events,
      achieved: meter.events,
      outcome:,
      gap_ms: None,
      took_ms: Some(meter.elapsed_ms),
    ))

  model.PanelInfo(
    ..line,
    coverage: measure.Coverage(
      ..line.coverage,
      dropped_events: Known(meter.dropped_events),
      in_flight_events: Known(meter.in_flight_at_stop),
    ),
  )
}
