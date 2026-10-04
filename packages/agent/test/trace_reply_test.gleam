import pickglass_agent/activity
import pickglass_agent/calltree
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Term, coerce}
import pickglass_agent/reply
import pickglass_agent/stacks.{Frame, NoLocation}
import pickglass_agent/tracing.{Meter}

fn meter() -> tracing.Meter {
  Meter(
    elapsed_ms: 600,
    events: 40,
    max_events: 100,
    dropped_events: 3,
    in_flight_at_stop: 2,
    peak_queue: 9,
    queue_limit: 50_000,
    targets_gone: 1,
  )
}

// The shapes below are the contract `pickglass_core/wire` decodes. A change
// to a tuple here is a change to the decoder there, and this test says so.
pub fn the_call_tree_reply_has_the_documented_shape_test() {
  let built =
    calltree.Built(
      frames: [Frame("m", "f", 1, NoLocation)],
      paths: [calltree.Path(5, 100, 60, [0])],
      timeline: [calltree.Moment(0, 0, 10, 20, 0)],
      processes: ["<0.1.0>"],
      distinct_paths: 1,
      dropped_calls: 2,
      elided_calls: 3,
      forced_closes: 4,
      strays: 5,
    )
  let body: Term =
    coerce(reply.calltrace(7, "finished", tracing.EventBudget, meter(), built))

  assert body
    == coerce(#(
      "calltrace",
      7,
      "finished",
      "event_budget",
      #(
        "traced_call_return_to",
        600,
        40,
        100,
        3,
        2,
        9,
        50_000,
        1,
        4,
        1,
        2,
        3,
        5,
        calltree.max_depth,
      ),
      [#("m", "f", 1, #("none"))],
      [#(5, 100, 60, [0])],
      #(["<0.1.0>"], [#(0, 0, 10, 20, 0)]),
    ))
}

pub fn the_events_reply_has_the_documented_shape_test() {
  let built =
    activity.Built(
      totals: [activity.Totals("<0.1.0>", 3, 300, 1, 2, 50)],
      timeline: [
        activity.Moment(0, activity.Run, 10, 20),
        activity.Moment(0, activity.MinorGc, 30, 5),
        activity.Moment(0, activity.MajorGc, 40, 6),
      ],
      long: [
        activity.SlowCollection("<0.2.0>", 12, 4096),
        activity.SlowTimeslice("<0.3.0>", 30, "m:f/2"),
      ],
      unpaired: 4,
      slices_dropped: 5,
      long_seen: 6,
      strays: 7,
    )
  let body: Term =
    coerce(reply.events(7, "running", tracing.Overrun, meter(), built, 2, 0))

  assert body
    == coerce(
      #(
        "events",
        7,
        "running",
        "overrun",
        #(
          "traced_running_gc",
          600,
          40,
          100,
          3,
          2,
          9,
          50_000,
          1,
          4,
          5,
          6,
          7,
          2,
          0,
        ),
        [#("<0.1.0>", 3, 300, 1, 2, 50)],
        [
          #(0, "run", 10, 20),
          #(0, "gc_minor", 30, 5),
          #(0, "gc_major", 40, 6),
        ],
        [
          coerce(#("long_gc", "<0.2.0>", 12, 4096)),
          coerce(#("long_schedule", "<0.3.0>", 30, "m:f/2")),
        ],
      ),
    )
}

pub fn the_started_replies_echo_the_settled_values_test() {
  assert coerce(reply.calltrace_started(3, 2, 11, 500, 1000, 100))
    == coerce(#("calltrace_started", 3, 2, 11, 500, 1000, 100))
  assert coerce(reply.events_started(3, 2, 500, 1000, 100, 5, 0))
    == coerce(#("events_started", 3, 2, 500, 1000, 100, 5, 0))
  let _ = ffi_proc.self()
}
