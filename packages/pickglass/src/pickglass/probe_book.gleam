//// The probes the viewer started, what became of each, and what each
//// measured.
////
//// The agent keeps a probe only until the viewer reads or stops it, so
//// whatever a probe measured must be taken into the viewer when the probe
//// ends, or it is gone. This module is the viewer's record of that: a
//// `ProbeRecord` is created when the agent confirms a start, and when the
//// probe ends (its deadline, or the operator's stop) the agent's final
//// snapshot is turned into a core profile and the record becomes
//// `Finished`, carrying the profile, how the probe ended and what it cost.
////
//// The module is pure. The service decides when to ask the agent whether a
//// probe has ended; `finish_counters` is what it does with the answer.
////
//// A finished probe is also a part of a capture: its profile is a `profile`
//// record and its cost a `perturbation` record, tied together by the
//// probe's id. `to_records` writes them and `of_records` reads them back,
//// so a capture opened later, or compared against another, has the probe
//// history it was taken with. A call tree probe adds an `events` record with
//// the raw slices it kept for a timeline, and a scheduling and collection
//// probe, which measures per-process time and not call stacks and so has no
//// profile, is its `events` record alone. What a capture cannot say is when a probe
//// started or which module it named; those come back unknown and a replayed
//// probe says so.
////
//// ## Flow
////
//// - `started` records a probe the agent accepted.
//// - `finish_counters`, `finish_stacks`, `finish_calltrace` and
////   `finish_events` close it with the agent's last snapshot of its kind.
//// - `to_records` and `of_records` map finished probes to and from a
////   capture's records.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/calltrace_profile
import pickglass/counters_profile
import pickglass/profile_from_stacks
import pickglass_core/capture.{type Record}
import pickglass_core/measure.{Known, NotApplicable}
import pickglass_core/policy
import pickglass_core/profile.{type Profile}
import pickglass_core/wire
import pickglass_web/fmt

/// Where a probe is in its life.
pub type ProbeState {
  /// The agent is counting.
  Running

  /// The probe ended and its result was taken.
  Finished(
    /// When the viewer took the result, in wall-clock milliseconds.
    ended_ms: Int,
    /// How it ended. A counters probe that ran to its deadline or was
    /// stopped by the operator is `Complete` for the time it ran; one the
    /// agent no longer knew is `Errored`.
    outcome: measure.Outcome,
    /// What the probe cost the target, as far as is known.
    cost: capture.ProbeCost,
    /// What it measured, when it measured anything.
    profile: Option(Profile),
    /// Sentences about how far to trust the profile.
    notes: List(String),
  )
}

/// What a probe measured that a profile cannot hold.
pub type Detail {
  /// Nothing beyond the profile, if there is one.
  NoDetail

  /// A scheduling and collection probe's whole result: per-process totals,
  /// the run and collection slices, and the node-wide threshold events.
  SchedulingDetail(snapshot: wire.EventsSnapshot)

  /// A call tree probe's frame table, traced processes and the raw call
  /// slices it kept for a timeline. The paths are in its profile, so the
  /// snapshot held here has none.
  CallSlices(snapshot: wire.CalltraceSnapshot)
}

/// One probe.
pub type ProbeRecord {
  ProbeRecord(
    /// The agent's id for the probe, as text.
    id: String,
    kind: policy.ProbeKind,
    /// The module patterns the plan named. Empty for a probe read back from
    /// a capture, which does not record them.
    modules: List(String),
    /// When the agent confirmed the start. Zero for a probe read back from
    /// a capture.
    started_ms: Int,
    /// The planned length.
    duration_ms: Int,
    /// How many functions matched.
    matched: Int,
    state: ProbeState,
    /// What the probe measured besides its profile. Empty until the probe
    /// finishes.
    detail: Detail,
  )
}

/// A probe the agent accepted.
///
/// ## Examples
///
/// ```gleam
/// probe_book.started(7, policy.Counters, ["lists"], 1000, 30_000, 12)
/// ```
pub fn started(
  probe_id: Int,
  kind: policy.ProbeKind,
  modules: List(String),
  now_ms: Int,
  duration_ms: Int,
  matched: Int,
) -> ProbeRecord {
  ProbeRecord(
    id: int.to_string(probe_id),
    kind:,
    modules:,
    started_ms: now_ms,
    duration_ms:,
    matched:,
    state: Running,
    detail: NoDetail,
  )
}

/// Whether a probe is still counting.
pub fn is_running(probe: ProbeRecord) -> Bool {
  case probe.state {
    Running -> True
    Finished(..) -> False
  }
}

/// How long a running probe has left, never below zero. A finished probe
/// has none.
///
/// ## Examples
///
/// ```gleam
/// probe_book.remaining_ms(probe, 5000)
/// ```
pub fn remaining_ms(probe: ProbeRecord, now_ms: Int) -> Int {
  case probe.state {
    Running -> int.max(0, probe.started_ms + probe.duration_ms - now_ms)
    Finished(..) -> 0
  }
}

/// Close a counters probe with the agent's last snapshot. The profile is
/// built from the snapshot; if core refuses it the probe is `Errored` and
/// carries no profile, never an empty one.
///
/// ## Examples
///
/// ```gleam
/// probe_book.finish_counters(probe, snapshot, 31_000)
/// ```
pub fn finish_counters(
  probe: ProbeRecord,
  snapshot: wire.CountersSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  recorded(closed_finish_counters(probe, snapshot, now_ms))
}

fn closed_finish_counters(
  probe: ProbeRecord,
  snapshot: wire.CountersSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  let cost =
    capture.ProbeCost(
      probe: probe.id,
      enabled: ["call_time"],
      events: NotApplicable,
      collector_reductions: NotApplicable,
      bytes: NotApplicable,
      wall_ms: Known(snapshot.elapsed_ms),
      outcome: measure.Unrecorded,
      matched: None,
    )

  ProbeRecord(..probe, state: case counters_profile.build(snapshot) {
    Ok(built) ->
      Finished(
        ended_ms: now_ms,
        outcome: measure.Complete,
        cost:,
        profile: Some(built),
        notes: counter_notes(snapshot),
      )
    Error(_) ->
      Finished(
        ended_ms: now_ms,
        outcome: measure.Errored("the counters could not be read as a profile"),
        cost:,
        profile: None,
        notes: [],
      )
  })
}

/// Close a stack-sampling probe with the agent's aggregated stacks. The
/// stacks go through `profile_from_stacks`; a reply core refuses (a stack
/// naming a frame the table does not hold, an empty stack) closes the probe
/// as `Errored` with the reason and no profile. A probe that reached its
/// sample budget is `Partial`, and the notes say how many samples were not
/// kept and how many targets exited.
///
/// ## Examples
///
/// ```gleam
/// probe_book.finish_stacks(probe, snapshot, 41_000)
/// ```
pub fn finish_stacks(
  probe: ProbeRecord,
  snapshot: wire.StacksSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  recorded(closed_finish_stacks(probe, snapshot, now_ms))
}

fn closed_finish_stacks(
  probe: ProbeRecord,
  snapshot: wire.StacksSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  let meter = snapshot.meter
  let cost =
    capture.ProbeCost(
      probe: probe.id,
      enabled: ["current_stacktrace"],
      events: Known(meter.samples),
      collector_reductions: NotApplicable,
      bytes: NotApplicable,
      wall_ms: Known(meter.elapsed_ms),
      outcome: measure.Unrecorded,
      matched: None,
    )

  case aggregated_of(snapshot) {
    Error(reason) ->
      ProbeRecord(
        ..probe,
        state: Finished(
          ended_ms: now_ms,
          outcome: measure.Errored(reason),
          cost:,
          profile: None,
          notes: [],
        ),
      )
    Ok(input) ->
      case profile_from_stacks.build(input) {
        Error(refusal) ->
          ProbeRecord(
            ..probe,
            state: Finished(
              ended_ms: now_ms,
              outcome: measure.Errored(
                "the sampled stacks could not be read as a profile ("
                <> string.inspect(refusal)
                <> ")",
              ),
              cost:,
              profile: None,
              notes: [],
            ),
          )
        Ok(built) ->
          ProbeRecord(
            ..probe,
            state: Finished(
              ended_ms: now_ms,
              outcome: case snapshot.stop {
                wire.SamplingBudget ->
                  measure.Partial(measure.Truncated(measure.BudgetReached))
                wire.SamplingRunning
                | wire.SamplingDeadline
                | wire.SamplingTargetsGone
                | wire.SamplingStopped -> measure.Complete
              },
              cost:,
              profile: Some(built),
              notes: list.append(
                profile_from_stacks.caveats(input),
                stack_notes(meter),
              ),
            ),
          )
      }
  }
}

/// Close a call tree probe with the agent's last snapshot. The paths go
/// through `calltrace_profile`; a reply core refuses (a path naming a frame
/// the table does not hold) closes the probe as `Errored` with no profile.
/// A probe that hit its event budget is `Partial` with that reason, and one
/// the agent stopped because the collector fell behind is `Partial` with
/// `CollectorOverrun`; the notes say what was dropped either way. The raw
/// call slices the probe kept for a timeline are kept as the record's
/// detail.
///
/// ## Examples
///
/// ```gleam
/// probe_book.finish_calltrace(probe, snapshot, 41_000)
/// ```
pub fn finish_calltrace(
  probe: ProbeRecord,
  snapshot: wire.CalltraceSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  recorded(closed_finish_calltrace(probe, snapshot, now_ms))
}

fn closed_finish_calltrace(
  probe: ProbeRecord,
  snapshot: wire.CalltraceSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  let trace = snapshot.meter.trace
  let cost =
    capture.ProbeCost(
      probe: probe.id,
      enabled: ["call", "return_to"],
      events: Known(trace.events),
      collector_reductions: NotApplicable,
      bytes: NotApplicable,
      wall_ms: Known(trace.elapsed_ms),
      outcome: measure.Unrecorded,
      matched: None,
    )

  case calltrace_profile.build(snapshot) {
    Error(_) ->
      ProbeRecord(
        ..probe,
        state: Finished(
          ended_ms: now_ms,
          outcome: measure.Errored(
            "the call paths could not be read as a profile",
          ),
          cost:,
          profile: None,
          notes: [],
        ),
      )
    Ok(built) ->
      ProbeRecord(
        ..probe,
        state: Finished(
          ended_ms: now_ms,
          outcome: trace_outcome(snapshot.stop),
          cost:,
          profile: Some(built),
          notes: case snapshot.paths {
            [] -> [
              "No call to a traced function happened in the window.",
              ..calltrace_profile.caveats(snapshot)
            ]
            [_, ..] -> calltrace_profile.caveats(snapshot)
          },
        ),
        detail: CallSlices(wire.CalltraceSnapshot(..snapshot, paths: [])),
      )
  }
}

/// Close a scheduling and garbage collection probe with the agent's last
/// snapshot. There is no profile: the result is per-process totals and
/// slices, kept whole as the record's detail. The outcome and notes follow
/// the same stop reasons as a call tree probe's.
///
/// ## Examples
///
/// ```gleam
/// probe_book.finish_events(probe, snapshot, 41_000)
/// ```
pub fn finish_events(
  probe: ProbeRecord,
  snapshot: wire.EventsSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  recorded(closed_finish_events(probe, snapshot, now_ms))
}

fn closed_finish_events(
  probe: ProbeRecord,
  snapshot: wire.EventsSnapshot,
  now_ms: Int,
) -> ProbeRecord {
  let trace = snapshot.meter.trace
  let thresholds =
    list.flatten([
      case snapshot.meter.long_gc_ms {
        0 -> []
        _ -> ["long_gc"]
      },
      case snapshot.meter.long_schedule_ms {
        0 -> []
        _ -> ["long_schedule"]
      },
    ])

  ProbeRecord(
    ..probe,
    state: Finished(
      ended_ms: now_ms,
      outcome: trace_outcome(snapshot.stop),
      cost: capture.ProbeCost(
        probe: probe.id,
        enabled: list.append(["running", "garbage_collection"], thresholds),
        events: Known(trace.events),
        collector_reductions: NotApplicable,
        bytes: NotApplicable,
        wall_ms: Known(trace.elapsed_ms),
        outcome: measure.Unrecorded,
        matched: None,
      ),
      profile: None,
      notes: events_notes(snapshot),
    ),
    detail: SchedulingDetail(snapshot),
  )
  |> recorded
}

// How a tracing probe's stop reason reads as an outcome. The window, the
// operator and the exit of every target are complete for what they covered;
// the event budget and a collector that fell behind each cut the probe short
// of its window.
fn trace_outcome(stop: wire.TraceStop) -> measure.Outcome {
  case stop {
    wire.TraceBudget ->
      measure.Partial(measure.Truncated(measure.BudgetReached))
    wire.TraceOverrun ->
      measure.Partial(measure.Truncated(measure.CollectorOverrun))
    wire.TraceRunning
    | wire.TraceDeadline
    | wire.TraceTargetsGone
    | wire.TraceStopped -> measure.Complete
  }
}

// What a scheduling probe says about how far to trust it: how it ended, what
// its queue lost, what its results leave out, and whether the node-wide
// thresholds were in force.
fn events_notes(snapshot: wire.EventsSnapshot) -> List(String) {
  let meter = snapshot.meter

  list.flatten([
    [calltrace_profile.stop_text(snapshot.stop, meter.trace)],
    calltrace_profile.lost_text(meter.trace),
    count_note(
      meter.unpaired_events,
      " events had no start or end to pair with, such as a run that began before the probe, and are not in any slice.",
    ),
    count_note(
      meter.dropped_slices,
      " slices were past the slice limit and are counted in the totals but not drawn.",
    ),
    count_note(
      meter.trace.targets_gone,
      " traced processes exited while the probe ran.",
    ),
    case meter.long_gc_ms, meter.long_schedule_ms {
      0, 0 -> [
        "The node-wide long collection and long timeslice thresholds were not set, so no such events were watched for.",
      ]
      gc, schedule -> [
        "Node-wide thresholds: collections of "
        <> fmt.count(gc)
        <> " ms or more and timeslices of "
        <> fmt.count(schedule)
        <> " ms or more are reported for any process on the node, not only the traced ones; "
        <> fmt.count(meter.long_events_seen)
        <> " were seen, and the agent keeps the first 200.",
      ]
    },
    [
      "Time on a scheduler is the closest the BEAM comes to per-process CPU time, and includes any time the operating system took the scheduler thread away.",
    ],
  ])
}

fn count_note(count: Int, rest: String) -> List(String) {
  case count {
    0 -> []
    _ -> [fmt.count(count) <> rest]
  }
}

fn stack_notes(meter: wire.SamplerMeter) -> List(String) {
  let achieved = meter.achieved_millihz / 1000

  list.flatten([
    [
      "Sampled "
      <> int.to_string(meter.samples)
      <> " times at "
      <> int.to_string(achieved)
      <> " Hz achieved of "
      <> int.to_string(meter.requested_hz)
      <> " requested.",
    ],
    case meter.targets_gone {
      0 -> []
      count -> [
        int.to_string(count) <> " targets exited while the probe ran.",
      ]
    },
  ])
}

// The agent's frame table and index lists as the adapter's input. A stack
// naming a frame outside the table is a defect of the reply and refuses the
// whole result rather than guessing the frame.
fn aggregated_of(
  snapshot: wire.StacksSnapshot,
) -> Result(profile_from_stacks.Aggregated, String) {
  let frames =
    list.map(snapshot.frames, fn(frame) {
      let #(file, line) = case frame.location {
        wire.NoLocation -> #(None, None)
        wire.FileOnly(file:) -> #(Some(file), None)
        wire.AtLine(file:, line:) -> #(Some(file), Some(line))
      }

      profile_from_stacks.Frame(
        module: frame.module,
        function: frame.function,
        arity: frame.arity,
        file:,
        line:,
      )
    })

  use stacks <- result.map(
    list.try_map(snapshot.stacks, fn(stack) {
      list.try_map(stack.frames, fn(index) {
        list.drop(frames, index) |> list.first
      })
      |> result.map(fn(resolved) {
        profile_from_stacks.Stack(
          frames: resolved,
          count: stack.count,
          status: Some(stack.status),
        )
      })
    })
    |> result.replace_error(
      "a sampled stack names a frame the agent did not list",
    ),
  )

  let dropped =
    snapshot.meter.dropped_samples + snapshot.meter.truncated_samples

  profile_from_stacks.Aggregated(
    method: "process_info current_stacktrace",
    rate_hz: snapshot.meter.requested_hz,
    depth_limit: snapshot.meter.depth_limit,
    completeness: case dropped {
      0 -> profile_from_stacks.AllStacks
      _ -> profile_from_stacks.CutShort(dropped_samples: dropped)
    },
    stacks:,
  )
}

fn counter_notes(snapshot: wire.CountersSnapshot) -> List(String) {
  let base = [
    "No call stacks: a counters probe counts calls per function and cannot draw a flame graph or a call graph.",
    "Call time sums over every traced process, and calls are not split by process.",
    "Time spent in untraced callees is charged to the nearest traced caller.",
  ]

  case snapshot.invalidated {
    0 -> base
    count ->
      list.append(base, [
        int.to_string(count)
        <> " traced functions were invalidated by a module reload; this snapshot is suspect.",
      ])
  }
}

/// A probe that ended without the agent's answer: the agent no longer knew
/// it, or the target went away. It is closed with the reason and no
/// profile.
///
/// ## Examples
///
/// ```gleam
/// probe_book.finish_lost(probe, "the agent no longer has the probe", 9000)
/// ```
pub fn finish_lost(
  probe: ProbeRecord,
  reason: String,
  now_ms: Int,
) -> ProbeRecord {
  recorded(closed_finish_lost(probe, reason, now_ms))
}

fn closed_finish_lost(
  probe: ProbeRecord,
  reason: String,
  now_ms: Int,
) -> ProbeRecord {
  ProbeRecord(
    ..probe,
    state: Finished(
      ended_ms: now_ms,
      outcome: measure.Errored(reason),
      cost: capture.ProbeCost(
        probe: probe.id,
        enabled: ["call_time"],
        events: NotApplicable,
        collector_reductions: NotApplicable,
        bytes: NotApplicable,
        wall_ms: measure.Missing(measure.ProcessExited),
        outcome: measure.Unrecorded,
        matched: None,
      ),
      profile: None,
      notes: [],
    ),
  )
}

// The cost record is what a capture keeps of a finished probe, so it must
// say how the probe ended and how much the agent matched; the closing
// functions build it without those and this fills them in from the state they
// chose.
fn recorded(probe: ProbeRecord) -> ProbeRecord {
  case probe.state {
    Running -> probe
    Finished(ended_ms:, outcome:, cost:, profile:, notes:) ->
      ProbeRecord(
        ..probe,
        state: Finished(
          ended_ms:,
          outcome:,
          cost: capture.ProbeCost(
            ..cost,
            outcome:,
            matched: Some(probe.matched),
          ),
          profile:,
          notes:,
        ),
      )
  }
}

/// Keep every running probe and the newest `keep` finished ones, from a list
/// newest first, and say how many finished ones were let go. A finished probe
/// holds a profile, so without a bound a long session grows by one per probe.
///
/// ## Examples
///
/// ```gleam
/// probe_book.bound(probes, 50)
/// // -> #(kept, 3)
/// ```
pub fn bound(
  probes: List(ProbeRecord),
  keep: Int,
) -> #(List(ProbeRecord), Int) {
  let #(kept, dropped, _) =
    list.fold(probes, #([], 0, 0), fn(state, probe) {
      let #(kept, dropped, finished) = state

      case is_running(probe), finished >= keep {
        True, _ -> #([probe, ..kept], dropped, finished)
        False, False -> #([probe, ..kept], dropped, finished + 1)
        False, True -> #(kept, dropped + 1, finished)
      }
    })

  #(list.reverse(kept), dropped)
}

/// The newest finished probe that has a profile, from a list newest first.
///
/// ## Examples
///
/// ```gleam
/// probe_book.latest_profiled(probes)
/// ```
pub fn latest_profiled(
  probes: List(ProbeRecord),
) -> Result(#(ProbeRecord, Profile), Nil) {
  list.find_map(probes, fn(probe) {
    case probe.state {
      Finished(profile: Some(found), ..) -> Ok(#(probe, found))
      Finished(profile: None, ..) | Running -> Error(Nil)
    }
  })
}

// ------------------------------------------------------------------ capture

/// The capture records of the finished probes, oldest first. A probe that
/// is still running is not a capture's business.
///
/// ## Examples
///
/// ```gleam
/// probe_book.to_records(probes)
/// ```
pub fn to_records(probes: List(ProbeRecord)) -> List(Record(Profile)) {
  probes
  |> list.reverse
  |> list.flat_map(fn(probe) {
    case probe.state, int.parse(probe.id) {
      Running, _ -> []
      Finished(cost:, profile:, ..), Ok(number) ->
        list.flatten([
          [capture.ProbeCostRecord(cost)],
          case profile {
            Some(found) -> [
              capture.ProfileRecord(capture.Profile(
                id: number,
                source: source_of(profile.source(found)),
                payload: found,
              )),
            ]
            None -> []
          },
          detail_records(probe.detail),
        ])
      Finished(..), Error(Nil) -> []
    }
  })
}

// A tracing probe's slices and totals are an `events` record, which carries
// the probe's whole result so a replay draws what the live page drew.
fn detail_records(detail: Detail) -> List(Record(Profile)) {
  case detail {
    NoDetail -> []
    SchedulingDetail(snapshot:) -> [
      capture.EventsRecord(capture.scheduling_events(snapshot)),
    ]
    CallSlices(snapshot:) -> [
      capture.EventsRecord(capture.call_tree_events(snapshot)),
    ]
  }
}

fn source_of(source: profile.Source) -> capture.ProfileSource {
  case source {
    profile.SampledStacks(..) -> capture.SampledStacks
    profile.TracedCalls -> capture.TracedCalls
    profile.TracedCounters -> capture.TracedCounters
    profile.AllocationCounts -> capture.AllocationCounts
  }
}

/// The probes a capture's records describe, newest first. Each cost record
/// is a probe; its profile is the profile record with the same id.
///
/// ## Examples
///
/// ```gleam
/// probe_book.of_records(capture.records)
/// ```
pub fn of_records(records: List(Record(Profile))) -> List(ProbeRecord) {
  let profiles =
    list.filter_map(records, fn(record) {
      case record {
        capture.ProfileRecord(found) -> Ok(found)
        _ -> Error(Nil)
      }
    })

  let traced =
    list.filter_map(records, fn(record) {
      case record {
        capture.EventsRecord(capture.Events(traced: Some(found), ..)) ->
          Ok(found)
        _ -> Error(Nil)
      }
    })

  records
  |> list.filter_map(fn(record) {
    case record {
      capture.ProbeCostRecord(cost) -> Ok(probe_of(cost, profiles, traced))
      _ -> Error(Nil)
    }
  })
  |> list.reverse
}

// The tracing result a cost record's probe left, by the probe's id.
fn detail_of(cost: capture.ProbeCost, traced: List(capture.Traced)) -> Detail {
  case
    list.find(traced, fn(found) {
      case found {
        capture.SchedulingTraced(snapshot:) ->
          int.to_string(snapshot.probe_id) == cost.probe
        capture.CallTreeTraced(snapshot:) ->
          int.to_string(snapshot.probe_id) == cost.probe
      }
    })
  {
    Ok(capture.SchedulingTraced(snapshot:)) -> SchedulingDetail(snapshot)
    Ok(capture.CallTreeTraced(snapshot:)) -> CallSlices(snapshot)
    Error(Nil) -> NoDetail
  }
}

fn probe_of(
  cost: capture.ProbeCost,
  profiles: List(capture.Profile(Profile)),
  traced: List(capture.Traced),
) -> ProbeRecord {
  let detail = detail_of(cost, traced)

  let found =
    int.parse(cost.probe)
    |> result.try(fn(number) {
      list.find(profiles, fn(candidate) { candidate.id == number })
    })
    |> option.from_result

  ProbeRecord(
    id: cost.probe,
    kind: case found {
      Some(capture.Profile(source: capture.SampledStacks, ..)) ->
        policy.Sampling
      Some(capture.Profile(source: capture.TracedCalls, ..)) -> policy.CallTree
      Some(capture.Profile(source: capture.TracedCounters, ..))
      | Some(capture.Profile(source: capture.AllocationCounts, ..)) ->
        policy.Counters
      None ->
        case detail {
          SchedulingDetail(..) -> policy.SchedulingGc
          CallSlices(..) -> policy.CallTree
          NoDetail -> policy.Counters
        }
    },
    modules: [],
    started_ms: 0,
    duration_ms: 0,
    // A capture that did not keep the match count has no request to put
    // the profile's size against, so the profile's own size stands in.
    matched: option.unwrap(cost.matched, case found {
      Some(item) -> list.length(profile.samples(item.payload))
      None -> 0
    }),
    state: Finished(
      ended_ms: 0,
      outcome: cost.outcome,
      cost:,
      profile: option.map(found, fn(item) { item.payload }),
      notes: ["Read from a capture: when the probe ran is not recorded."],
    ),
    detail:,
  )
}
