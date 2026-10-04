//// `pickglass profile`: its command line, and the command run end to end
//// over a fake agent.

import fixture
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pickglass/capture_file
import pickglass/cli
import pickglass/probe_book
import pickglass/profile_run
import pickglass/remote
import pickglass_core/identity
import pickglass_core/policy
import pickglass_core/profile
import pickglass_core/profile/activity
import pickglass_core/wire
import simplifile

// ----------------------------------------------------------------- parsing

fn base() -> cli.ProfileOptions {
  cli.ProfileOptions(
    selector: cli.NamedNode("app@127.0.0.1", Some("/c")),
    agent_ebin: None,
    target: cli.TopTarget(0),
    seconds: 10,
    out: None,
    format: cli.SpeedscopeFormat,
    method: cli.SampleStacks(rate_hz: 100, samples: activity.OnSchedulerOnly),
  )
}

const node = ["profile", "--node", "app@127.0.0.1", "--cookie-file", "/c"]

fn with(rest: List(String)) -> Result(cli.Command, String) {
  cli.parse(list.append(node, rest))
}

pub fn an_owner_profile_parses_with_its_defaults_test() {
  assert with(["--owner", "session:abc"])
    == Ok(cli.Profile(
      cli.ProfileOptions(..base(), target: cli.OwnerTarget("session:abc")),
    ))
}

pub fn every_option_parses_test() {
  assert with([
      "--top", "8", "--seconds", "30", "--rate", "250", "--out", "p.json",
      "--format", "collapsed", "--agent-ebin", "/e",
    ])
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..base(),
        target: cli.TopTarget(8),
        seconds: 30,
        method: cli.SampleStacks(
          rate_hz: 250,
          samples: activity.OnSchedulerOnly,
        ),
        out: Some("p.json"),
        format: cli.CollapsedFormat,
        agent_ebin: Some("/e"),
      ),
    ))
}

pub fn a_loom_target_and_a_process_parse_test() {
  assert cli.parse([
      "profile", "--state-dir", "/s", "--pid", "42", "--pid-text", "<0.123.0>",
    ])
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..base(),
        selector: cli.LoomTarget(Some("/s"), Some(42)),
        target: cli.ProcessTarget("<0.123.0>"),
      ),
    ))
}

pub fn the_owner_paths_the_owners_page_writes_parse_test() {
  assert is_ok(with(["--owner", "unknown"]))
  assert is_ok(with(["--owner", "session:abc/strand:def"]))
}

pub fn every_format_is_named_test() {
  list.each(
    [
      #("speedscope", cli.SpeedscopeFormat),
      #("collapsed", cli.CollapsedFormat),
      #("chrome", cli.ChromeFormat),
      #("pgcap", cli.PgcapFormat),
      #("text", cli.TextFormat),
    ],
    fn(pair) {
      assert with(["--top", "1", "--format", pair.0])
        == Ok(cli.Profile(
          cli.ProfileOptions(..base(), target: cli.TopTarget(1), format: pair.1),
        ))
    },
  )
}

// Each refusal is a message, never a crash.
pub fn bad_profile_command_lines_are_refused_test() {
  // No scope, or two.
  assert with([]) == Error("profile needs one of --owner, --top and --pid-text")
  assert with(["--top", "3", "--owner", "unknown"])
    == Error("profile takes only one of --owner, --top and --pid-text")

  // Values outside what the agent runs.
  assert is_error(with(["--top", "0"]))
  assert is_error(with(["--top", "17"]))
  assert is_error(with(["--top", "x"]))
  assert is_error(with(["--top", "3", "--seconds", "0"]))
  assert is_error(with(["--top", "3", "--seconds", "61"]))
  assert is_error(with(["--top", "3", "--rate", "0"]))
  assert is_error(with(["--top", "3", "--rate", "1001"]))
  assert is_error(with(["--top", "3", "--format", "pdf"]))

  // Owners and pids that cannot be named.
  assert is_error(with(["--owner", "session"]))
  assert is_error(with(["--owner", "session:"]))
  assert is_error(with(["--owner", ""]))
  assert is_error(with(["--pid-text", "0.1.0"]))
  assert is_error(with(["--pid-text", "<0.1>"]))
  assert is_error(with(["--pid-text", "<a.b.c>"]))
  assert is_error(with(["--pid-text", "<0.-1.0>"]))

  // A flag with no value, an unknown flag.
  assert is_error(with(["--top"]))
  assert is_error(with(["--top", "3", "--bogus"]))
}

// The selection rules of the other commands hold here too.
pub fn the_target_selection_rules_hold_for_profile_test() {
  assert is_error(
    cli.parse(["profile", "--node", "app@127.0.0.1", "--pid", "4", "--top", "1"]),
  )
  assert is_error(
    cli.parse([
      "profile",
      "--node",
      "app@127.0.0.1",
      "--cookie",
      "x",
      "--top",
      "1",
    ]),
  )
}

fn is_ok(result: Result(a, b)) -> Bool {
  result.is_ok(result)
}

fn is_error(result: Result(a, b)) -> Bool {
  result.is_error(result)
}

// ----------------------------------------------------------------- running

fn agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  let rows = [
    fixture.row("<0.1.0>", 9000, fixture.labelled("session", "abc", "worker")),
    fixture.row("<0.2.0>", 4000, fixture.labelled("session", "abc", "keeper")),
    fixture.row("<0.3.0>", 1000, wire.Unlabelled),
  ]

  case request {
    wire.Extended(wire.AskOwners(..)) -> {
      let census = fixture.census(rows)

      Ok(
        wire.OwnersReport(wire.OwnersSnapshot(
          coverage: census.coverage,
          rows: census.rows,
          owners: [],
          totals: wire.CensusTotals(3, 14_000, 0, 0, 900, 2, 2),
        )),
      )
    }
    wire.AskPin(text) -> {
      let serial = case string.split(text, ".") {
        [_, number, _] -> result.unwrap(int.parse(number), 0)
        _ -> 0
      }
      let assert Ok(token) = identity.pin(fixture.boot(), serial)

      Ok(wire.Pinned(token, text))
    }
    wire.Extended(wire.AskStartStacks(tokens, rate, _, _)) ->
      Ok(wire.StacksStarted(
        11,
        list.length(tokens),
        int.min(rate, 1000 / list.length(tokens)),
        1000,
        100_000,
      ))
    wire.Extended(wire.AskReadStacks(11))
    | wire.Extended(wire.AskStopStacks(11)) -> Ok(wire.StacksReport(finished()))
    other -> fixture.healthy(other)
  }
}

fn finished() -> wire.StacksSnapshot {
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
      distinct_stacks: 2,
      truncated_samples: 0,
    ),
    frames: [
      wire.StackFrame("loom@runtime", "leaf", 1, wire.AtLine("src/a.gleam", 10)),
      wire.StackFrame("loom@runtime", "root", 1, wire.NoLocation),
    ],
    stacks: [
      wire.SampledStack(150, "running", [0, 1]),
      wire.SampledStack(44, "waiting", [1]),
    ],
  )
}

fn run(
  options: cli.ProfileOptions,
) -> #(Result(String, profile_run.Failure), List(wire.Request)) {
  run_over(agent, options)
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

fn options(
  target: cli.ProfileTarget,
  format: cli.ProfileFormat,
  out: String,
) -> cli.ProfileOptions {
  cli.ProfileOptions(
    ..base(),
    target:,
    seconds: 1,
    format:,
    out: Some("build/profile_cli_test_out/" <> out),
  )
}

fn out_dir() -> Nil {
  let assert Ok(Nil) =
    simplifile.create_directory_all("build/profile_cli_test_out")

  Nil
}

// The whole command over a fake agent: it chooses the owner's two
// processes, pins them, plans and confirms, takes the profile, releases the
// pins, and writes speedscope JSON that has the documented shape.
pub fn a_profile_of_an_owner_writes_speedscope_and_summarises_it_test() {
  out_dir()

  let #(outcome, requests) =
    run(options(cli.OwnerTarget("session:abc"), cli.SpeedscopeFormat, "o.json"))
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "profile of all 2 listed processes of session:abc",
  )
  assert string.contains(text, "150 samples counted over 1 s")
  assert string.contains(
    text,
    "samples: 194 samples: 150 running/runnable, 44 waiting; counting running and runnable samples",
  )
  assert string.contains(
    text,
    "coverage: Sampled 194 times at 97 Hz achieved of 100 requested.",
  )
  assert string.contains(
    text,
    "sampled at reduction safe points; long BIFs and NIFs are under-counted",
  )
  assert string.contains(text, "top 2 functions by samples of their own")
  assert string.contains(text, "loom@runtime:leaf/1")
  assert string.contains(text, "wrote build/profile_cli_test_out/o.json")
  assert string.contains(text, "speedscope.app")
  assert string.contains(text, "pins released")

  // Only the owner's processes were pinned, and each pin was released.
  let pinned =
    list.filter_map(requests, fn(request) {
      case request {
        wire.AskPin(pid) -> Ok(pid)
        _ -> Error(Nil)
      }
    })
  let released =
    list.count(requests, fn(request) {
      case request {
        wire.AskUnpin(_) -> True
        _ -> False
      }
    })

  assert list.sort(pinned, string.compare) == ["<0.1.0>", "<0.2.0>"]
  assert released == 2

  let assert Ok(body) = simplifile.read("build/profile_cli_test_out/o.json")
  let assert Ok(frames) =
    json.parse(
      body,
      decode.at(
        ["shared", "frames"],
        decode.list(decode.at(["name"], decode.string)),
      ),
    )
  let assert Ok(unit) =
    json.parse(
      body,
      decode.at(["profiles"], decode.list(decode.at(["unit"], decode.string))),
    )
  let assert Ok(weights) =
    json.parse(
      body,
      decode.at(
        ["profiles"],
        decode.list(decode.at(["weights"], decode.list(decode.int))),
      ),
    )

  assert frames == ["loom@runtime:leaf/1", "loom@runtime:root/1"]
  assert unit == ["none"]

  // Only the 150 samples taken while a process was running are in the file;
  // the 44 taken while it waited are not.
  assert weights == [[150]]
}

pub fn the_text_format_prints_a_call_tree_and_the_top_n_profile_runs_test() {
  let #(outcome, _) =
    run(
      cli.ProfileOptions(
        ..options(cli.TopTarget(2), cli.TextFormat, "t.txt"),
        out: None,
      ),
    )
  let assert Ok(text) = outcome

  assert string.contains(text, "call tree (share of 150 samples)")
  assert string.contains(text, "100.0%  loom@runtime:root/1")
  assert string.contains(text, "100.0%    loom@runtime:leaf/1")
  assert !string.contains(text, "wrote ")
}

// `--include-waiting` counts every sample, and the summary still says how the
// set split.
pub fn including_waiting_counts_every_sample_test() {
  let #(outcome, _) =
    run(
      cli.ProfileOptions(
        ..options(cli.TopTarget(2), cli.TextFormat, "t.txt"),
        out: None,
        method: cli.SampleStacks(rate_hz: 100, samples: activity.IncludeWaiting),
      ),
    )
  let assert Ok(text) = outcome

  assert string.contains(text, "194 samples counted over 1 s")
  assert string.contains(
    text,
    "samples: 194 samples: 150 running/runnable, 44 waiting; counting all samples, waiting ones included",
  )
  assert string.contains(text, "call tree (share of 194 samples)")
  assert string.contains(text, "77.3%    loom@runtime:leaf/1")
}

pub fn collapsed_chrome_and_pgcap_files_are_written_test() {
  out_dir()

  let target = cli.ProcessTarget("<0.1.0>")
  let assert #(Ok(collapsed), _) =
    run(options(target, cli.CollapsedFormat, "c.collapsed"))
  let assert Ok(lines) =
    simplifile.read("build/profile_cli_test_out/c.collapsed")

  assert string.contains(
    collapsed,
    "wrote build/profile_cli_test_out/c.collapsed",
  )
  assert lines == "loom@runtime:root/1;loom@runtime:leaf/1 150\n"

  let assert #(Ok(_), _) =
    run(options(target, cli.ChromeFormat, "c.trace.json"))
  let assert Ok(trace) =
    simplifile.read("build/profile_cli_test_out/c.trace.json")

  assert string.contains(trace, "traceEvents")

  // A capture holds the observations and the profile, and verifies.
  let assert #(Ok(_), _) = run(options(target, cli.PgcapFormat, "c.pgcap"))
  let assert Ok(loaded) =
    capture_file.read("build/profile_cli_test_out/c.pgcap")

  assert loaded.digest == capture_file.DigestVerified
}

pub fn an_owner_with_no_processes_fails_with_a_typed_message_test() {
  let #(outcome, requests) =
    run(options(
      cli.OwnerTarget("session:nobody"),
      cli.SpeedscopeFormat,
      "n.json",
    ))

  assert outcome
    == Error(profile_run.NoProcesses(
      "the last pass lists no live process of session:nobody",
    ))
  assert profile_run.describe(profile_run.NoProcesses(
      "the last pass lists no live process of session:nobody",
    ))
    == "profile failed (no_processes): the last pass lists no live process of session:nobody"

  // Nothing was pinned.
  assert !list.any(requests, fn(request) {
    case request {
      wire.AskPin(_) -> True
      _ -> False
    }
  })
}

// ---------------------------------------------------------- waiting samples

// An idle node: every sample caught its process in `receive`.
fn idle_agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskReadStacks(11))
    | wire.Extended(wire.AskStopStacks(11)) ->
      Ok(wire.StacksReport(
        wire.StacksSnapshot(..finished(), stacks: [
          wire.SampledStack(194, "waiting", [1]),
        ]),
      ))
    other -> agent(other)
  }
}

// When no sample caught a process running the command says so in plain words
// and writes no file of nothing, and it is not a failure.
pub fn an_idle_profile_says_every_process_was_waiting_and_writes_nothing_test() {
  out_dir()

  let #(outcome, _) =
    run_over(
      idle_agent,
      options(cli.OwnerTarget("session:abc"), cli.SpeedscopeFormat, "idle.json"),
    )
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "samples: 194 samples: 0 running/runnable, 194 waiting",
  )
  assert string.contains(
    text,
    "All 2 processes were waiting for messages for the whole window.",
  )
  assert string.contains(text, "no file was written")
  assert string.contains(text, "--include-waiting")
  assert !string.contains(text, "wrote ")
  assert !string.contains(text, "top ")
}

pub fn an_idle_profile_is_drawn_when_waiting_is_included_test() {
  out_dir()

  let #(outcome, _) =
    run_over(
      idle_agent,
      cli.ProfileOptions(
        ..options(cli.OwnerTarget("session:abc"), cli.CollapsedFormat, "idle.c"),
        method: cli.SampleStacks(rate_hz: 100, samples: activity.IncludeWaiting),
      ),
    )
  let assert Ok(text) = outcome

  assert string.contains(text, "wrote build/profile_cli_test_out/idle.c")
  assert !string.contains(text, "were waiting for messages")
}

// A capture holds every sample whatever was counted, so the viewer can show
// either view when it opens the file.
pub fn a_capture_keeps_the_waiting_samples_test() {
  out_dir()

  let #(outcome, _) =
    run(options(cli.ProcessTarget("<0.1.0>"), cli.PgcapFormat, "w.pgcap"))
  let assert Ok(_) = outcome
  let assert Ok(loaded) =
    capture_file.read("build/profile_cli_test_out/w.pgcap")
  let assert [probe] = probe_book.of_records(loaded.capture.records)
  let assert probe_book.Finished(profile: Some(found), ..) = probe.state
  let assert Ok(column) = profile.column(found, 0)

  assert activity.split(found, column)
    == activity.Split(on_scheduler: 150, waiting: 44, unstated: 0)
}

// ---------------------------------------------------------------- tracing

fn tracing(modules: List(String)) -> cli.ProfileOptions {
  cli.ProfileOptions(..base(), seconds: 5, method: cli.TraceCalls(modules:))
}

fn traced(modules: List(String)) -> List(String) {
  list.append(
    ["--trace-calls"],
    list.flat_map(modules, fn(m) { ["--module", m] }),
  )
}

pub fn a_call_trace_parses_with_its_modules_and_a_shorter_default_test() {
  assert with(list.append(["--top", "2"], traced(["lists", "gleam@list"])))
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..tracing(["lists", "gleam@list"]),
        target: cli.TopTarget(2),
      ),
    ))

  // Modules may also be joined by commas or spaces in one value, and the
  // window may be set up to the agent's ten seconds.
  assert with([
      "--pid-text", "<0.5.0>", "--trace-calls", "--module", "lists,m@n",
      "--seconds", "10",
    ])
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..tracing(["lists", "m@n"]),
        target: cli.ProcessTarget("<0.5.0>"),
        seconds: 10,
      ),
    ))
}

pub fn including_waiting_parses_for_sampling_test() {
  assert with(["--top", "1", "--include-waiting"])
    == Ok(cli.Profile(
      cli.ProfileOptions(
        ..base(),
        target: cli.TopTarget(1),
        method: cli.SampleStacks(rate_hz: 100, samples: activity.IncludeWaiting),
      ),
    ))
}

// A flag that belongs to one method is refused under the other, so a command
// line never silently ignores part of what it says.
pub fn the_flags_of_each_method_are_refused_under_the_other_test() {
  // Tracing every function is refused by the agent, so it needs modules.
  assert with(["--top", "1", "--trace-calls"])
    == Error(
      "--trace-calls needs at least one --module: the agent refuses to trace every function of a node",
    )
  assert is_error(with(["--top", "1", "--module", "lists"]))

  // Sampling flags mean nothing to a trace.
  assert is_error(
    with(["--top", "1", ..list.append(traced(["lists"]), ["--rate", "50"])]),
  )
  assert is_error(
    with(["--top", "1", ..list.append(traced(["lists"]), ["--include-waiting"])]),
  )

  // The agent's limits for a call trace.
  assert is_error(with(["--top", "5", ..traced(["lists"])]))
  assert is_error(
    with(["--top", "2", ..list.append(traced(["lists"]), ["--seconds", "11"])]),
  )
  assert is_ok(with(["--owner", "session:abc", ..traced(["lists"])]))

  // The module alphabet and the lone wildcard.
  assert is_error(with(["--top", "1", "--trace-calls", "--module", "../etc"]))
  assert is_error(with(["--top", "1", "--trace-calls", "--module", ""]))
  assert is_error(with(["--top", "1", "--trace-calls", "--module", "*"]))
  assert is_ok(with(["--top", "1", "--trace-calls", "--module", "loom@*"]))
  assert is_error(with(["--top", "1", "--trace-calls", "--module"]))
}

fn call_agent(request: wire.Request) -> Result(wire.Reply, remote.Failure) {
  case request {
    wire.Extended(wire.AskStartCalltrace(tokens, ..)) ->
      Ok(wire.CalltraceStarted(21, list.length(tokens), 7, 5000, 100_000, 2000))
    wire.Extended(wire.AskReadCalltrace(21))
    | wire.Extended(wire.AskStopCalltrace(21)) ->
      Ok(wire.CalltraceReport(traced_calls()))
    other -> agent(other)
  }
}

fn traced_calls() -> wire.CalltraceSnapshot {
  wire.CalltraceSnapshot(
    probe_id: 21,
    state: wire.ProbeFinished,
    stop: wire.TraceOverrun,
    meter: wire.CalltraceMeter(
      trace: wire.TraceMeter(
        elapsed_ms: 1200,
        events: 28_000,
        max_events: 100_000,
        dropped_events: 60_000,
        in_flight_at_stop: 59_900,
        peak_queue: 50_012,
        queue_limit: 50_000,
        targets_gone: 0,
      ),
      forced_closes: 0,
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
      wire.CallPath(6, 4_000_000, 3_000_000, [0, 1]),
      wire.CallPath(2, 5_000_000, 1_000_000, [1]),
    ],
    processes: ["<0.1.0>"],
    slices: [],
  )
}

// The command pins the owner's processes (at most four), plans and confirms
// one call tree probe over the named modules through the gate, takes the
// profile and prints how the probe ended and what it lost.
pub fn a_call_trace_runs_over_the_fake_agent_and_summarises_it_test() {
  let #(outcome, requests) =
    run_over(
      call_agent,
      cli.ProfileOptions(
        ..tracing(["lists", "m"]),
        target: cli.OwnerTarget("session:abc"),
        format: cli.TextFormat,
      ),
    )
  let assert Ok(text) = outcome

  assert string.contains(
    text,
    "traced calls of lists, m in all 2 listed processes of session:abc",
  )
  assert string.contains(
    text,
    "probe 21: 8 calls over 2 functions in 5 s, truncated: collector_overrun",
  )
  assert string.contains(text, "collector fell behind")
  assert string.contains(
    text,
    "60,000 events arrived after the stop and were discarded unread; 59,900 were already queued",
  )
  assert string.contains(
    text,
    "Untraced time inside a traced function counts as exclusive",
  )
  assert string.contains(
    text,
    "Recursion deeper than one level reads as two levels",
  )

  // The table is by exclusive time, written as a time and not as samples.
  assert string.contains(
    text,
    "functions by exclusive time of their own (4.00 ms in all)",
  )
  assert string.contains(text, "75.0%")
  assert string.contains(text, "pins released")
  assert !string.contains(text, "samples")

  // The agent was asked for exactly the modules, at the command's window.
  let assert Ok(start) =
    list.find(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCalltrace(..)) -> True
        _ -> False
      }
    })
  let assert wire.Extended(wire.AskStartCalltrace(
    tokens,
    patterns,
    duration_ms,
    ..,
  )) = start

  assert list.length(tokens) == 2
  assert patterns
    == [wire.CounterPattern("lists", "_"), wire.CounterPattern("m", "_")]
  assert duration_ms == 5000
}

pub fn a_call_trace_writes_its_profile_as_a_capture_and_collapsed_stacks_test() {
  out_dir()

  let target = cli.ProcessTarget("<0.1.0>")
  let traced_options = fn(format, out) {
    cli.ProfileOptions(
      ..tracing(["lists"]),
      target:,
      format:,
      out: Some("build/profile_cli_test_out/" <> out),
    )
  }
  let assert #(Ok(_), _) =
    run_over(call_agent, traced_options(cli.CollapsedFormat, "calls.collapsed"))
  let assert Ok(lines) =
    simplifile.read("build/profile_cli_test_out/calls.collapsed")

  // Exclusive nanoseconds, root first.
  assert lines == "m:work/0 1000000\nm:work/0;lists:sort/1 3000000\n"

  let assert #(Ok(_), _) =
    run_over(call_agent, traced_options(cli.PgcapFormat, "calls.pgcap"))
  let assert Ok(loaded) =
    capture_file.read("build/profile_cli_test_out/calls.pgcap")

  assert loaded.digest == capture_file.DigestVerified
  let assert [probe] = probe_book.of_records(loaded.capture.records)

  assert probe.kind == policy.CallTree
}

// An agent that refuses the modules (here: it matched nothing) is a typed
// failure carrying its own code.
pub fn a_call_trace_the_agent_refuses_fails_with_its_reason_test() {
  let refusing = fn(request) {
    case request {
      wire.Extended(wire.AskStartCalltrace(..)) ->
        Error(remote.Refusal("no_match", "no function of nothing matched"))
      other -> agent(other)
    }
  }
  let #(outcome, requests) =
    run_over(
      refusing,
      cli.ProfileOptions(
        ..tracing(["nothing"]),
        target: cli.ProcessTarget("<0.1.0>"),
      ),
    )
  let assert Error(profile_run.StartRefused(reason)) = outcome

  assert string.contains(reason, "no_match")

  // The agent was asked once and the command stopped there; the detach that
  // `run` always makes is what clears the pin it took.
  assert list.count(requests, fn(request) {
      case request {
        wire.Extended(wire.AskStartCalltrace(..)) -> True
        _ -> False
      }
    })
    == 1
}

pub fn every_failure_has_its_own_code_test() {
  let codes =
    list.map(
      [
        profile_run.AttachFailed("a"),
        profile_run.NoObservation("a"),
        profile_run.NoProcesses("a"),
        profile_run.PlanRefused("a"),
        profile_run.StartRefused("a"),
        profile_run.ProbeFailed("a"),
        profile_run.ProbeTimedOut("a"),
        profile_run.WriteFailed("a"),
      ],
      fn(failure) {
        let assert Ok(#(head, _)) =
          string.split_once(profile_run.describe(failure), "):")

        head
      },
    )

  assert list.unique(codes) == codes
  assert list.length(codes) == 8
}
