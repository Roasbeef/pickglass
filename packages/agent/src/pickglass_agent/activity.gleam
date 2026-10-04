//// The aggregate behind the scheduling and garbage collection probe: when
//// each target ran, and when it collected, folded from event pairs as they
//// arrive.
////
//// A process with the `running` trace flag sends `in` when a scheduler
//// starts running it and `out` when it stops, and with `garbage_collection`
//// it sends a start and an end for every minor and major collection. The
//// time between an `in` and its `out` is the closest the BEAM comes to a
//// per-process CPU time: it is wall time on a scheduler, so it excludes
//// waiting and includes any time the scheduler was itself descheduled by the
//// operating system. This module pairs the events per process, keeps totals,
//// and keeps the first `slice_limit` pairs as slices for a timeline.
////
//// An `out` with no `in` before it is a run that began before the probe did,
//// and an `end` with no matching `start` is the same for a collection. Both
//// are counted as unpaired and never turned into a slice of invented length.
//// A run or collection still open when the probe stops is closed at the latest
//// timestamp seen.
////
//// Beside the per-process events the probe may ask the VM for node-wide
//// threshold messages, `long_gc` and `long_schedule`, which name any process
//// whose collection or timeslice was slow. They arrive without a timestamp and
//// for processes the probe did not pin, so they are kept apart, bounded, and
//// only ever reported as what the VM said.
////
//// Everything here is pure over terms the VM produced and sends nothing.

import pickglass_agent/census
import pickglass_agent/internal/ffi_events.{type Collection}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}
import pickglass_agent/internal/seq

/// The most node-wide threshold events kept. Later ones are counted.
pub const max_long = 200

/// Whether a target is on a scheduler, and since when.
pub type Slot {
  Descheduled
  Scheduled(since: Int)
}

/// Whether a target is in a collection, which kind, and since when.
pub type Pause {
  NotCollecting
  Collecting(kind: Collection, since: Int)
}

/// One traced process: its position in the request's target list and what it
/// has accumulated. Times are native ticks.
pub type Process {
  Process(
    pid: Pid,
    index: Int,
    slot: Slot,
    pause: Pause,
    runs: Int,
    run_ticks: Int,
    minor_gcs: Int,
    major_gcs: Int,
    gc_ticks: Int,
  )
}

/// What a slice describes.
pub type SliceKind {
  Run
  MinorGc
  MajorGc
}

/// A closed run or collection kept for a timeline. `start` is the absolute
/// timestamp in native ticks.
pub type Slice {
  Slice(process: Int, kind: SliceKind, start: Int, duration: Int)
}

/// A node-wide threshold event, as the VM reported it. The two kinds carry
/// different facts, so they are different constructors.
pub type Long {
  /// A collection that took `duration_ms`, leaving `heap_words`.
  SlowCollection(pid: String, duration_ms: Int, heap_words: Int)

  /// A timeslice that lasted `duration_ms`, ending in `function`, which is
  /// empty when the VM named none.
  SlowTimeslice(pid: String, duration_ms: Int, function: String)
}

/// The accumulated activity.
pub type Activity {
  Activity(
    processes: List(Process),
    epoch: Int,
    latest: Int,
    slices: List(Slice),
    slice_count: Int,
    slice_limit: Int,
    slices_dropped: Int,
    unpaired: Int,
    long: List(Long),
    long_seen: Int,
    strays: Int,
  )
}

/// One target's totals, in nanoseconds.
pub type Totals {
  Totals(
    pid: String,
    runs: Int,
    run_ns: Int,
    minor_gcs: Int,
    major_gcs: Int,
    gc_ns: Int,
  )
}

/// A closed run or collection for a timeline. `start_ns` counts from the
/// tracer's start.
pub type Moment {
  Moment(process: Int, kind: SliceKind, start_ns: Int, duration_ns: Int)
}

/// A snapshot: totals per target in request order, the timeline in the order
/// slices closed, and the node-wide threshold events, with the counts that
/// say what they leave out. `unpaired` counts events whose partner was not
/// seen, `slices_dropped` the slices past the limit, `long_seen` every
/// threshold event including those past the list bound, and `strays` the
/// events for processes or of a shape the record could not use.
pub type Built {
  Built(
    totals: List(Totals),
    timeline: List(Moment),
    long: List(Long),
    unpaired: Int,
    slices_dropped: Int,
    long_seen: Int,
    strays: Int,
  )
}

/// An empty record over `targets`. `slice_limit` bounds the slices kept and
/// `epoch` is the native monotonic time slice starts are measured from.
///
/// ## Examples
///
/// ```gleam
/// new([pid], 100, monotonic_time(Native))
/// ```
pub fn new(targets: List(Pid), slice_limit: Int, epoch: Int) -> Activity {
  Activity(
    processes: processes_of(targets, 0),
    epoch: epoch,
    latest: epoch,
    slices: [],
    slice_count: 0,
    slice_limit: slice_limit,
    slices_dropped: 0,
    unpaired: 0,
    long: [],
    long_seen: 0,
    strays: 0,
  )
}

fn processes_of(targets: List(Pid), index: Int) -> List(Process) {
  case targets {
    [] -> []
    [pid, ..rest] -> [
      Process(pid, index, Descheduled, NotCollecting, 0, 0, 0, 0, 0),
      ..processes_of(rest, index + 1)
    ]
  }
}

/// Fold an `in` event.
///
/// ## Examples
///
/// ```gleam
/// scheduled_in(new([pid], 0, 0), pid, 10)
/// ```
pub fn scheduled_in(activity: Activity, pid: Pid, at: Int) -> Activity {
  with_process(activity, pid, at, fn(held, process) {
    case process.slot {
      Descheduled -> #(held, Process(..process, slot: Scheduled(at)))
      Scheduled(_) -> #(unpaired(held), Process(..process, slot: Scheduled(at)))
    }
  })
}

/// Fold an `out` event.
///
/// ## Examples
///
/// ```gleam
/// scheduled_out(scheduled_in(new([pid], 0, 0), pid, 10), pid, 30)
/// ```
pub fn scheduled_out(activity: Activity, pid: Pid, at: Int) -> Activity {
  with_process(activity, pid, at, fn(held, process) {
    case process.slot {
      Descheduled -> #(unpaired(held), process)
      Scheduled(since) -> #(
        keep_slice(held, process.index, Run, since, at - since),
        Process(
          ..process,
          slot: Descheduled,
          runs: process.runs + 1,
          run_ticks: process.run_ticks + non_negative(at - since),
        ),
      )
    }
  })
}

/// Fold a collection start.
///
/// ## Examples
///
/// ```gleam
/// collection_started(new([pid], 0, 0), pid, ffi_events.Minor, 10)
/// ```
pub fn collection_started(
  activity: Activity,
  pid: Pid,
  kind: Collection,
  at: Int,
) -> Activity {
  with_process(activity, pid, at, fn(held, process) {
    case process.pause {
      NotCollecting -> #(held, Process(..process, pause: Collecting(kind, at)))
      Collecting(_, _) -> #(
        unpaired(held),
        Process(..process, pause: Collecting(kind, at)),
      )
    }
  })
}

/// Fold a collection end. It pairs with the start of the same kind; an end
/// with no such start is unpaired.
///
/// ## Examples
///
/// ```gleam
/// collection_ended(collection_started(a, pid, ffi_events.Minor, 10), pid, ffi_events.Minor, 12)
/// ```
pub fn collection_ended(
  activity: Activity,
  pid: Pid,
  kind: Collection,
  at: Int,
) -> Activity {
  with_process(activity, pid, at, fn(held, process) {
    case process.pause {
      Collecting(started, since) if started == kind ->
        finish_collection(held, process, kind, since, at)
      Collecting(_, _) -> #(
        unpaired(held),
        Process(..process, pause: NotCollecting),
      )
      NotCollecting -> #(unpaired(held), process)
    }
  })
}

fn finish_collection(
  held: Activity,
  process: Process,
  kind: Collection,
  since: Int,
  at: Int,
) -> #(Activity, Process) {
  let spent = non_negative(at - since)
  let counted =
    Process(..process, pause: NotCollecting, gc_ticks: process.gc_ticks + spent)

  case kind {
    ffi_events.Minor -> #(
      keep_slice(held, process.index, MinorGc, since, spent),
      Process(..counted, minor_gcs: process.minor_gcs + 1),
    )
    ffi_events.Major -> #(
      keep_slice(held, process.index, MajorGc, since, spent),
      Process(..counted, major_gcs: process.major_gcs + 1),
    )
  }
}

/// Record a `long_gc` threshold event. `info` is the VM's property list.
///
/// ## Examples
///
/// ```gleam
/// long_collection(new([], 0, 0), pid, info)
/// ```
pub fn long_collection(activity: Activity, pid: Pid, info: Term) -> Activity {
  case milliseconds(info) {
    Error(Nil) -> Activity(..activity, strays: activity.strays + 1)
    Ok(duration) ->
      keep_long(
        activity,
        SlowCollection(
          ffi_term.pid_text(pid),
          duration,
          words(info, "heap_size"),
        ),
      )
  }
}

/// Record a `long_schedule` threshold event. `info` is the VM's property
/// list.
///
/// ## Examples
///
/// ```gleam
/// long_timeslice(new([], 0, 0), pid, info)
/// ```
pub fn long_timeslice(activity: Activity, pid: Pid, info: Term) -> Activity {
  case milliseconds(info) {
    Error(Nil) -> Activity(..activity, strays: activity.strays + 1)
    Ok(duration) ->
      keep_long(
        activity,
        SlowTimeslice(
          ffi_term.pid_text(pid),
          duration,
          census.function_text(property(info, "out")),
        ),
      )
  }
}

fn keep_long(activity: Activity, event: Long) -> Activity {
  let seen = Activity(..activity, long_seen: activity.long_seen + 1)

  case activity.long_seen < max_long {
    True -> Activity(..seen, long: [event, ..seen.long])
    False -> seen
  }
}

@external(erlang, "lists", "keyfind")
fn keyfind(key: Atom, position: Int, list: Term) -> Term

// The value of a `{Key, Value}` element of a property list, or the atom
// `undefined` when there is none or the list is not a proper list.
fn property(info: Term, key: String) -> Term {
  case ffi_safe.proper_length(info) {
    Error(Nil) -> ffi_term.coerce(ffi_term.atom("undefined"))
    Ok(_) -> {
      let found = keyfind(ffi_term.atom(key), 1, info)

      case ffi_term.is_tuple(found) && ffi_term.tuple_size(found) == 2 {
        True -> ffi_term.element(2, found)
        False -> ffi_term.coerce(ffi_term.atom("undefined"))
      }
    }
  }
}

fn milliseconds(info: Term) -> Result(Int, Nil) {
  let value = property(info, "timeout")

  case ffi_term.is_integer(value) {
    True -> Ok(ffi_term.coerce(value))
    False -> Error(Nil)
  }
}

fn words(info: Term, key: String) -> Int {
  let value = property(info, key)

  case ffi_term.is_integer(value) {
    True -> ffi_term.coerce(value)
    False -> 0
  }
}

/// Close every run and collection still open, at the latest timestamp seen.
///
/// ## Examples
///
/// ```gleam
/// close_all(scheduled_in(new([pid], 0, 0), pid, 10))
/// ```
pub fn close_all(activity: Activity) -> Activity {
  seq.fold(activity.processes, activity, fn(held, process) {
    let at = held.latest

    collection_ended_if_open(
      scheduled_out_if_open(held, process, at),
      process,
      at,
    )
  })
}

fn scheduled_out_if_open(
  held: Activity,
  process: Process,
  at: Int,
) -> Activity {
  case process.slot {
    Descheduled -> held
    Scheduled(_) -> scheduled_out(held, process.pid, at)
  }
}

fn collection_ended_if_open(
  held: Activity,
  process: Process,
  at: Int,
) -> Activity {
  case process.pause {
    NotCollecting -> held
    Collecting(kind, _) -> collection_ended(held, process.pid, kind, at)
  }
}

fn unpaired(held: Activity) -> Activity {
  Activity(..held, unpaired: held.unpaired + 1)
}

fn non_negative(value: Int) -> Int {
  case value < 0 {
    True -> 0
    False -> value
  }
}

// Applies a change to one target's record and to the activity, after noting
// the event's time. A pid that is not a target is a stray.
fn with_process(
  activity: Activity,
  pid: Pid,
  at: Int,
  change: fn(Activity, Process) -> #(Activity, Process),
) -> Activity {
  let timed = case at > activity.latest {
    True -> Activity(..activity, latest: at)
    False -> activity
  }

  case seq.find(timed.processes, fn(process) { process.pid == pid }) {
    Error(Nil) -> Activity(..timed, strays: timed.strays + 1)
    Ok(process) -> {
      let #(changed, updated) = change(timed, process)

      Activity(
        ..changed,
        processes: seq.map(changed.processes, fn(held) {
          case held.index == updated.index {
            True -> updated
            False -> held
          }
        }),
      )
    }
  }
}

fn keep_slice(
  activity: Activity,
  index: Int,
  kind: SliceKind,
  start: Int,
  duration: Int,
) -> Activity {
  case activity.slice_count < activity.slice_limit {
    True ->
      Activity(
        ..activity,
        slices: [
          Slice(index, kind, start, non_negative(duration)),
          ..activity.slices
        ],
        slice_count: activity.slice_count + 1,
      )
    False -> Activity(..activity, slices_dropped: activity.slices_dropped + 1)
  }
}

/// Turn the record into a snapshot. Open runs are not closed here; the
/// caller closes a copy first.
///
/// ## Examples
///
/// ```gleam
/// build(close_all(activity))
/// ```
pub fn build(activity: Activity) -> Built {
  Built(
    totals: seq.map(activity.processes, fn(process) {
      Totals(
        ffi_term.pid_text(process.pid),
        process.runs,
        nanoseconds(process.run_ticks),
        process.minor_gcs,
        process.major_gcs,
        nanoseconds(process.gc_ticks),
      )
    }),
    timeline: seq.map(seq.reverse(activity.slices), fn(slice) {
      Moment(
        slice.process,
        slice.kind,
        nanoseconds(non_negative(slice.start - activity.epoch)),
        nanoseconds(slice.duration),
      )
    }),
    long: seq.reverse(activity.long),
    unpaired: activity.unpaired,
    slices_dropped: activity.slices_dropped,
    long_seen: activity.long_seen,
    strays: activity.strays,
  )
}

fn nanoseconds(ticks: Int) -> Int {
  ffi_proc.convert_time(ticks, ffi_proc.Native, ffi_proc.Nanosecond)
}
