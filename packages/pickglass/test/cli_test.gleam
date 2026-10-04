import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass/cli.{
  Attach, AttachOptions, Open, OpenOptions, ProbeOptions, ShowBanner, ShowHelp,
  View, ViewOptions,
}
import pickglass_core/identity
import pickglass_core/owner
import pickglass_core/wire
import qcheck

pub fn no_arguments_print_the_banner_test() {
  assert cli.parse([]) == Ok(ShowBanner)
  assert cli.parse(["--help"]) == Ok(ShowHelp)
}

pub fn attach_options_parse_test() {
  assert cli.parse(["attach"])
    == Ok(Attach(AttachOptions(None, None, None, None, None)))
  assert cli.parse([
      "attach", "--state-dir", "/s", "--pid", "42", "--agent-ebin", "/e",
    ])
    == Ok(Attach(AttachOptions(Some("/s"), Some(42), Some("/e"), None, None)))
  assert cli.parse(["attach", "--probe-counters", "lists", "--seconds", "5"])
    == Ok(
      Attach(AttachOptions(
        None,
        None,
        None,
        Some(ProbeOptions("lists", 5)),
        None,
      )),
    )
}

// Every malformed command line is an error with a message, not a crash.
pub fn malformed_command_lines_are_errors_test() {
  assert is_error(cli.parse(["frobnicate"]))
  assert is_error(cli.parse(["attach", "--pid", "0"]))
  assert is_error(cli.parse(["attach", "--pid", "x"]))
  assert is_error(
    cli.parse(["attach", "--seconds", "999", "--probe-counters", "m"]),
  )
  assert is_error(cli.parse(["attach", "--probe-counters", "lists"]))
  assert is_error(cli.parse(["attach", "--seconds", "5"]))
  assert is_error(cli.parse(["attach", "--state-dir"]))
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

// Parsing is total over arbitrary argument lists.
pub fn property_parse_never_crashes_test() {
  qcheck.run(
    qcheck.default_config(),
    qcheck.generic_list(qcheck.string(), qcheck.bounded_int(0, 6)),
    fn(arguments) {
      let _ = cli.parse(arguments)
      Nil
    },
  )
}

pub fn the_report_names_unknown_owners_and_truncation_test() {
  let assert Ok(boot) = identity.boot_id("boot-1") as "valid boot id"
  let assert Ok(segment) = owner.segment("session", "s1") as "valid segment"
  let pong =
    wire.PongInfo(
      boot_id: boot,
      node: "n@127.0.0.1",
      otp_release: "29",
      uptime_ms: 5,
      pins: 0,
      probes: 0,
    )
  let memory =
    wire.MemorySnapshot(
      categories: [#("total", 104_857_600)],
      word_size: 8,
      process_count: 2,
      otp_release: "29",
      erts_version: "17",
      schedulers_online: 1,
    )
  let row =
    wire.ProcessRow(
      "<0.1.0>",
      2_097_152,
      1,
      1,
      1,
      3,
      4,
      "waiting",
      "m:f/1",
      "",
      wire.Unlabelled,
    )
  let census =
    wire.CensusSnapshot(
      coverage: wire.CensusCoverage(2, 500, wire.ScanBudgetReached, 7),
      rows: [row],
      owners: [
        wire.OwnerTotal(wire.Unlabelled, 1, 2_097_152, 3, 4),
        wire.OwnerTotal(wire.Labelled([segment], "worker"), 1, 1, 0, 0),
      ],
    )

  let text = cli.render_report(pong, memory, census)

  assert string.contains(
    text,
    "scanned 2 of 500 processes, stopped at the scan budget",
  )
  assert string.contains(text, "100.0")
  assert string.contains(text, "unknown")
  assert string.contains(text, "session:s1 (worker)")
  assert list.length(string.split(text, "\n")) > 8
}

pub fn once_and_open_and_view_parse_test() {
  assert cli.parse(["attach", "--once", "--out", "cut.pgcap"])
    == Ok(Attach(AttachOptions(None, None, None, None, Some("cut.pgcap"))))
  assert cli.parse(["open", "--pid", "7", "--port", "8080", "--cadence", "5"])
    == Ok(Open(OpenOptions(None, Some(7), None, Some(8080), None, Some(5))))
  assert cli.parse(["view", "cut.pgcap", "--port", "9000"])
    == Ok(View(ViewOptions("cut.pgcap", Some(9000))))
}

pub fn malformed_open_and_view_are_errors_test() {
  assert is_error(cli.parse(["open", "--port", "0"]))
  assert is_error(cli.parse(["open", "--cadence", "0"]))
  assert is_error(cli.parse(["open", "--frob"]))
  assert is_error(cli.parse(["view"]))
  assert is_error(cli.parse(["view", "--port", "1"]))
  assert is_error(
    cli.parse([
      "attach",
      "--out",
      "x",
      "--probe-counters",
      "m",
      "--seconds",
      "5",
    ]),
  )
}

pub fn compare_takes_two_capture_files_test() {
  assert cli.parse(["compare", "a.pgcap", "b.pgcap"])
    == Ok(cli.Compare("a.pgcap", "b.pgcap"))
}

pub fn compare_without_two_files_or_with_options_is_refused_test() {
  assert cli.parse(["compare"]) == Error("compare needs two capture files")
  assert cli.parse(["compare", "a.pgcap"])
    == Error("compare needs two capture files")
  assert cli.parse(["compare", "a", "b", "c"])
    == Error("compare needs two capture files")
  assert cli.parse(["compare", "--out", "b"])
    == Error("compare takes two capture files and no options")
}
