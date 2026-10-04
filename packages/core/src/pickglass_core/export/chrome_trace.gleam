//// Chrome trace event JSON, for Perfetto and `chrome://tracing`.
////
//// The timeline of a capture is a set of tracks, each holding events: a
//// slice has a start and a duration (a traced call, a GC, a provider
//// request), a counter has named values at a time, and an instant has just
//// a time. This module defines that small event model with timestamps in
//// nanoseconds, because that is what the BEAM's monotonic clock gives, and
//// writes it in the Trace Event Format, whose timestamps are microseconds.
////
//// Slices become `X` events, counters `C`, instants `i` with thread scope,
//// and each track's name and the process name become `M` metadata events.
//// A track is one thread (`tid`) of one process (`pid` 1), so Perfetto
//// shows one row per track. Events are written in the order given, track by
//// track, so equal input gives equal output.
////
//// The two tracing probes have timelines of their own, and this module turns
//// them into tracks. A scheduling and collection probe becomes one thread per
//// traced process holding its runs and collections as `X` slices, a totals
//// instant at the start, and one more thread for the node-wide threshold
//// events as instants. A call tree probe becomes one thread per process
//// holding its calls as `X` slices named by function; Perfetto nests slices
//// that contain one another on a thread, so the callers and callees come out
//// as a stack.
////
//// ## Flow
////
//// `export` writes a `track_name` metadata event for each track, then
//// each track's events through `encode_event`, which converts times with
//// `microseconds`. `events` and `calls` build the tracks of a probe's result
//// and call `export`.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import pickglass_core/export.{type Export, Export}
import pickglass_core/wire

/// One event on a track. Times are nanoseconds on the track's clock.
pub type Event {
  /// Something that took time.
  Slice(
    name: String,
    start_ns: Int,
    duration_ns: Int,
    args: List(#(String, String)),
  )

  /// Named numeric values at a moment, drawn as a counter graph.
  Counter(name: String, at_ns: Int, values: List(#(String, Int)))

  /// Something that happened at a moment.
  Instant(name: String, at_ns: Int, args: List(#(String, String)))
}

/// A row of the timeline.
pub type Track {
  Track(
    /// A number unique among the tracks of one export.
    id: Int,
    /// The row's label.
    name: String,
    /// The events, in the order to write them.
    events: List(Event),
  )
}

/// Write tracks as a Chrome trace. `process` names the single process the
/// tracks belong to.
///
/// ## Examples
///
/// ```gleam
/// chrome_trace.export("loomd", [Track(1, "ops", [Instant("start", 0, [])])])
/// ```
pub fn export(process: String, tracks: List(Track)) -> Export {
  let metadata = [
    json.object([
      #("name", json.string("process_name")),
      #("ph", json.string("M")),
      #("pid", json.int(1)),
      #("args", json.object([#("name", json.string(process))])),
    ]),
    ..list.map(tracks, track_name)
  ]
  let events =
    list.flat_map(tracks, fn(track) {
      list.map(track.events, encode_event(track.id, _))
    })
  let document =
    json.object([
      #("traceEvents", json.preprocessed_array(list.append(metadata, events))),
      #("displayTimeUnit", json.string("ns")),
    ])
  Export(body: json.to_string(document), losses: losses())
}

fn track_name(track: Track) -> Json {
  json.object([
    #("name", json.string("thread_name")),
    #("ph", json.string("M")),
    #("pid", json.int(1)),
    #("tid", json.int(track.id)),
    #("args", json.object([#("name", json.string(track.name))])),
  ])
}

fn encode_event(track: Int, event: Event) -> Json {
  case event {
    Slice(name:, start_ns:, duration_ns:, args:) ->
      json.object([
        #("name", json.string(name)),
        #("ph", json.string("X")),
        #("ts", microseconds(start_ns)),
        #("dur", microseconds(int.max(duration_ns, 0))),
        #("pid", json.int(1)),
        #("tid", json.int(track)),
        #("args", string_args(args)),
      ])
    Counter(name:, at_ns:, values:) ->
      json.object([
        #("name", json.string(name)),
        #("ph", json.string("C")),
        #("ts", microseconds(at_ns)),
        #("pid", json.int(1)),
        #("tid", json.int(track)),
        #(
          "args",
          json.object(
            list.map(values, fn(pair) { #(pair.0, json.int(pair.1)) }),
          ),
        ),
      ])
    Instant(name:, at_ns:, args:) ->
      json.object([
        #("name", json.string(name)),
        #("ph", json.string("i")),
        #("s", json.string("t")),
        #("ts", microseconds(at_ns)),
        #("pid", json.int(1)),
        #("tid", json.int(track)),
        #("args", string_args(args)),
      ])
  }
}

fn string_args(args: List(#(String, String))) -> Json {
  json.object(list.map(args, fn(pair) { #(pair.0, json.string(pair.1)) }))
}

// Trace Event Format timestamps are microseconds, possibly fractional.
fn microseconds(nanoseconds: Int) -> Json {
  json.float(int.to_float(nanoseconds) /. 1000.0)
}

/// What this format leaves out.
pub fn losses() -> List(String) {
  [
    "Stacks: events carry names, not call stacks.",
    "Coverage and truncation, except as instants the caller adds.",
    "Provenance, except as process and track names.",
    "Sub-microsecond precision: timestamps are fractional microseconds.",
  ]
}

// ------------------------------------------------------ tracing probes

/// What the file of a scheduling and collection probe leaves out, beyond what
/// every Chrome trace does.
pub fn events_losses() -> List(String) {
  [
    "Slices past the probe's slice limit: the totals on each process's first event count every run and collection, and the slices are the first ones to close.",
    "Time of the node-wide threshold events: the VM reports a duration and a process and no time, so each is placed at the end of the observed window.",
    "The probe's stop reason and the events it dropped: they are named on the Timeline page and in the capture.",
  ]
  |> list.append(losses())
}

/// What the file of a call tree probe leaves out, beyond what every Chrome
/// trace does.
pub fn calls_losses() -> List(String) {
  [
    "Calls past the probe's slice limit: the slices are the first calls to close, and the call counts and times of every call are in the profile.",
    "The probe's stop reason and the events it dropped: they are named on the Profile page and in the capture.",
  ]
  |> list.append(losses())
}

/// A scheduling and collection probe's result as a Chrome trace. `label_of`
/// names a traced process from its pid text, for the thread names. The slices
/// are `X` events named `run`, `gc minor` and `gc major` on the thread of
/// their process; each thread starts with a `totals` instant carrying the
/// counts the probe made over the whole window; and the threshold events are
/// instants on a thread of their own, at the end of the observed window.
///
/// ## Examples
///
/// ```gleam
/// chrome_trace.events("probe-9", snapshot, fn(pid) { pid })
/// ```
pub fn events(
  process: String,
  snapshot: wire.EventsSnapshot,
  label_of: fn(String) -> String,
) -> Export {
  let end_ns = snapshot.meter.trace.elapsed_ms * 1_000_000
  let tracks =
    list.index_map(snapshot.processes, fn(traced, index) {
      Track(id: index + 1, name: label_of(traced.pid_text), events: [
        Instant(name: "totals", at_ns: 0, args: [
          #("runs", int.to_string(traced.runs)),
          #("run_ns", int.to_string(traced.run_ns)),
          #("minor_gcs", int.to_string(traced.minor_gcs)),
          #("major_gcs", int.to_string(traced.major_gcs)),
          #("gc_ns", int.to_string(traced.gc_ns)),
        ]),
        ..list.filter_map(snapshot.slices, fn(slice) {
          case slice.process == index {
            True ->
              Ok(
                Slice(
                  name: slice_name(slice.kind),
                  start_ns: slice.start_ns,
                  duration_ns: slice.duration_ns,
                  args: [#("pid", traced.pid_text)],
                ),
              )
            False -> Error(Nil)
          }
        })
      ])
    })

  let thresholds = case snapshot.long {
    [] -> []
    longs -> [
      Track(
        id: 0,
        name: "node-wide long events (time not reported)",
        events: list.map(longs, fn(event) { long_instant(event, end_ns) }),
      ),
    ]
  }

  Export(
    body: { export(process, list.append(thresholds, tracks)) }.body,
    losses: events_losses(),
  )
}

fn slice_name(kind: wire.ActivityKind) -> String {
  case kind {
    wire.RunSlice -> "run"
    wire.MinorGcSlice -> "gc minor"
    wire.MajorGcSlice -> "gc major"
  }
}

fn long_instant(event: wire.LongEvent, at_ns: Int) -> Event {
  case event {
    wire.LongGc(pid_text:, duration_ms:, heap_words:) ->
      Instant(name: "long_gc", at_ns:, args: [
        #("pid", pid_text),
        #("duration_ms", int.to_string(duration_ms)),
        #("heap_words", int.to_string(heap_words)),
      ])
    wire.LongSchedule(pid_text:, duration_ms:, function:) ->
      Instant(name: "long_schedule", at_ns:, args: [
        #("pid", pid_text),
        #("duration_ms", int.to_string(duration_ms)),
        #("function", function),
      ])
  }
}

/// A call tree probe's slices as a Chrome trace: one thread per traced
/// process, each call an `X` slice named by `module:function/arity` with its
/// depth in the arguments.
///
/// ## Examples
///
/// ```gleam
/// chrome_trace.calls("probe-9", snapshot, fn(pid) { pid })
/// ```
pub fn calls(
  process: String,
  snapshot: wire.CalltraceSnapshot,
  label_of: fn(String) -> String,
) -> Export {
  let frames = snapshot.frames
  let name_of = fn(index) {
    case list.drop(frames, index) {
      [frame, ..] ->
        frame.module
        <> ":"
        <> frame.function
        <> "/"
        <> int.to_string(frame.arity)
      [] -> "unknown"
    }
  }
  let tracks =
    list.index_map(snapshot.processes, fn(pid, index) {
      Track(
        id: index + 1,
        name: label_of(pid),
        events: list.filter_map(snapshot.slices, fn(slice) {
          case slice.process == index {
            True ->
              Ok(
                Slice(
                  name: name_of(slice.frame),
                  start_ns: slice.start_ns,
                  duration_ns: slice.duration_ns,
                  args: [#("depth", int.to_string(slice.depth))],
                ),
              )
            False -> Error(Nil)
          }
        }),
      )
    })

  Export(body: { export(process, tracks) }.body, losses: calls_losses())
}
