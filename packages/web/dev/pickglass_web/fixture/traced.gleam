//// Synthetic tracing-probe timelines for the preview and the tests.
////
//// A scheduling and collection probe and a call tree probe each give the
//// Timeline page a block of its own. The numbers are invented and the shape
//// is chosen so that every element shows: three processes with runs of
//// microseconds to milliseconds, minor collections after runs, one major
//// collection, a probe that stopped before its window ended so part of the
//// axis is unshaded, a long collection and a long timeslice, and a call
//// timeline nested four levels deep. The module lives under `dev/` so
//// nothing in the release can show invented figures.

import gleam/list
import gleam/option.{None}
import pickglass_core/measure
import pickglass_web/model
import pickglass_web/timeline_model

// A deterministic source of numbers, so the preview is the same on every
// run.
fn next(seed: Int) -> Int {
  { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
}

// Runs and collections of one process: a run every few milliseconds, each
// followed by a short minor collection, with a major collection in the
// middle of the window.
fn slices(
  seed: Int,
  count: Int,
  pace_ns: Int,
) -> List(timeline_model.ActivitySlice) {
  let #(_, built, _) =
    list.index_fold(
      list.repeat(Nil, count),
      #(seed, [], 0),
      fn(state, _, position) {
        let index = position + 1
        let #(random, built, at) = state
        let random = next(random)
        let run = 40_000 + random % 900_000
        let after = at + run
        let collect = case index % 9 {
          0 -> [
            timeline_model.ActivitySlice(
              start_ns: after,
              duration_ns: 380_000 + random % 200_000,
              kind: timeline_model.MajorGcActivity,
            ),
          ]
          3 | 6 -> [
            timeline_model.ActivitySlice(
              start_ns: after,
              duration_ns: 20_000 + random % 40_000,
              kind: timeline_model.MinorGcActivity,
            ),
          ]
          _ -> []
        }
        let pause = case collect {
          [slice] -> slice.duration_ns
          _ -> 0
        }

        #(
          random,
          list.append(list.reverse(collect), [
            timeline_model.ActivitySlice(
              start_ns: at,
              duration_ns: run,
              kind: timeline_model.RunActivity,
            ),
            ..built
          ]),
          after + pause + pace_ns + random % pace_ns,
        )
      },
    )

  list.reverse(built)
}

fn track(
  label: String,
  seed: Int,
  count: Int,
  pace_ns: Int,
) -> timeline_model.TracedTrack {
  let drawn = slices(seed, count, pace_ns)
  let runs =
    list.filter(drawn, fn(slice) { slice.kind == timeline_model.RunActivity })
  let minors =
    list.filter(drawn, fn(slice) {
      slice.kind == timeline_model.MinorGcActivity
    })
  let majors =
    list.filter(drawn, fn(slice) {
      slice.kind == timeline_model.MajorGcActivity
    })
  let time = fn(from: List(timeline_model.ActivitySlice)) {
    list.fold(from, 0, fn(sum, slice) { sum + slice.duration_ns })
  }

  timeline_model.TracedTrack(
    label:,
    runs: list.length(runs),
    run_ns: time(runs),
    minor_gcs: list.length(minors),
    major_gcs: list.length(majors),
    gc_ns: time(list.append(minors, majors)),
    slices: drawn,
  )
}

fn panel_info(
  source: String,
  method: String,
  events: Int,
  outcome: measure.Outcome,
) -> model.PanelInfo {
  model.PanelInfo(
    source:,
    method:,
    cadence: measure.OneShot,
    achieved_ms: None,
    took_ms: None,
    coverage: measure.Coverage(
      scope: "events folded",
      requested: 100_000,
      achieved: events,
      outcome:,
      dropped_events: measure.Known(61_204),
      in_flight_events: measure.Known(61_198),
      unscanned_bytes: measure.NotApplicable,
    ),
  )
}

/// A scheduling and collection probe that ran its whole 5 s window over three
/// processes and saw two threshold events.
///
/// ## Examples
///
/// ```gleam
/// traced.events()
/// ```
pub fn events() -> timeline_model.EventsTimeline {
  timeline_model.EventsTimeline(
    probe: "p-43",
    info: panel_info(
      "agent trace session",
      "running and garbage_collection events, folded in the agent",
      9100,
      measure.Complete,
    ),
    window_ns: 5_000_000_000,
    observed_ns: 5_000_000_000,
    tracks: [
      track("<0.4411.0> session s-12 / keeper", 7, 60, 1_000_000),
      track("<0.4412.0> session s-12 / gateway", 31, 40, 2_000_000),
      track("<0.88.0> weft_actor", 53, 25, 4_000_000),
    ],
    long: [
      timeline_model.LongGcMarker(
        process: "<0.4411.0>",
        duration_ms: 61,
        heap_words: 4_194_304,
      ),
      timeline_model.LongScheduleMarker(
        process: "<0.4412.0>",
        duration_ms: 140,
        function: "lists:sort/1",
      ),
    ],
    long_gc_ms: 50,
    long_schedule_ms: 100,
    long_seen: 2,
    notes: [
      "The probe ran to the end of its window and folded 9,100 events.",
      "Node-wide thresholds: collections of 50 ms or more and timeslices of 100 ms or more are reported for any process on the node, not only the traced ones; 2 were seen, and the agent keeps the first 200.",
      "Time on a scheduler is the closest the BEAM comes to per-process CPU time, and includes any time the operating system took the scheduler thread away.",
    ],
  )
}

/// The same probe cut short at 1.2 s of a 5 s window, because its collector
/// fell behind: the shaded part of the axis ends where the probe did.
///
/// ## Examples
///
/// ```gleam
/// traced.events_overrun()
/// ```
pub fn events_overrun() -> timeline_model.EventsTimeline {
  let base = events()

  timeline_model.EventsTimeline(
    ..base,
    info: panel_info(
      "agent trace session",
      "running and garbage_collection events, folded in the agent",
      31_000,
      measure.Partial(measure.Truncated(measure.CollectorOverrun)),
    ),
    observed_ns: 1_200_000_000,
    tracks: list.map(base.tracks, fn(track) {
      timeline_model.TracedTrack(
        ..track,
        slices: list.filter(track.slices, fn(slice) {
          slice.start_ns + slice.duration_ns <= 1_200_000_000
        }),
      )
    }),
    notes: [
      "The probe was stopped after 1,200 ms because the collector fell behind (its queue reached 50,012 of 50,000 messages); the result is partial.",
      "61,204 events arrived after the stop and were discarded unread; 61,198 were already queued when it stopped.",
    ],
  )
}

/// A call tree probe over two processes: calls nested four levels deep, the
/// deepest of them microseconds long.
///
/// ## Examples
///
/// ```gleam
/// traced.calls()
/// ```
pub fn calls() -> timeline_model.CallsTimeline {
  timeline_model.CallsTimeline(
    probe: "p-44",
    info: panel_info(
      "agent trace session",
      "call and return_to, folded in the agent",
      24_400,
      measure.Complete,
    ),
    window_ns: 5_000_000_000,
    observed_ns: 5_000_000_000,
    tracks: [
      timeline_model.CallTrack(
        label: "<0.4411.0> session s-12 / keeper",
        calls: nested(11, 6),
      ),
      timeline_model.CallTrack(
        label: "<0.4412.0> session s-12 / gateway",
        calls: nested(29, 4),
      ),
    ],
    notes: [
      "The probe ran to the end of its window and folded 24,400 events.",
      "Untraced time inside a traced function counts as exclusive: a callee that was not traced is charged to its caller.",
      "Recursion deeper than one level reads as two levels.",
    ],
  )
}

// A handful of requests, each a call that contains a call that contains
// another, so every level has something drawn in it.
fn nested(seed: Int, requests: Int) -> List(timeline_model.CallBox) {
  let #(_, built, _) =
    list.index_fold(
      list.repeat(Nil, requests),
      #(seed, [], 100_000_000),
      fn(state, _, n) {
        let #(random, built, at) = state
        let random = next(random)
        let outer = 120_000_000 + random % 400_000_000
        let inner = outer * 6 / 10
        let leaf = inner / 3

        #(
          random,
          list.append(
            [
              timeline_model.CallBox(
                name: "loom@runtime@keeper:handle/2",
                start_ns: at,
                duration_ns: outer,
                depth: 0,
              ),
              timeline_model.CallBox(
                name: "loom@runtime@keeper:persist/2",
                start_ns: at + outer / 10,
                duration_ns: inner,
                depth: 1,
              ),
              timeline_model.CallBox(
                name: "gleam@list:map/2",
                start_ns: at + outer / 5,
                duration_ns: inner / 2,
                depth: 2,
              ),
              timeline_model.CallBox(
                name: "lists:sort/1",
                start_ns: at + outer / 4,
                duration_ns: leaf + n * 10_000,
                depth: 3,
              ),
            ],
            built,
          ),
          at + outer + 150_000_000,
        )
      },
    )

  list.reverse(built)
}
