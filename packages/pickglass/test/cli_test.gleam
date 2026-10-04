import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass/cli.{Attach, AttachOptions, ProbeOptions, ShowBanner, ShowHelp}
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
    == Ok(Attach(AttachOptions(None, None, None, None)))
  assert cli.parse([
      "attach", "--state-dir", "/s", "--pid", "42", "--agent-ebin", "/e",
    ])
    == Ok(Attach(AttachOptions(Some("/s"), Some(42), Some("/e"), None)))
  assert cli.parse(["attach", "--probe-counters", "lists", "--seconds", "5"])
    == Ok(
      Attach(AttachOptions(None, None, None, Some(ProbeOptions("lists", 5)))),
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
