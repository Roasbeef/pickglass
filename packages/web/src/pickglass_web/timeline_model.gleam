//// The models of the Timeline page.
////
//// The page draws two kinds of evidence, and these are the types it is fed.
//// The first is readings the viewer took at its own passes: counters polled
//// at an interval, drawn as steps and never interpolated, spans of host
//// operations, and the stretches where evidence was lost. The second is what
//// a tracing probe saw. A scheduling and collection probe and a call tree probe
//// each leave slices with a start and a length, counted from the probe's own
//// start, so they are drawn below the polled tracks on a time axis of their
//// own: the viewer's passes are stamped on the wall clock, and nothing aligns
//// the two.
////
//// The tracing types hold, for each traced process, a track of slices and the
//// totals the probe counted over its whole window (the slices are only the
//// first ones to close), the node-wide threshold events as the VM reported
//// them with no time, and the sentences about how the probe ended. They live
//// apart from `pickglass_web/model` because they describe one page's evidence
//// and `model` is a list of pages.
////
//// Every reading is a `Measurement` or an integer count or duration, and a
//// missing reading is never a zero.

import gleam/option.{type Option}
import pickglass_core/measure.{type Measurement}
import pickglass_core/unit.{type Unit}
import pickglass_web/model.{type PanelInfo}

/// A stretch where evidence was lost.
pub type CoverageGap {
  CoverageGap(
    /// Start, in milliseconds from the window start.
    from_ms: Int,
    /// End, in milliseconds from the window start.
    to_ms: Int,
    /// Events dropped inside the gap, when known.
    dropped: Measurement,
    /// Why it was lost.
    reason: String,
  )
}

/// A reading with the width of time it stands for.
pub type Step {
  Step(
    /// When the reading was taken, in milliseconds from the window start.
    at_ms: Int,
    /// How long it stands for: the sampling interval.
    width_ms: Int,
    /// The reading.
    value: Measurement,
  )
}

/// A span of an operation.
pub type Span {
  Span(
    /// Start, in milliseconds from the window start.
    at_ms: Int,
    /// Length in milliseconds.
    length_ms: Int,
    /// The operation name.
    label: String,
  )
}

/// A row of the timeline.
pub type Track {
  /// A polled counter, drawn as steps and never interpolated.
  CounterTrack(label: String, unit: Unit, steps: List(Step))

  /// Operation spans reported by the host.
  SpanTrack(label: String, spans: List(Span))
}

/// What one slice of a traced process was doing.
pub type ActivityKind {
  /// The process was running on a scheduler.
  RunActivity

  /// A minor (young generation) garbage collection.
  MinorGcActivity

  /// A major (full sweep) garbage collection.
  MajorGcActivity
}

/// One run or collection of a traced process. Times count from the start of
/// the probe.
pub type ActivitySlice {
  ActivitySlice(start_ns: Int, duration_ns: Int, kind: ActivityKind)
}

/// One traced process: a track of slices and the totals the probe counted,
/// which cover the whole window even when the slices kept are fewer.
pub type TracedTrack {
  TracedTrack(
    /// The process, as the pid text with its owner when known.
    label: String,
    /// Runs counted.
    runs: Int,
    /// Time on a scheduler, in nanoseconds.
    run_ns: Int,
    /// Minor collections counted.
    minor_gcs: Int,
    /// Major collections counted.
    major_gcs: Int,
    /// Time collecting, in nanoseconds.
    gc_ns: Int,
    /// The slices kept, oldest first.
    slices: List(ActivitySlice),
  )
}

/// A collection or timeslice the VM reported as longer than a node-wide
/// threshold. It concerns any process on the node, and the agent reports no
/// time for it.
pub type LongMarker {
  LongGcMarker(process: String, duration_ms: Int, heap_words: Int)
  LongScheduleMarker(process: String, duration_ms: Int, function: String)
}

/// A scheduling and collection probe's timeline.
pub type EventsTimeline {
  EventsTimeline(
    /// The probe's id.
    probe: String,
    /// Where it came from and how it ended.
    info: PanelInfo,
    /// The window the probe was asked for, in nanoseconds.
    window_ns: Int,
    /// How long it observed before it stopped, in nanoseconds. The part of
    /// the window after it is drawn unshaded: nothing was watched there.
    observed_ns: Int,
    /// One track per traced process, in the order the probe named them.
    tracks: List(TracedTrack),
    /// The threshold events, as the agent reported them.
    long: List(LongMarker),
    /// The two thresholds in force, in milliseconds; zero is off.
    long_gc_ms: Int,
    long_schedule_ms: Int,
    /// How many threshold events the VM reported, kept or not.
    long_seen: Int,
    /// What to be careful about, among them how the probe stopped and what
    /// it dropped.
    notes: List(String),
  )
}

/// One call of a call tree probe, as a slice nested at its depth.
pub type CallBox {
  CallBox(name: String, start_ns: Int, duration_ns: Int, depth: Int)
}

/// One traced process's calls.
pub type CallTrack {
  CallTrack(label: String, calls: List(CallBox))
}

/// A call tree probe's timeline: the first calls to finish, per process,
/// nested by depth.
pub type CallsTimeline {
  CallsTimeline(
    /// The probe's id.
    probe: String,
    /// Where it came from and how it ended.
    info: PanelInfo,
    /// The window the probe was asked for, in nanoseconds.
    window_ns: Int,
    /// How long it observed before it stopped, in nanoseconds.
    observed_ns: Int,
    /// One track per traced process.
    tracks: List(CallTrack),
    /// What to be careful about.
    notes: List(String),
  )
}

/// The timeline page.
pub type TimelineModel {
  TimelineModel(
    /// Where the timeline came from.
    info: PanelInfo,
    /// The window length in milliseconds.
    window_ms: Int,
    /// The clock the tracks share and its error.
    clock_note: String,
    /// The tracks.
    tracks: List(Track),
    /// Where evidence was dropped.
    gaps: List(CoverageGap),
    /// The newest scheduling and collection probe, drawn on a time axis of
    /// its own.
    events: Option(EventsTimeline),
    /// The newest call tree probe that kept call slices, likewise.
    calls: Option(CallsTimeline),
  )
}
