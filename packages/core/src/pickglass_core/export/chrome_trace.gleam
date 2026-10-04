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
//// ## Flow
////
//// `export` writes a `track_name` metadata event for each track, then
//// each track's events through `encode_event`, which converts times with
//// `microseconds`.

import gleam/int
import gleam/json.{type Json}
import gleam/list
import pickglass_core/export.{type Export, Export}

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
