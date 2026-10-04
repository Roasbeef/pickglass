import gleam/list
import pickglass_agent/activity.{type Activity}
import pickglass_agent/internal/ffi_events.{Major, Minor}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term, coerce}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

fn blocked() -> Pid {
  let #(pid, _) = ffi_proc.spawn_opt(fn() { sleep(60_000) }, [ffi_proc.Monitor])

  pid
}

fn ns(ticks: Int) -> Int {
  ffi_proc.convert_time(ticks, ffi_proc.Native, ffi_proc.Nanosecond)
}

fn start(targets: List(Pid)) -> Activity {
  activity.new(targets, 100, 0)
}

fn totals_of(built: activity.Built) -> activity.Totals {
  case built.totals {
    [first, ..] -> first
    [] -> activity.Totals("", 0, 0, 0, 0, 0)
  }
}

// An `in` and the `out` after it are one run, and the time between them is
// the process's time on a scheduler.
pub fn runs_are_paired_and_timed_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> activity.scheduled_in(pid, 100)
    |> activity.scheduled_out(pid, 160)
    |> activity.scheduled_in(pid, 200)
    |> activity.scheduled_out(pid, 210)
    |> activity.build

  let totals = totals_of(built)

  assert totals.runs == 2
  assert totals.run_ns == ns(70)
  assert built.timeline
    == [
      activity.Moment(0, activity.Run, ns(100), ns(60)),
      activity.Moment(0, activity.Run, ns(200), ns(10)),
    ]
  assert built.unpaired == 0
}

// Minor and major collections are counted apart and their time is summed.
pub fn collections_are_paired_by_kind_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> activity.collection_started(pid, Minor, 10)
    |> activity.collection_ended(pid, Minor, 14)
    |> activity.collection_started(pid, Major, 20)
    |> activity.collection_ended(pid, Major, 50)
    |> activity.build

  let totals = totals_of(built)

  assert totals.minor_gcs == 1
  assert totals.major_gcs == 1
  assert totals.gc_ns == ns(34)
  assert built.timeline
    == [
      activity.Moment(0, activity.MinorGc, ns(10), ns(4)),
      activity.Moment(0, activity.MajorGc, ns(20), ns(30)),
    ]
}

// An `out` with no `in`, an `in` after an `in`, and an end that does not
// match the start are counted as unpaired and never become a slice of
// invented length.
pub fn unpaired_events_are_counted_not_invented_test() {
  let pid = blocked()
  let built =
    start([pid])
    |> activity.scheduled_out(pid, 5)
    |> activity.scheduled_in(pid, 10)
    |> activity.scheduled_in(pid, 12)
    |> activity.collection_ended(pid, Minor, 15)
    |> activity.collection_started(pid, Minor, 16)
    |> activity.collection_ended(pid, Major, 18)
    |> activity.build

  assert built.unpaired == 4
  assert built.timeline == []
  assert totals_of(built).runs == 0
}

// A run or a collection still open when the probe stops closes at the latest
// timestamp seen.
pub fn open_runs_close_at_the_latest_timestamp_test() {
  let pid = blocked()
  let other = blocked()
  let built =
    start([pid, other])
    |> activity.scheduled_in(pid, 10)
    |> activity.collection_started(pid, Minor, 40)
    |> activity.scheduled_in(other, 90)
    |> activity.close_all
    |> activity.build

  assert list.map(built.totals, fn(totals) { totals.runs }) == [1, 1]
  assert built.timeline
    == [
      activity.Moment(0, activity.Run, ns(10), ns(80)),
      activity.Moment(0, activity.MinorGc, ns(40), ns(50)),
      activity.Moment(1, activity.Run, ns(90), ns(0)),
    ]
}

pub fn events_of_other_processes_are_strays_test() {
  let pid = blocked()
  let stranger = blocked()
  let built =
    start([pid])
    |> activity.scheduled_in(stranger, 1)
    |> activity.collection_started(stranger, Minor, 1)
    |> activity.build

  assert built.strays == 2
  assert totals_of(built).runs == 0
}

// The slices kept are bounded, the totals are not, and the ones left out are
// counted.
pub fn slices_are_bounded_and_totals_are_not_test() {
  let pid = blocked()
  let held =
    list.fold(list.repeat(Nil, 10), activity.new([pid], 4, 0), fn(held, _) {
      held
      |> activity.scheduled_in(pid, 1)
      |> activity.scheduled_out(pid, 3)
    })
  let built = activity.build(held)

  assert list.length(built.timeline) == 4
  assert built.slices_dropped == 6
  assert totals_of(built).runs == 10
}

fn info(entries: List(#(String, Term))) -> Term {
  coerce(list.map(entries, fn(entry) { #(ffi_term.atom(entry.0), entry.1) }))
}

// A threshold event keeps what the VM said: the duration, and the heap or the
// function. One that is not a property list with a timeout is a stray.
pub fn threshold_events_keep_what_the_vm_said_test() {
  let pid = blocked()
  let function = coerce(#(ffi_term.atom("m"), ffi_term.atom("f"), 2))
  let built =
    start([])
    |> activity.long_collection(
      pid,
      info([#("timeout", coerce(12)), #("heap_size", coerce(4096))]),
    )
    |> activity.long_timeslice(
      pid,
      info([
        #("timeout", coerce(30)),
        #("in", coerce(ffi_term.atom("undefined"))),
        #("out", function),
      ]),
    )
    |> activity.long_collection(pid, coerce("garbage"))
    |> activity.long_timeslice(pid, info([#("out", function)]))
    |> activity.build

  let text = ffi_term.pid_text(pid)

  assert built.long
    == [
      activity.SlowCollection(text, 12, 4096),
      activity.SlowTimeslice(text, 30, "m:f/2"),
    ]
  assert built.long_seen == 2
  assert built.strays == 2
}

// Threshold events past the list bound are counted and not kept.
pub fn threshold_events_are_bounded_test() {
  let pid = blocked()
  let held =
    list.fold(list.repeat(Nil, activity.max_long + 5), start([]), fn(held, _) {
      activity.long_collection(held, pid, info([#("timeout", coerce(3))]))
    })
  let built = activity.build(held)

  assert list.length(built.long) == activity.max_long
  assert built.long_seen == activity.max_long + 5
}
