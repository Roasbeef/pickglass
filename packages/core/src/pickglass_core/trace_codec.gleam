//// The JSON form of a call tree or an events probe's result, as a capture's
//// `events` record carries it.
////
//// The agent's replies are decoded into `wire.CalltraceSnapshot` and
//// `wire.EventsSnapshot`. A capture keeps those snapshots whole so a viewer
//// opened later draws the same timeline the live one did, with the same stop
//// reason, the same dropped counts and the same per-process totals, and so
//// that a replay needs no second model of what a probe returned. This module
//// writes them as JSON and reads them back with total decoders: a code this
//// build does not know, a missing field or a field of the wrong type is a
//// decode failure that names what was expected, never a default.
////
//// Slices are written as parallel arrays (one array per field) and not as an
//// array of objects, because a probe keeps up to five thousand of them and
//// the object keys would be written for every one. A reader that finds
//// arrays of different lengths refuses the record.
////
//// ## Flow
////
//// `events_json` and `calltrace_json` write a snapshot. `events_decoder` and
//// `calltrace_decoder` read one, joining the parallel arrays with
//// `zip_slices` (events) and `zip_calls` (call slices).

import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import pickglass_core/wire.{
  type ActivityKind, type CallPath, type CallSlice, type CalltraceMeter,
  type CalltraceSnapshot, type EventsMeter, type EventsSnapshot, type LongEvent,
  type ProbeState, type StackFrame, type TraceMeter, type TraceStop,
  type TracedProcess,
}

// ---------------------------------------------------------------- closed codes

/// The stable code of a probe state.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.state_code(wire.ProbeFinished)
/// // -> "finished"
/// ```
pub fn state_code(state: ProbeState) -> String {
  case state {
    wire.ProbeRunning -> "running"
    wire.ProbeFinished -> "finished"
    wire.ProbeStopped -> "stopped"
  }
}

fn parse_state(code: String) -> Result(ProbeState, Nil) {
  list.find([wire.ProbeRunning, wire.ProbeFinished, wire.ProbeStopped], fn(s) {
    state_code(s) == code
  })
}

/// The stable code of a stop reason, the agent's own spelling.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.stop_code(wire.TraceBudget)
/// // -> "event_budget"
/// ```
pub fn stop_code(stop: TraceStop) -> String {
  case stop {
    wire.TraceRunning -> "running"
    wire.TraceDeadline -> "deadline"
    wire.TraceBudget -> "event_budget"
    wire.TraceOverrun -> "overrun"
    wire.TraceTargetsGone -> "targets_gone"
    wire.TraceStopped -> "stopped"
  }
}

fn parse_stop(code: String) -> Result(TraceStop, Nil) {
  list.find(
    [
      wire.TraceRunning,
      wire.TraceDeadline,
      wire.TraceBudget,
      wire.TraceOverrun,
      wire.TraceTargetsGone,
      wire.TraceStopped,
    ],
    fn(stop) { stop_code(stop) == code },
  )
}

/// The stable code of what a scheduling or collection slice describes.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.kind_code(wire.MinorGcSlice)
/// // -> "gc_minor"
/// ```
pub fn kind_code(kind: ActivityKind) -> String {
  case kind {
    wire.RunSlice -> "run"
    wire.MinorGcSlice -> "gc_minor"
    wire.MajorGcSlice -> "gc_major"
  }
}

fn parse_kind(code: String) -> Result(ActivityKind, Nil) {
  list.find([wire.RunSlice, wire.MinorGcSlice, wire.MajorGcSlice], fn(kind) {
    kind_code(kind) == code
  })
}

fn closed(
  expected: String,
  placeholder: a,
  parse: fn(String) -> Result(a, Nil),
) -> Decoder(a) {
  use text <- decode.then(decode.string)

  case parse(text) {
    Ok(value) -> decode.success(value)
    Error(Nil) -> decode.failure(placeholder, expected)
  }
}

// ------------------------------------------------------------------- meters

fn trace_meter_fields(meter: TraceMeter) -> List(#(String, Json)) {
  [
    #("elapsed_ms", json.int(meter.elapsed_ms)),
    #("events", json.int(meter.events)),
    #("max_events", json.int(meter.max_events)),
    #("dropped_events", json.int(meter.dropped_events)),
    #("in_flight_at_stop", json.int(meter.in_flight_at_stop)),
    #("peak_queue", json.int(meter.peak_queue)),
    #("queue_limit", json.int(meter.queue_limit)),
    #("targets_gone", json.int(meter.targets_gone)),
  ]
}

fn trace_meter_decoder() -> Decoder(TraceMeter) {
  use elapsed_ms <- decode.field("elapsed_ms", decode.int)
  use events <- decode.field("events", decode.int)
  use max_events <- decode.field("max_events", decode.int)
  use dropped_events <- decode.field("dropped_events", decode.int)
  use in_flight_at_stop <- decode.field("in_flight_at_stop", decode.int)
  use peak_queue <- decode.field("peak_queue", decode.int)
  use queue_limit <- decode.field("queue_limit", decode.int)
  use targets_gone <- decode.field("targets_gone", decode.int)

  decode.success(wire.TraceMeter(
    elapsed_ms:,
    events:,
    max_events:,
    dropped_events:,
    in_flight_at_stop:,
    peak_queue:,
    queue_limit:,
    targets_gone:,
  ))
}

// ------------------------------------------------------------------- events

/// Encode an events probe's result.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.events_json(snapshot) |> json.to_string
/// ```
pub fn events_json(snapshot: EventsSnapshot) -> Json {
  let meter = snapshot.meter

  json.object([
    #("probe_id", json.int(snapshot.probe_id)),
    #("state", json.string(state_code(snapshot.state))),
    #("stop", json.string(stop_code(snapshot.stop))),
    #(
      "meter",
      json.object(
        list.append(trace_meter_fields(meter.trace), [
          #("unpaired_events", json.int(meter.unpaired_events)),
          #("dropped_slices", json.int(meter.dropped_slices)),
          #("long_events_seen", json.int(meter.long_events_seen)),
          #("strays", json.int(meter.strays)),
          #("long_gc_ms", json.int(meter.long_gc_ms)),
          #("long_schedule_ms", json.int(meter.long_schedule_ms)),
        ]),
      ),
    ),
    #("processes", json.array(snapshot.processes, traced_process_json)),
    #(
      "slices",
      json.object([
        #("process", json.array(snapshot.slices, fn(s) { json.int(s.process) })),
        #(
          "kind",
          json.array(snapshot.slices, fn(s) { json.string(kind_code(s.kind)) }),
        ),
        #(
          "start_ns",
          json.array(snapshot.slices, fn(s) { json.int(s.start_ns) }),
        ),
        #(
          "duration_ns",
          json.array(snapshot.slices, fn(s) { json.int(s.duration_ns) }),
        ),
      ]),
    ),
    #("long", json.array(snapshot.long, long_json)),
  ])
}

fn traced_process_json(process: TracedProcess) -> Json {
  json.object([
    #("pid", json.string(process.pid_text)),
    #("runs", json.int(process.runs)),
    #("run_ns", json.int(process.run_ns)),
    #("minor_gcs", json.int(process.minor_gcs)),
    #("major_gcs", json.int(process.major_gcs)),
    #("gc_ns", json.int(process.gc_ns)),
  ])
}

fn traced_process_decoder() -> Decoder(TracedProcess) {
  use pid_text <- decode.field("pid", decode.string)
  use runs <- decode.field("runs", decode.int)
  use run_ns <- decode.field("run_ns", decode.int)
  use minor_gcs <- decode.field("minor_gcs", decode.int)
  use major_gcs <- decode.field("major_gcs", decode.int)
  use gc_ns <- decode.field("gc_ns", decode.int)

  decode.success(wire.TracedProcess(
    pid_text:,
    runs:,
    run_ns:,
    minor_gcs:,
    major_gcs:,
    gc_ns:,
  ))
}

fn long_json(event: LongEvent) -> Json {
  case event {
    wire.LongGc(pid_text:, duration_ms:, heap_words:) ->
      json.object([
        #("kind", json.string("long_gc")),
        #("pid", json.string(pid_text)),
        #("duration_ms", json.int(duration_ms)),
        #("heap_words", json.int(heap_words)),
      ])
    wire.LongSchedule(pid_text:, duration_ms:, function:) ->
      json.object([
        #("kind", json.string("long_schedule")),
        #("pid", json.string(pid_text)),
        #("duration_ms", json.int(duration_ms)),
        #("function", json.string(function)),
      ])
  }
}

fn long_decoder() -> Decoder(LongEvent) {
  use kind <- decode.field("kind", decode.string)
  use pid_text <- decode.field("pid", decode.string)
  use duration_ms <- decode.field("duration_ms", decode.int)

  case kind {
    "long_gc" -> {
      use heap_words <- decode.field("heap_words", decode.int)

      decode.success(wire.LongGc(pid_text:, duration_ms:, heap_words:))
    }
    "long_schedule" -> {
      use function <- decode.field("function", decode.string)

      decode.success(wire.LongSchedule(pid_text:, duration_ms:, function:))
    }
    _ ->
      decode.failure(
        wire.LongGc(pid_text:, duration_ms:, heap_words: 0),
        "long_gc or long_schedule",
      )
  }
}

/// Decode an events probe's result written by `events_json`.
pub fn events_decoder() -> Decoder(EventsSnapshot) {
  use probe_id <- decode.field("probe_id", decode.int)
  use state <- decode.field(
    "state",
    closed("a probe state", wire.ProbeRunning, parse_state),
  )
  use stop <- decode.field(
    "stop",
    closed("a stop reason", wire.TraceRunning, parse_stop),
  )
  use meter <- decode.field("meter", events_meter_decoder())
  use processes <- decode.field(
    "processes",
    decode.list(traced_process_decoder()),
  )
  use slices <- decode.field("slices", slices_decoder())
  use long <- decode.field("long", decode.list(long_decoder()))

  decode.success(wire.EventsSnapshot(
    probe_id:,
    state:,
    stop:,
    meter:,
    processes:,
    slices:,
    long:,
  ))
}

fn events_meter_decoder() -> Decoder(EventsMeter) {
  use trace <- decode.then(trace_meter_decoder())
  use unpaired_events <- decode.field("unpaired_events", decode.int)
  use dropped_slices <- decode.field("dropped_slices", decode.int)
  use long_events_seen <- decode.field("long_events_seen", decode.int)
  use strays <- decode.field("strays", decode.int)
  use long_gc_ms <- decode.field("long_gc_ms", decode.int)
  use long_schedule_ms <- decode.field("long_schedule_ms", decode.int)

  decode.success(wire.EventsMeter(
    trace:,
    unpaired_events:,
    dropped_slices:,
    long_events_seen:,
    strays:,
    long_gc_ms:,
    long_schedule_ms:,
  ))
}

fn slices_decoder() -> Decoder(List(wire.ActivitySlice)) {
  use process <- decode.field("process", decode.list(decode.int))
  use kind <- decode.field(
    "kind",
    decode.list(closed("a slice kind", wire.RunSlice, parse_kind)),
  )
  use start_ns <- decode.field("start_ns", decode.list(decode.int))
  use duration_ns <- decode.field("duration_ns", decode.list(decode.int))

  case zip_slices(process, kind, start_ns, duration_ns) {
    Ok(slices) -> decode.success(slices)
    Error(Nil) -> decode.failure([], "slice arrays of one length")
  }
}

/// Join the four parallel arrays of an events record into slices. The arrays
/// must have one length.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.zip_slices([0], [wire.RunSlice], [5], [7])
/// // -> Ok([ActivitySlice(0, RunSlice, 5, 7)])
/// ```
pub fn zip_slices(
  process: List(Int),
  kind: List(ActivityKind),
  start_ns: List(Int),
  duration_ns: List(Int),
) -> Result(List(wire.ActivitySlice), Nil) {
  case
    list.length(process) == list.length(kind)
    && list.length(kind) == list.length(start_ns)
    && list.length(start_ns) == list.length(duration_ns)
  {
    False -> Error(Nil)
    True ->
      Ok(
        list.zip(list.zip(process, kind), list.zip(start_ns, duration_ns))
        |> list.map(fn(pair) {
          let #(#(process, kind), #(start_ns, duration_ns)) = pair

          wire.ActivitySlice(process:, kind:, start_ns:, duration_ns:)
        }),
      )
  }
}

// ---------------------------------------------------------------- call tree

/// Encode a call tree probe's result: its meter, frame table, paths, traced
/// processes and the raw slices it kept for a timeline.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.calltrace_json(snapshot) |> json.to_string
/// ```
pub fn calltrace_json(snapshot: CalltraceSnapshot) -> Json {
  let meter = snapshot.meter

  json.object([
    #("probe_id", json.int(snapshot.probe_id)),
    #("state", json.string(state_code(snapshot.state))),
    #("stop", json.string(stop_code(snapshot.stop))),
    #(
      "meter",
      json.object(
        list.append(trace_meter_fields(meter.trace), [
          #("forced_closes", json.int(meter.forced_closes)),
          #("distinct_paths", json.int(meter.distinct_paths)),
          #("dropped_calls", json.int(meter.dropped_calls)),
          #("elided_calls", json.int(meter.elided_calls)),
          #("strays", json.int(meter.strays)),
          #("depth_limit", json.int(meter.depth_limit)),
        ]),
      ),
    ),
    #("frames", json.array(snapshot.frames, frame_json)),
    #("paths", json.array(snapshot.paths, path_json)),
    #("processes", json.array(snapshot.processes, json.string)),
    #(
      "slices",
      json.object([
        #("process", json.array(snapshot.slices, fn(s) { json.int(s.process) })),
        #("frame", json.array(snapshot.slices, fn(s) { json.int(s.frame) })),
        #(
          "start_ns",
          json.array(snapshot.slices, fn(s) { json.int(s.start_ns) }),
        ),
        #(
          "duration_ns",
          json.array(snapshot.slices, fn(s) { json.int(s.duration_ns) }),
        ),
        #("depth", json.array(snapshot.slices, fn(s) { json.int(s.depth) })),
      ]),
    ),
  ])
}

fn frame_json(frame: StackFrame) -> Json {
  json.object([
    #("module", json.string(frame.module)),
    #("function", json.string(frame.function)),
    #("arity", json.int(frame.arity)),
  ])
}

fn frame_decoder() -> Decoder(StackFrame) {
  use module <- decode.field("module", decode.string)
  use function <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)

  decode.success(wire.StackFrame(
    module:,
    function:,
    arity:,
    location: wire.NoLocation,
  ))
}

fn path_json(path: CallPath) -> Json {
  json.object([
    #("calls", json.int(path.calls)),
    #("inclusive_ns", json.int(path.inclusive_ns)),
    #("exclusive_ns", json.int(path.exclusive_ns)),
    #("frames", json.array(path.frames, json.int)),
  ])
}

fn path_decoder() -> Decoder(CallPath) {
  use calls <- decode.field("calls", decode.int)
  use inclusive_ns <- decode.field("inclusive_ns", decode.int)
  use exclusive_ns <- decode.field("exclusive_ns", decode.int)
  use frames <- decode.field("frames", decode.list(decode.int))

  decode.success(wire.CallPath(calls:, inclusive_ns:, exclusive_ns:, frames:))
}

/// Decode a call tree probe's result written by `calltrace_json`.
pub fn calltrace_decoder() -> Decoder(CalltraceSnapshot) {
  use probe_id <- decode.field("probe_id", decode.int)
  use state <- decode.field(
    "state",
    closed("a probe state", wire.ProbeRunning, parse_state),
  )
  use stop <- decode.field(
    "stop",
    closed("a stop reason", wire.TraceRunning, parse_stop),
  )
  use meter <- decode.field("meter", calltrace_meter_decoder())
  use frames <- decode.field("frames", decode.list(frame_decoder()))
  use paths <- decode.field("paths", decode.list(path_decoder()))
  use processes <- decode.field("processes", decode.list(decode.string))
  use slices <- decode.field("slices", call_slices_decoder())

  decode.success(wire.CalltraceSnapshot(
    probe_id:,
    state:,
    stop:,
    meter:,
    frames:,
    paths:,
    processes:,
    slices:,
  ))
}

fn calltrace_meter_decoder() -> Decoder(CalltraceMeter) {
  use trace <- decode.then(trace_meter_decoder())
  use forced_closes <- decode.field("forced_closes", decode.int)
  use distinct_paths <- decode.field("distinct_paths", decode.int)
  use dropped_calls <- decode.field("dropped_calls", decode.int)
  use elided_calls <- decode.field("elided_calls", decode.int)
  use strays <- decode.field("strays", decode.int)
  use depth_limit <- decode.field("depth_limit", decode.int)

  decode.success(wire.CalltraceMeter(
    trace:,
    forced_closes:,
    distinct_paths:,
    dropped_calls:,
    elided_calls:,
    strays:,
    depth_limit:,
  ))
}

fn call_slices_decoder() -> Decoder(List(CallSlice)) {
  use process <- decode.field("process", decode.list(decode.int))
  use frame <- decode.field("frame", decode.list(decode.int))
  use start_ns <- decode.field("start_ns", decode.list(decode.int))
  use duration_ns <- decode.field("duration_ns", decode.list(decode.int))
  use depth <- decode.field("depth", decode.list(decode.int))

  case zip_calls(process, frame, start_ns, duration_ns, depth) {
    Ok(slices) -> decode.success(slices)
    Error(Nil) -> decode.failure([], "call slice arrays of one length")
  }
}

/// Join the five parallel arrays of a call slice record. The arrays must have
/// one length.
///
/// ## Examples
///
/// ```gleam
/// trace_codec.zip_calls([0], [1], [5], [7], [2])
/// // -> Ok([CallSlice(0, 1, 5, 7, 2)])
/// ```
pub fn zip_calls(
  process: List(Int),
  frame: List(Int),
  start_ns: List(Int),
  duration_ns: List(Int),
  depth: List(Int),
) -> Result(List(CallSlice), Nil) {
  let width = list.length(process)

  case
    list.all([frame, start_ns, duration_ns, depth], fn(column) {
      list.length(column) == width
    })
  {
    False -> Error(Nil)
    True ->
      Ok(
        list.zip(
          process,
          list.zip(frame, list.zip(start_ns, list.zip(duration_ns, depth))),
        )
        |> list.map(fn(row) {
          let #(process, #(frame, #(start_ns, #(duration_ns, depth)))) = row

          wire.CallSlice(process:, frame:, start_ns:, duration_ns:, depth:)
        }),
      )
  }
}
