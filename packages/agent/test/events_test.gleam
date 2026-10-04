import pickglass_agent/internal/ffi_events.{
  Called, CollectionEnded, CollectionStarted, LongCollection, LongTimeslice,
  Major, Minor, NotTrace, ReturnedTo, ScheduledIn, ScheduledOut,
}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Term, coerce}

fn atom(name: String) -> ffi_term.Atom {
  ffi_term.atom(name)
}

fn stamped(tag: String, info: a) -> Term {
  coerce(#(atom("trace_ts"), ffi_proc.self(), atom(tag), info, 42))
}

// Every tag the probes ask the VM for decodes to its own event, with the
// timestamp and the pid the VM stamped.
pub fn stamped_events_decode_test() {
  let function = coerce(#(atom("m"), atom("f"), 1))
  let me = ffi_proc.self()

  assert ffi_events.decode(stamped("call", function))
    == Called(me, function, coerce(atom("undefined")), 42)
  assert ffi_events.decode(stamped("return_to", function))
    == ReturnedTo(me, function, 42)
  assert ffi_events.decode(stamped("in", function)) == ScheduledIn(me, 42)
  assert ffi_events.decode(stamped("out", function)) == ScheduledOut(me, 42)
  assert ffi_events.decode(stamped("gc_minor_start", []))
    == CollectionStarted(me, Minor, 42)
  assert ffi_events.decode(stamped("gc_minor_end", []))
    == CollectionEnded(me, Minor, 42)
  assert ffi_events.decode(stamped("gc_major_start", []))
    == CollectionStarted(me, Major, 42)
  assert ffi_events.decode(stamped("gc_major_end", []))
    == CollectionEnded(me, Major, 42)
}

// A call that carries its caller in a sixth element decodes with it.
pub fn a_call_with_its_caller_decodes_test() {
  let function = coerce(#(atom("m"), atom("f"), 1))
  let caller = coerce(#(atom("m"), atom("g"), 2))
  let me = ffi_proc.self()

  assert ffi_events.decode(
      coerce(#(atom("trace_ts"), me, atom("call"), function, caller, 42)),
    )
    == Called(me, function, caller, 42)
  assert ffi_events.decode(
      coerce(#(
        atom("trace_ts"),
        me,
        atom("call"),
        function,
        coerce(atom("undefined")),
        42,
      )),
    )
    == Called(me, function, coerce(atom("undefined")), 42)
  assert ffi_events.decode(
      coerce(#(atom("trace_ts"), me, atom("return_to"), function, caller, 42)),
    )
    == NotTrace
  assert ffi_events.decode(
      coerce(#(atom("trace_ts"), me, atom("call"), function, caller, atom("x"))),
    )
    == NotTrace
}

pub fn threshold_events_decode_test() {
  let info = coerce([#(atom("timeout"), 9)])
  let me = ffi_proc.self()

  assert ffi_events.decode(
      coerce(#(atom("monitor"), me, atom("long_gc"), info)),
    )
    == LongCollection(me, info)
  assert ffi_events.decode(
      coerce(#(atom("monitor"), me, atom("long_schedule"), info)),
    )
    == LongTimeslice(me, info)
}

// A term of the wrong shape, or a tag the probes did not ask for, is not an
// event. Nothing here may raise.
pub fn anything_else_is_not_an_event_test() {
  let me = ffi_proc.self()

  assert ffi_events.decode(coerce(42)) == NotTrace
  assert ffi_events.decode(coerce("call")) == NotTrace
  assert ffi_events.decode(coerce(#(1, 2, 3, 4, 5))) == NotTrace
  assert ffi_events.decode(coerce(#(atom("trace_ts"), 1, atom("call"), 3, 4)))
    == NotTrace
  assert ffi_events.decode(
      coerce(#(atom("trace_ts"), me, atom("call"), 3, atom("late"))),
    )
    == NotTrace
  assert ffi_events.decode(coerce(#(atom("trace_ts"), me, 7, 3, 4))) == NotTrace
  assert ffi_events.decode(stamped("send", [])) == NotTrace
  assert ffi_events.decode(
      coerce(#(atom("monitor"), me, atom("busy_port"), [])),
    )
    == NotTrace
  assert ffi_events.decode(coerce(#(atom("monitor"), 1, atom("long_gc"), [])))
    == NotTrace
  assert ffi_events.decode(coerce(#(atom("DOWN"), 1, atom("process"), me, 2)))
    == NotTrace
}
