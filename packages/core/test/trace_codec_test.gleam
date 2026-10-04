//// The JSON of a tracing probe's result and the `events` record that holds
//// it.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pg_data_gen as gen
import pickglass_core/capture
import pickglass_core/export/chrome_trace
import pickglass_core/trace_codec
import pickglass_core/wire

fn meter() -> wire.TraceMeter {
  wire.TraceMeter(
    elapsed_ms: 1200,
    events: 5000,
    max_events: 100_000,
    dropped_events: 3,
    in_flight_at_stop: 2,
    peak_queue: 40,
    queue_limit: 50_000,
    targets_gone: 0,
  )
}

fn events() -> wire.EventsSnapshot {
  wire.EventsSnapshot(
    probe_id: 9,
    state: wire.ProbeFinished,
    stop: wire.TraceDeadline,
    meter: wire.EventsMeter(
      trace: meter(),
      unpaired_events: 1,
      dropped_slices: 0,
      long_events_seen: 2,
      strays: 0,
      long_gc_ms: 50,
      long_schedule_ms: 100,
    ),
    processes: [
      wire.TracedProcess("<0.90.0>", 12, 4_500_000, 3, 1, 900_000),
      wire.TracedProcess("<0.91.0>", 0, 0, 0, 0, 0),
    ],
    slices: [
      wire.ActivitySlice(0, wire.RunSlice, 1_000_000, 250_000),
      wire.ActivitySlice(0, wire.MinorGcSlice, 1_100_000, 40_000),
      wire.ActivitySlice(0, wire.MajorGcSlice, 3_000_000, 600_000),
    ],
    long: [
      wire.LongGc("<0.90.0>", 61, 4096),
      wire.LongSchedule("<0.5.0>", 140, "lists:sort/1"),
    ],
  )
}

fn calls() -> wire.CalltraceSnapshot {
  wire.CalltraceSnapshot(
    probe_id: 4,
    state: wire.ProbeStopped,
    stop: wire.TraceBudget,
    meter: wire.CalltraceMeter(
      trace: meter(),
      forced_closes: 1,
      distinct_paths: 2,
      dropped_calls: 0,
      elided_calls: 0,
      strays: 0,
      depth_limit: 64,
    ),
    frames: [
      wire.StackFrame("lists", "sort", 1, wire.NoLocation),
      wire.StackFrame("m", "work", 0, wire.NoLocation),
    ],
    paths: [
      wire.CallPath(3, 900, 400, [0, 1]),
      wire.CallPath(1, 1000, 100, [1]),
    ],
    processes: ["<0.90.0>"],
    slices: [wire.CallSlice(0, 0, 10, 20, 1), wire.CallSlice(0, 1, 5, 40, 0)],
  )
}

fn text_of(value: json.Json) -> String {
  json.to_string(value)
}

pub fn an_events_result_round_trips_test() {
  let text = text_of(trace_codec.events_json(events()))

  assert json.parse(text, trace_codec.events_decoder()) == Ok(events())
}

pub fn a_call_tree_result_round_trips_test() {
  let text = text_of(trace_codec.calltrace_json(calls()))

  assert json.parse(text, trace_codec.calltrace_decoder()) == Ok(calls())
}

// The capture record holds the whole result, and its generic fields hold the
// slices a reader without the result would still understand: milliseconds,
// each tagged with the process and the kind.
pub fn a_scheduling_probe_makes_a_record_that_reads_back_test() {
  let record = capture.EventsRecord(capture.scheduling_events(events()))
  let line = capture.encode_record(record, json.string)

  assert capture.decode_line(line, decode.string) == Ok(record)

  let capture.EventsRecord(held) = record

  assert held.kind == "scheduling_gc"
  assert held.timestamps_ms == [1, 1, 3]
  assert held.durations_ms == [0, 0, 0]
  assert held.args == ["<0.90.0> run", "<0.90.0> gc_minor", "<0.90.0> gc_major"]
}

// The viewer keeps a call tree's paths in the profile record, so the events
// record holds none, whatever the snapshot it was given carried.
pub fn a_call_tree_record_leaves_the_paths_to_the_profile_test() {
  let record = capture.EventsRecord(capture.call_tree_events(calls()))
  let line = capture.encode_record(record, json.string)

  assert capture.decode_line(line, decode.string) == Ok(record)

  let capture.EventsRecord(held) = record

  assert held.kind == "call_tree"
  assert held.args == ["<0.90.0> lists:sort/1", "<0.90.0> m:work/0"]
  assert held.traced
    == Some(capture.CallTreeTraced(wire.CalltraceSnapshot(..calls(), paths: [])))
}

// An `events` record written before the probes existed has no `traced` field
// and still reads.
pub fn an_older_events_record_has_no_result_test() {
  let line =
    "{\"t\":\"events\",\"track\":0,\"kind\":\"pass\",\"timestamps_ms\":[1],\"durations_ms\":[2],\"args\":[\"a\"]}"

  assert capture.decode_line(line, decode.string)
    == Ok(
      capture.EventsRecord(capture.Events(
        track: 0,
        kind: "pass",
        timestamps_ms: [1],
        durations_ms: [2],
        args: ["a"],
        traced: None,
      )),
    )
}

pub fn a_result_this_build_cannot_read_is_refused_test() {
  let good = text_of(trace_codec.events_json(events()))

  // A stop reason the build does not know.
  assert is_error(json.parse(
    string.replace(good, "\"deadline\"", "\"gave_up\""),
    trace_codec.events_decoder(),
  ))

  // A slice kind the build does not know.
  assert is_error(json.parse(
    string.replace(good, "\"gc_minor\"", "\"gc_huge\""),
    trace_codec.events_decoder(),
  ))

  // Parallel arrays of different lengths do not describe slices.
  assert is_error(json.parse(
    string.replace(
      good,
      "\"start_ns\":[1000000,1100000,3000000]",
      "\"start_ns\":[1]",
    ),
    trace_codec.events_decoder(),
  ))

  // A record that names one probe cannot carry the other's result.
  let line =
    capture.encode_record(
      capture.EventsRecord(capture.scheduling_events(events())),
      json.string,
    )
  let swapped =
    string.replace(
      line,
      "\"probe\":\"scheduling_gc\"",
      "\"probe\":\"call_tree\"",
    )

  assert is_error(capture.decode_line(swapped, decode.string))

  // A probe code that names neither.
  let unknown =
    string.replace(line, "\"probe\":\"scheduling_gc\"", "\"probe\":\"other\"")

  assert is_error(capture.decode_line(unknown, decode.string))
}

pub fn the_arrays_of_a_record_must_agree_test() {
  assert trace_codec.zip_slices([0, 1], [wire.RunSlice], [1, 2], [3, 4])
    == Error(Nil)
  assert trace_codec.zip_calls([0], [1], [2], [3], []) == Error(Nil)
  assert trace_codec.zip_slices([], [], [], []) == Ok([])
}

pub fn property_events_results_round_trip_test() {
  use snapshot <- gen.check(gen.events_snapshot())

  assert json.parse(
      text_of(trace_codec.events_json(snapshot)),
      trace_codec.events_decoder(),
    )
    == Ok(snapshot)
}

pub fn property_call_tree_results_round_trip_test() {
  use snapshot <- gen.check(gen.calltrace_snapshot())

  assert json.parse(
      text_of(trace_codec.calltrace_json(snapshot)),
      trace_codec.calltrace_decoder(),
    )
    == Ok(snapshot)
}

// Cutting the text of a result anywhere before its end leaves invalid JSON,
// and the decoder must say so.
pub fn property_truncated_results_are_refused_test() {
  use #(snapshot, cut) <- gen.check(gen.tuple2(
    gen.events_snapshot(),
    gen.non_negative(),
  ))
  let text = text_of(trace_codec.events_json(snapshot))
  let prefix = string.slice(text, 0, cut % string.length(text))

  assert is_error(json.parse(prefix, trace_codec.events_decoder()))
}

pub fn the_stop_codes_are_the_agents_spelling_test() {
  assert list.map(
      [
        wire.TraceRunning,
        wire.TraceDeadline,
        wire.TraceBudget,
        wire.TraceOverrun,
        wire.TraceTargetsGone,
        wire.TraceStopped,
      ],
      trace_codec.stop_code,
    )
    == [
      "running", "deadline", "event_budget", "overrun", "targets_gone",
      "stopped",
    ]
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// ---------------------------------------------------------- chrome trace

fn trace_events(body: String) -> List(#(String, String, Int, Float, Float)) {
  let event = {
    use ph <- decode.field("ph", decode.string)
    use name <- decode.field("name", decode.string)
    use tid <- decode.optional_field("tid", 0, decode.int)
    use ts <- decode.optional_field("ts", 0.0, decode.float)
    use dur <- decode.optional_field("dur", 0.0, decode.float)
    decode.success(#(ph, name, tid, ts, dur))
  }
  let assert Ok(events) =
    json.parse(
      body,
      decode.field("traceEvents", decode.list(event), decode.success),
    )
    as "the trace parses"

  list.map(events, fn(e) { #(e.0, e.1, e.2, e.3, e.4) })
}

// A scheduling probe becomes a thread per traced process holding its slices,
// and one more thread for the threshold events, each an instant.
pub fn a_scheduling_probe_exports_as_slices_and_instants_test() {
  let made = chrome_trace.events("probe-9", events(), fn(pid) { pid })
  let all = trace_events(made.body)

  // The slices of the first process, at their microsecond positions.
  let slices = list.filter(all, fn(e) { e.0 == "X" })

  assert list.map(slices, fn(e) { #(e.1, e.2, e.3, e.4) })
    == [
      #("run", 1, 1000.0, 250.0),
      #("gc minor", 1, 1100.0, 40.0),
      #("gc major", 1, 3000.0, 600.0),
    ]

  // One totals instant per process, and the two threshold instants.
  let instants = list.filter(all, fn(e) { e.0 == "i" })

  assert list.map(instants, fn(e) { #(e.1, e.2) })
    == [
      #("long_gc", 0),
      #("long_schedule", 0),
      #("totals", 1),
      #("totals", 2),
    ]

  // The threshold events carry no time of their own, so they sit at the end of
  // the observed window and the export says so.
  assert list.all(list.filter(instants, fn(e) { e.2 == 0 }), fn(e) {
    e.3 == 1_200_000.0
  })
  assert list.any(made.losses, string.contains(_, "no time"))

  // Thread names are the labels the caller gave.
  assert string.contains(made.body, "\"name\":\"<0.90.0>\"")
}

pub fn a_probe_with_no_threshold_events_has_no_node_wide_thread_test() {
  let quiet = wire.EventsSnapshot(..events(), long: [])
  let made = chrome_trace.events("p", quiet, fn(pid) { pid })

  assert !string.contains(made.body, "node-wide")
}

pub fn a_call_tree_exports_one_slice_per_call_test() {
  let made = chrome_trace.calls("probe-4", calls(), fn(pid) { pid })
  let slices = list.filter(trace_events(made.body), fn(e) { e.0 == "X" })

  assert list.map(slices, fn(e) { #(e.1, e.2, e.3, e.4) })
    == [#("lists:sort/1", 1, 0.01, 0.02), #("m:work/0", 1, 0.005, 0.04)]
  assert string.contains(made.body, "\"depth\":\"1\"")
  assert made.losses != []
}

pub fn the_trace_exports_are_deterministic_test() {
  assert chrome_trace.events("p", events(), fn(pid) { pid })
    == chrome_trace.events("p", events(), fn(pid) { pid })
}
