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
import pickglass/profile_run
import pickglass/remote
import pickglass_core/identity
import pickglass_core/wire
import simplifile

// ----------------------------------------------------------------- parsing

fn base() -> cli.ProfileOptions {
  cli.ProfileOptions(
    selector: cli.NamedNode("app@127.0.0.1", Some("/c")),
    agent_ebin: None,
    target: cli.TopTarget(0),
    seconds: 10,
    rate_hz: 100,
    out: None,
    format: cli.SpeedscopeFormat,
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
        rate_hz: 250,
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
  let seen = process.new_subject()
  let outcome =
    profile_run.execute(
      options,
      "0.0.0",
      "fake@127.0.0.1",
      1,
      fixture.fake_remote(seen, agent),
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

fn out_dir() {
  let assert Ok(Nil) =
    simplifile.create_directory_all("build/profile_cli_test_out")
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
  assert string.contains(text, "194 samples")
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
  assert weights == [[44, 150]] || weights == [[150, 44]]
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

  assert string.contains(text, "call tree (share of 194 samples)")
  assert string.contains(text, "100.0%  loom@runtime:root/1")
  assert string.contains(text, "77.3%    loom@runtime:leaf/1")
  assert !string.contains(text, "wrote ")
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
  assert lines
    == "loom@runtime:root/1 44\nloom@runtime:root/1;loom@runtime:leaf/1 150\n"

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
