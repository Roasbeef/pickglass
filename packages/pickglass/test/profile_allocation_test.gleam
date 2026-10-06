//// `pickglass profile --allocation`: its command line, and the command run end
//// to end over a fake agent. The fake plays every way the agent can answer a
//// counters probe that counts allocation: a complete reading, a reading with
//// functions it could not read, a probe that counted no allocation, a refusal
//// to start, and a probe that never ends.

import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pickglass/allocation_compare
import pickglass/allocation_report
import pickglass/capture_file
import pickglass/cli
import pickglass/probe_book
import pickglass/profile_run
import pickglass/remote
import pickglass_core/capture
import pickglass_core/identity
import pickglass_core/measure
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/provenance
import pickglass_core/unit
import pickglass_core/wire
import simplifile

// ----------------------------------------------------------------- parsing

fn base() -> cli.ProfileOptions {
  cli.ProfileOptions(
    selector: cli.NamedNode("app@127.0.0.1", Some("/c")),
    agent_ebin: None,
    target: cli.TopTarget(0),
    seconds: 5,
    out: None,
    format: cli.PgcapFormat,
    method: cli.CountAllocation(modules: ["alloc_fixture"]),
  )
}

const node = ["profile", "--node", "app@127.0.0.1", "--cookie-file", "/c"]

fn with(rest: List(String)) -> Result(cli.Command, String) {
  cli.parse(list.append(node, rest))
}

fn allocate(rest: List(String)) -> Result(cli.Command, String) {
  with(["--allocation", "--module", "alloc_fixture", ..rest])
}

fn is_error(result: Result(a, b)) -> Bool {
  result.is_error(result)
}

pub fn an_allocation_count_parses_with_its_defaults_test() {
  // Five seconds, and a capture, because the window cannot be counted again.
  assert allocate(["--owner", "session:abc"])
    == Ok(cli.Profile(
      cli.ProfileOptions(..base(), target: cli.OwnerTarget("session:abc")),
    ))
}

pub fn every_option_of_an_allocation_count_parses_test() {
  assert with([
      "--top", "8", "--allocation", "--module", "a,b", "--module", "c@*",
      "--seconds", "60", "--out", "p.txt", "--format", "text",
    ])
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..base(),
        target: cli.TopTarget(8),
        seconds: 60,
        out: Some("p.txt"),
        format: cli.TextFormat,
        method: cli.CountAllocation(modules: ["a", "b", "c@*"]),
      ),
    ))
}

// Every limit is the viewer's or the agent's, and every flag of another
// method is refused so a command line never silently ignores part of itself.
pub fn bad_allocation_command_lines_are_refused_test() {
  // The modules are what keeps the probe off every function of a node.
  assert with(["--top", "1", "--allocation"])
    == Error(
      "--allocation needs at least one --module: the agent refuses to count every function of a node",
    )
  assert is_error(with(["--top", "1", "--allocation", "--module", "*"]))
  assert is_error(with(["--top", "1", "--allocation", "--module", "../etc"]))

  // More patterns than the agent takes for one counters probe.
  let nine = ["a", "b", "c", "d", "e", "f", "g", "h", "i"]
  assert is_error(
    with([
      "--top",
      "1",
      "--allocation",
      ..list.flat_map(nine, fn(name) { ["--module", name] })
    ]),
  )
  let eight = list.take(nine, 8)
  assert !is_error(
    with([
      "--top",
      "1",
      "--allocation",
      ..list.flat_map(eight, fn(name) { ["--module", name] })
    ]),
  )

  // The viewer's limits for a probe that counts allocation.
  assert is_error(allocate(["--top", "9"]))
  assert !is_error(allocate(["--top", "8"]))
  assert is_error(allocate(["--top", "1", "--seconds", "61"]))
  assert is_error(allocate(["--top", "1", "--seconds", "0"]))

  // Function totals have no call stacks to draw a flame or a graph from.
  assert is_error(allocate(["--top", "1", "--format", "speedscope"]))
  assert is_error(allocate(["--top", "1", "--format", "collapsed"]))
  assert is_error(allocate(["--top", "1", "--format", "chrome"]))

  // Sampling flags mean nothing to a count, and two methods are one too many.
  assert is_error(allocate(["--top", "1", "--rate", "50"]))
  assert is_error(allocate(["--top", "1", "--include-waiting"]))
  assert is_error(allocate(["--top", "1", "--trace-calls"]))
  assert is_error(with(["--top", "1", "--module", "lists"]))
}

pub fn the_usage_names_the_allocation_method_and_what_its_words_mean_test() {
  assert string.contains(cli.usage, "--allocation --module MODULE")
  assert string.contains(cli.usage, "cumulative allocation, not retained heap")
  assert string.contains(cli.usage, "there are no call stacks")
}

// ----------------------------------------------------------------- running

fn base_agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  let rows = [
    fixture.row("<0.1.0>", 9000, fixture.labelled("session", "abc", "worker")),
    fixture.row("<0.2.0>", 4000, fixture.labelled("session", "abc", "keeper")),
    fixture.row("<0.3.0>", 1000, wire.Unlabelled),
  ]

  case request {
    wire.Extended(wire.AskOwnersDetail(..)) -> {
      let census = fixture.census(rows)

      Ok(fixture.owners_detail(
        census.coverage,
        census.rows,
        wire.CensusTotals(3, 14_000, 0, 0, 900, 2, 2),
      ))
    }
    wire.AskPin(text) -> {
      let serial = case string.split(text, ".") {
        [_, number, _] -> result.unwrap(int.parse(number), 0)
        _ -> 0
      }
      let assert Ok(token) = identity.pin(fixture.boot(), serial)

      Ok(wire.Pinned(token, text))
    }
    other -> fixture.healthy(other)
  }
}

// The functions of an allocation-heavy fixture, as the agent lists them:
// heavy builds a 200 cell list each call (400 words), relay builds a tuple and
// calls heavy, light builds a tuple.
fn rows() -> List(wire.FunctionMemory) {
  [
    wire.FunctionMemory("alloc_fixture", "heavy", 1, 80_000, 200, 4000),
    wire.FunctionMemory("alloc_fixture", "light", 1, 1200, 400, 300),
    wire.FunctionMemory("alloc_fixture", "relay", 1, 600, 200, 900),
  ]
}

fn counters(
  state: wire.ProbeState,
  with_calls: Int,
  invalidated: Int,
) -> wire.CountersSnapshot {
  wire.CountersSnapshot(
    probe_id: 31,
    state:,
    matched_functions: 9,
    elapsed_ms: 1200,
    functions: 9,
    with_calls:,
    invalidated:,
    rows: [],
  )
}

fn memory(
  memory: wire.CounterMemory,
  state: wire.ProbeState,
) -> wire.CounterMemorySnapshot {
  wire.CounterMemorySnapshot(probe_id: 31, state:, memory:)
}

fn complete() -> wire.CounterMemory {
  wire.MemoryCounted(
    rows(),
    wire.MemoryTotals(read: 3, unread: 0, words: 81_800),
  )
}

// An agent whose allocation probe ends at once with these readings.
fn agent_with(
  counted: wire.CountersSnapshot,
  allocated: wire.CounterMemory,
) -> fn(wire.Request) -> Result(wire.Reply, remote.Failure) {
  fn(request) {
    case request {
      wire.Extended(wire.AskStartCounterSet(..)) ->
        Ok(wire.CountersStarted(31, 9, 1000))
      wire.AskReadCounters(31) | wire.AskStopCounters(31) ->
        Ok(wire.CountersReport(counted))
      wire.Extended(wire.AskReadCounterMemory(31)) ->
        Ok(wire.CounterMemoryReport(memory(allocated, wire.ProbeFinished)))
      other -> base_agent(other)
    }
  }
}

fn run_over(
  script: fn(wire.Request) -> Result(wire.Reply, remote.Failure),
  options: cli.ProfileOptions,
) -> #(Result(String, profile_run.Failure), List(wire.Request)) {
  let seen = process.new_subject()
  let outcome =
    profile_run.execute(
      options,
      "0.0.0",
      "fake@127.0.0.1",
      1,
      fixture.fake_remote(seen, script),
    )

  #(outcome, fixture.drain(seen, 100))
}

fn options(format: cli.ProfileFormat, out: String) -> cli.ProfileOptions {
  out_dir()

  cli.ProfileOptions(
    ..base(),
    target: cli.OwnerTarget("session:abc"),
    seconds: 1,
    format:,
    out: Some("build/profile_allocation_test_out/" <> out),
  )
}

fn out_dir() -> Nil {
  let assert Ok(Nil) =
    simplifile.create_directory_all("build/profile_allocation_test_out")

  Nil
}

fn count_requests(
  requests: List(wire.Request),
  matching: fn(wire.Request) -> Bool,
) -> Int {
  list.count(requests, matching)
}

fn pins_and_unpins(requests: List(wire.Request)) -> #(Int, Int) {
  #(
    count_requests(requests, fn(request) {
      case request {
        wire.AskPin(_) -> True
        _ -> False
      }
    }),
    count_requests(requests, fn(request) {
      case request {
        wire.AskUnpin(_) -> True
        _ -> False
      }
    }),
  )
}

// The whole command: it chooses the owner's two processes, pins them, plans
// and confirms one counter set that counts allocation, takes both replies,
// releases the probe and the pins, and prints what the numbers are and are not.
pub fn an_allocation_count_reports_words_calls_and_coverage_test() {
  let #(outcome, requests) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 3, 0), complete()),
      options(cli.TextFormat, "t.txt"),
    )
  let assert Ok(text) = outcome

  // What was counted, where, and for how long, asked and observed.
  assert string.contains(text, "allocation profile of all 2 listed processes")
  assert string.contains(
    text,
    "probe 31 counted calls, call time and allocated words of alloc_fixture in 2 processes",
  )
  assert string.contains(
    text,
    "window: 1.00 s asked for, 1.20 s observed, complete",
  )
  assert string.contains(
    text,
    "functions: 9 matched, 3 called, 3 with an allocation reading, 3 listed",
  )

  // Words beside the word size they were counted in, and the bytes they make.
  assert string.contains(
    text,
    "allocated words: 81,800 over 3 functions read, word size 8 bytes, 654,400 bytes",
  )
  assert string.contains(text, "unavailable: none")

  // The table is by words, with the calls and the words per call.
  let assert Ok(#(_, table)) = string.split_once(text, "  function")
  let heavy =
    string.split(table, "\n") |> list.find(string.contains(_, "heavy/1"))
  let assert Ok(heavy_line) = heavy

  assert string.contains(heavy_line, "alloc_fixture:heavy/1")
  assert string.contains(heavy_line, "80,000")
  assert string.contains(heavy_line, "640,000")
  assert string.contains(heavy_line, "400.0")
  assert string.contains(heavy_line, "4.00 ms")

  // What the words are not, and that they are totals and not stacks.
  assert string.contains(
    text,
    "not retained heap, resident memory (RSS), binaries held outside the heap, ETS or native and NIF memory",
  )
  assert string.contains(text, "Function totals only")
  assert string.contains(text, "no attribution of untraced work")
  assert !string.contains(text, "samples")

  // The agent was asked for exactly the modules, in the time-and-memory mode,
  // over the two pins, with the command's window as its own deadline.
  let assert Ok(start) =
    list.find(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCounterSet(..)) -> True
        _ -> False
      }
    })
  let assert wire.Extended(wire.AskStartCounterSet(
    patterns,
    wire.PinnedProcesses(tokens),
    duration_ms,
    mode,
  )) = start

  assert patterns == [wire.CounterPattern("alloc_fixture", "_")]
  assert list.length(tokens) == 2
  assert duration_ms == 1000
  assert mode == wire.CountTimeAndMemory
}

// After a normal end the probe is released on the agent and every pin the
// command took is given back, so neither a trace session nor a pin survives.
pub fn after_a_complete_count_the_probe_and_every_pin_are_released_test() {
  let #(outcome, requests) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 3, 0), complete()),
      options(cli.TextFormat, "t.txt"),
    )
  let assert Ok(text) = outcome
  let #(pinned, unpinned) = pins_and_unpins(requests)

  assert string.contains(text, "pins released")
  assert pinned == 2
  assert unpinned == 2

  // The allocation was read before the probe was released, since releasing it
  // removes it, and the release is the stop that destroys what is left.
  let positions =
    list.index_map(requests, fn(request, index) { #(index, request) })
  let first = fn(wanted: fn(wire.Request) -> Bool) {
    let assert Ok(#(index, _)) =
      list.find(positions, fn(entry) { wanted(entry.1) })

    index
  }
  let memory_read =
    first(fn(request) {
      request == wire.Extended(wire.AskReadCounterMemory(31))
    })
  let released = first(fn(request) { request == wire.AskStopCounters(31) })

  assert memory_read < released
}

pub fn a_count_writes_a_capture_that_keeps_what_the_report_says_test() {
  out_dir()

  let #(outcome, _) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 3, 0), complete()),
      options(cli.PgcapFormat, "a.pgcap"),
    )
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "wrote build/profile_allocation_test_out/a.pgcap",
  )
  assert string.contains(text, "pickglass view opens it")

  let assert Ok(loaded) =
    capture_file.read("build/profile_allocation_test_out/a.pgcap")

  assert loaded.digest == capture_file.DigestVerified

  // The word size is the capture's own runtime fact.
  assert loaded.capture.header.provenance.runtime.wordsize == 8

  let assert [probe] = probe_book.of_records(loaded.capture.records)

  assert probe.kind == policy.CallMemory
  assert probe.processes == Some(2)
  assert probe.matched == 9

  let assert probe_book.Finished(
    cost: capture.ProbeCost(counters: Some(facts), wall_ms:, enabled:, ..),
    profile: Some(found),
    notes:,
    ..,
  ) = probe.state

  assert enabled == ["call_time", "call_memory"]
  assert wall_ms == measure.Known(1200)
  assert facts.requested_ms == 1000
  assert facts.processes == Some(2)
  assert facts.called == 3
  assert facts.read == 3
  assert facts.unread == 0
  assert facts.invalidated == 0
  assert facts.total_words == 81_800

  // A function total, with no stacks: one frame per sample, the allocation in
  // words and the call time in nanoseconds.
  assert profile.source(found) == profile.AllocationCounts
  assert profile.shape(profile.source(found)) == profile.FunctionTotals
  assert list.map(profile.value_types(found), fn(value) { value.unit })
    == [unit.Count, unit.Nanoseconds, unit.Words]
  assert list.all(profile.samples(found), fn(sample) {
    list.length(sample.frames) == 1
  })

  // A reader of the capture is told what a live reader is.
  assert list.any(notes, string.contains(_, "not retained heap"))
  assert list.any(notes, string.contains(_, "Function totals only"))
}

// A function the VM could not read is counted and said, never a row of zero
// words, in the report and in what the capture keeps.
pub fn a_function_with_no_allocation_reading_is_said_and_never_zero_test() {
  out_dir()

  let unread =
    wire.MemoryCounted(
      list.take(rows(), 2),
      wire.MemoryTotals(read: 2, unread: 1, words: 81_200),
    )
  let script = agent_with(counters(wire.ProbeFinished, 3, 1), unread)
  let #(outcome, _) = run_over(script, options(cli.PgcapFormat, "u.pgcap"))
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "functions: 9 matched, 3 called, 2 with an allocation reading, 2 listed",
  )
  assert string.contains(
    text,
    "unavailable: 1 called functions have no allocation reading; they are not listed and are not zero",
  )
  assert string.contains(
    text,
    "invalidated: 1 traced functions were invalidated by a module reload, so this snapshot is suspect",
  )
  assert !string.contains(text, "unavailable: none")

  // The relay function has no reading, so it has no row.
  assert !string.contains(text, "alloc_fixture:relay/1")

  let assert Ok(loaded) =
    capture_file.read("build/profile_allocation_test_out/u.pgcap")
  let assert [probe] = probe_book.of_records(loaded.capture.records)
  let assert probe_book.Finished(
    cost: capture.ProbeCost(counters: Some(facts), ..),
    profile: Some(found),
    ..,
  ) = probe.state

  assert facts.unread == 1
  assert facts.invalidated == 1
  assert list.length(profile.samples(found)) == 2
}

pub fn a_probe_that_called_nothing_says_so_and_has_no_rows_test() {
  let empty = wire.MemoryCounted([], wire.MemoryTotals(0, 0, 0))
  let #(outcome, _) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 0, 0), empty),
      options(cli.TextFormat, "e.txt"),
    )
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "no function was called with an allocation reading",
  )
  assert string.contains(
    text,
    "functions: 9 matched, 0 called, 0 with an allocation reading, 0 listed",
  )
}

pub fn a_list_cut_at_the_agents_bound_says_how_many_were_left_out_test() {
  // The agent lists the 200 largest allocators; this probe read 250.
  let cut =
    wire.MemoryCounted(
      rows(),
      wire.MemoryTotals(read: 250, unread: 0, words: 90_000),
    )
  let #(outcome, _) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 250, 0), cut),
      options(cli.TextFormat, "c.txt"),
    )
  let assert Ok(text) = outcome

  assert string.contains(text, "the table lists the 3 largest")
  assert string.contains(
    text,
    "247 functions with a reading are not listed: the agent keeps the 3 that allocated the most.",
  )
  assert string.contains(
    text,
    "allocated words: 90,000 over 250 functions read",
  )
}

// ------------------------------------------------- unavailable counters

// A VM without the allocation counter refuses the probe, and the command says
// so with the agent's own code. Nothing was started, so there is nothing to
// release but the pins, which the detach `run` always makes clears.
pub fn a_vm_without_call_memory_refuses_and_the_command_fails_typed_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskStartCounterSet(..)) ->
        Error(remote.Refusal(
          "memory_unavailable",
          "the VM refused the pattern or has no call_memory counter",
        ))
      other -> base_agent(other)
    }
  }
  let #(outcome, requests) =
    run_over(refusing, options(cli.TextFormat, "r.txt"))
  let assert Error(profile_run.StartRefused(reason)) = outcome

  assert string.contains(reason, "memory_unavailable")
  assert profile_run.describe(profile_run.StartRefused(reason))
    == "profile failed (start_refused): " <> reason

  // One start, no read and no stop of a probe that never began.
  assert count_requests(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCounterSet(..)) -> True
        _ -> False
      }
    })
    == 1
  assert !list.any(requests, fn(request) {
    case request {
      wire.AskReadCounters(_)
      | wire.AskStopCounters(_)
      | wire.Extended(wire.AskReadCounterMemory(_)) -> True
      _ -> False
    }
  })
}

// The node-wide limits are the agent's: a third probe is refused with its code
// and the command stops, having started nothing.
pub fn a_node_with_its_probe_slots_taken_refuses_the_count_test() {
  let full = fn(request) {
    case request {
      wire.Extended(wire.AskStartCounterSet(..)) ->
        Error(remote.Refusal("probe_limit", "two probes are already running"))
      other -> base_agent(other)
    }
  }
  let #(outcome, _) = run_over(full, options(cli.TextFormat, "l.txt"))
  let assert Error(profile_run.StartRefused(reason)) = outcome

  assert string.contains(reason, "probe_limit")
}

// An agent that answers a time-and-memory probe with no allocation has
// nothing to profile, and the command fails and does not print zeros.
pub fn an_agent_that_counted_no_allocation_is_a_failure_not_zeros_test() {
  let #(outcome, _) =
    run_over(
      agent_with(counters(wire.ProbeFinished, 3, 0), wire.NoMemoryCounted),
      options(cli.TextFormat, "n.txt"),
    )
  let assert Error(profile_run.ProbeFailed(reason)) = outcome

  assert string.contains(reason, "the agent counted no allocation")
}

// A memory read that does not answer, with the counters answering, is asked
// again; one the agent refuses closes the probe as lost with the agent's words.
pub fn a_probe_whose_allocation_cannot_be_read_is_closed_as_lost_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskReadCounterMemory(_)) ->
        Error(remote.Refusal("no_such_probe", "no probe has that id"))
      other -> agent_with(counters(wire.ProbeFinished, 3, 0), complete())(other)
    }
  }
  let #(outcome, _) = run_over(refusing, options(cli.TextFormat, "g.txt"))
  let assert Error(profile_run.ProbeFailed(_)) = outcome
}

// ----------------------------------------------------------------- timeout

// An agent whose probe never ends. The command waits the probe's window and a
// grace, then fails with its own code. The agent was given the window as its
// deadline, so the probe ends on the agent whether or not the command waited.
pub fn a_probe_that_never_ends_times_out_and_the_agent_holds_the_deadline_test() {
  let seen = process.new_subject()
  let never = fn(request) {
    case request {
      wire.Extended(wire.AskStartCounterSet(..)) ->
        Ok(wire.CountersStarted(31, 9, 1000))
      wire.AskReadCounters(31) ->
        Ok(wire.CountersReport(counters(wire.ProbeRunning, 0, 0)))
      other -> base_agent(other)
    }
  }
  let outcome =
    profile_run.execute_within(
      options(cli.TextFormat, "x.txt"),
      "0.0.0",
      "fake@127.0.0.1",
      1,
      fixture.fake_remote(seen, never),
      0,
    )
  let requests = fixture.drain(seen, 100)
  let assert Error(profile_run.ProbeTimedOut(reason)) = outcome

  assert string.contains(reason, "probe 31 did not end in the time allowed")

  // The allocation of a probe that has not ended is never read.
  assert !list.any(requests, fn(request) {
    case request {
      wire.Extended(wire.AskReadCounterMemory(_)) -> True
      _ -> False
    }
  })
  let assert Ok(wire.Extended(wire.AskStartCounterSet(_, _, duration_ms, _))) =
    list.find(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCounterSet(..)) -> True
        _ -> False
      }
    })
    |> result.map(fn(request) { request })

  assert duration_ms == 1000
}

// ---------------------------------------------------- the target goes away

// The target stops answering once the probe has started. The viewer's hub
// reports it lost, the service closes the probe as lost and forgets its pins
// without asking a node that is gone, and the command fails and never reports
// words it did not read.
pub fn a_target_lost_mid_count_fails_without_reporting_words_test() {
  let handshake = process.new_subject()
  let _ =
    process.spawn(fn() {
      let inbox = process.new_subject()

      process.send(handshake, inbox)
      hold(inbox, False)
    })
  let assert Ok(flag) = process.receive(handshake, 1000)
  let gone = fn(request) {
    case asked(flag) {
      True -> Error(remote.TimedOut)
      False ->
        case request {
          wire.Extended(wire.AskStartCounterSet(..)) -> {
            process.send(flag, Raise)

            Ok(wire.CountersStarted(31, 9, 1000))
          }
          other -> base_agent(other)
        }
    }
  }
  let #(outcome, requests) = run_over(gone, options(cli.TextFormat, "d.txt"))
  let assert Error(profile_run.ProbeFailed(reason)) = outcome

  assert reason != ""

  // No allocation was read, and no pin was released on a node that is gone.
  assert !list.any(requests, fn(request) {
    case request {
      wire.Extended(wire.AskReadCounterMemory(_)) -> True
      _ -> False
    }
  })
}

type Flag {
  Raise
  Ask(reply: process.Subject(Bool))
}

// A flag the fake agent raises when it answers the start, so that everything
// after it is a node that stopped answering.
fn hold(inbox: process.Subject(Flag), raised: Bool) -> Nil {
  case process.receive_forever(inbox) {
    Raise -> hold(inbox, True)
    Ask(reply) -> {
      process.send(reply, raised)

      hold(inbox, raised)
    }
  }
}

fn asked(flag: process.Subject(Flag)) -> Bool {
  process.call(flag, 1000, Ask)
}

// ------------------------------------------------------------- comparing

fn captured(name: String, words: Int, per_call: Int) -> String {
  captured_with_words(name, words, per_call, 8)
}

// A capture of an allocation probe over a target whose words are this many
// bytes.
fn captured_with_words(
  name: String,
  words: Int,
  per_call: Int,
  word_size: Int,
) -> String {
  out_dir()

  let heavy = wire.FunctionMemory("alloc_fixture", "heavy", 1, words, 200, 4000)
  let other =
    wire.FunctionMemory("alloc_fixture", "other_" <> name, 1, per_call, 10, 10)
  let counted =
    wire.MemoryCounted(
      [heavy, other],
      wire.MemoryTotals(read: 2, unread: 0, words: words + per_call),
    )
  let path = "build/profile_allocation_test_out/" <> name <> ".pgcap"
  let script = agent_with(counters(wire.ProbeFinished, 2, 0), counted)
  let #(outcome, _) =
    run_over(
      fn(request) {
        case request {
          wire.AskMemory ->
            Ok(wire.MemoryReport(
              wire.MemorySnapshot(..fixture.memory(2_000_000), word_size:),
            ))
          other -> script(other)
        }
      },
      options(cli.PgcapFormat, name <> ".pgcap"),
    )
  let assert Ok(_) = outcome

  path
}

// Two captures put each other's functions side by side: the direction of the
// words, the words per call, and a function one capture lists and the other
// does not as "not listed", never as zero.
pub fn two_allocation_captures_compare_their_function_totals_test() {
  let before = captured("before", 80_000, 50)
  let after = captured("after", 120_000, 70)
  let report = compare_text(before, after)

  assert string.contains(
    report,
    "allocation: function totals of the newest allocation probe in each capture",
  )
  assert string.contains(report, "word size: 8 bytes in both")
  assert string.contains(
    report,
    "totals are cumulative over each probe's own window",
  )
  assert string.contains(report, "alloc_fixture:heavy/1")
  assert string.contains(report, "80,000")
  assert string.contains(report, "120,000")
  assert string.contains(
    report,
    "words higher, per call higher (400.0 | 600.0)",
  )
  assert string.contains(report, "not listed in the candidate")
  assert string.contains(report, "not listed in the baseline")
  assert string.contains(report, "which is not zero words")
}

fn compare_text(before: String, after: String) -> String {
  let assert Ok(first) = capture_file.read(before)
  let assert Ok(second) = capture_file.read(after)

  string.join(
    allocation_compare.lines(
      first,
      second,
      provenance.comparability(
        first.capture.header.provenance,
        second.capture.header.provenance,
      ),
    ),
    "\n",
  )
}

// A capture that holds no allocation probe compares as it always did: the
// section is not there, and a capture with one against one without says so.
pub fn captures_without_allocation_probes_add_no_section_test() {
  out_dir()

  let counted = captured("with", 80_000, 50)
  let sampled_path = "build/profile_allocation_test_out/stacks.pgcap"
  let #(sampled, _) =
    run_over(
      stack_agent,
      cli.ProfileOptions(
        ..base(),
        target: cli.OwnerTarget("session:abc"),
        seconds: 1,
        method: cli.SampleStacks(
          rate_hz: 100,
          samples: activity.OnSchedulerOnly,
        ),
        out: Some(sampled_path),
      ),
    )
  let assert Ok(_) = sampled

  assert compare_text(sampled_path, sampled_path) == ""
  assert string.contains(
    compare_text(counted, sampled_path),
    "only the baseline holds an allocation probe, so there is nothing to compare",
  )
  assert string.contains(
    compare_text(sampled_path, counted),
    "only the candidate holds an allocation probe, so there is nothing to compare",
  )
}

// Two captures taken with words of different sizes are not the same quantity:
// the report says so and states no direction, for the total or for any function.
pub fn captures_with_different_word_sizes_state_no_direction_test() {
  let before = captured_with_words("w8", 80_000, 50, 8)
  let after = captured_with_words("w4", 120_000, 70, 4)
  let report = compare_text(before, after)

  assert string.contains(report, "word size differs (8 | 4 bytes)")
  assert string.contains(report, "no direction")
  assert string.contains(report, "no direction: word sizes differ")
  assert !string.contains(report, "words higher")
  assert !string.contains(report, "words lower")
}

fn stack_agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskStartStacks(tokens, _, _, _)) ->
      Ok(wire.StacksStarted(11, list.length(tokens), 100, 1000, 100_000))
    wire.Extended(wire.AskReadStacks(11))
    | wire.Extended(wire.AskStopStacks(11)) ->
      Ok(wire.StacksReport(finished_stacks()))
    other -> base_agent(other)
  }
}

fn finished_stacks() -> wire.StacksSnapshot {
  wire.StacksSnapshot(
    probe_id: 11,
    state: wire.ProbeFinished,
    stop: wire.SamplingDeadline,
    meter: wire.SamplerMeter(
      requested_hz: 100,
      achieved_millihz: 97_000,
      rounds: 97,
      samples: 194,
      elapsed_ms: 1000,
      depth_limit: 8,
      at_depth_limit: 0,
      targets_gone: 0,
      dropped_samples: 0,
      distinct_stacks: 1,
      truncated_samples: 0,
    ),
    frames: [wire.StackFrame("loom@runtime", "leaf", 1, wire.NoLocation)],
    stacks: [wire.SampledStack(150, "running", [0])],
  )
}

// The report never invents what it was not given: with no word size there are
// no bytes, and with no process count it says the count is not recorded.
pub fn the_report_derives_no_bytes_without_a_word_size_test() {
  let facts =
    capture.CounterFacts(
      requested_ms: 5000,
      processes: None,
      called: 1,
      read: 1,
      unread: 0,
      invalidated: 0,
      total_words: 40,
    )
  let report =
    allocation_report.Report(
      scope: "",
      probe: "7",
      modules: [],
      matched: None,
      facts:,
      observed_ms: measure.Missing(measure.UnsupportedOnRuntime),
      outcome: measure.Complete,
      word_size: None,
      rows: [allocation_report.Row("m:f/1", 4, 8000, 40)],
    )
  let text = allocation_report.render(report, 15)

  assert string.contains(text, "word size not read, so no bytes are derived")
  assert string.contains(text, "an unrecorded number of processes")
  assert string.contains(text, "not recorded observed")
  assert !string.contains(text, "bytes\n")
  assert !string.contains(text, " B")
  assert string.contains(text, "m:f/1")
  assert string.contains(text, "10.0")
}
