//// The command line: parsing, running and printing.
////
//// `pickglass open` and `pickglass view` start the host (`serve` runs them),
//// and `pickglass attach --once --out` writes one capture (`once` runs it).
//// `pickglass attach` joins a profiled Loom daemon, prints what the agent
//// reports, and detaches. `pickglass attach --probe-counters MODULE
//// --seconds N` also runs a counters probe over every process for N seconds
//// and prints the functions that spent the most time. With no arguments the
//// program prints its banner, which is what the release smoke test checks.
////
//// Parsing and rendering are pure so they can be tested without a daemon.
//// Only `run` touches the target, and it always detaches, so a failed
//// request never leaves a session running on the target. If the process is
//// killed, the agent notices by itself.
////
//// ## Flow
////
//// - `parse` turns arguments into a `Command`.
//// - `run_attach` discovers the target, attaches, calls `observe` (which
////   calls `run_probe` when a probe was asked for), and detaches.
//// - `render_report` and `render_probe` format what the agent returned.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/attach.{type Session}
import pickglass/discover
import pickglass/internal/ffi_os
import pickglass_core/owner
import pickglass_core/wire

/// What to run.
pub type Command {
  /// No arguments: print the banner.
  ShowBanner

  /// Print usage.
  ShowHelp

  /// Attach and report.
  Attach(AttachOptions)

  /// Attach to a target and serve the pages.
  Open(OpenOptions)

  /// Serve the pages over a capture file, with no target.
  View(ViewOptions)
}

/// Options of `pickglass open`.
pub type OpenOptions {
  OpenOptions(
    state_dir: Option(String),
    pid: Option(Int),
    agent_ebin: Option(String),
    /// The port to listen on, or `None` for any free one.
    port: Option(Int),
    /// Where captures saved from a page are written, or `None` for the
    /// current directory.
    save_dir: Option(String),
    /// Seconds between collection passes, or `None` for two.
    cadence_s: Option(Int),
  )
}

/// Options of `pickglass view`.
pub type ViewOptions {
  ViewOptions(file: String, port: Option(Int))
}

/// Options of `pickglass attach`.
pub type AttachOptions {
  AttachOptions(
    state_dir: Option(String),
    pid: Option(Int),
    agent_ebin: Option(String),
    probe: Option(ProbeOptions),
    /// With `--once`, the file to write one capture to.
    once: Option(String),
  )
}

/// A counters probe request.
pub type ProbeOptions {
  ProbeOptions(module: String, seconds: Int)
}

/// The usage text.
pub const usage =
  "usage: pickglass open [--state-dir DIR] [--pid PID] [--agent-ebin DIR]
                      [--port N] [--save-dir DIR] [--cadence SECONDS]
       pickglass view FILE [--port N]
       pickglass attach [--state-dir DIR] [--pid PID] [--agent-ebin DIR]
                        [--probe-counters MODULE --seconds N]
       pickglass attach --once --out FILE [--state-dir DIR] [--pid PID]

open attaches to a profiled Loom daemon (loomd --profile), serves the pages
on 127.0.0.1 and prints a single-use URL. view serves the pages over a
capture file with no target. attach prints memory, the top processes and the
owner totals and detaches; with --once --out it writes one capture and
detaches; with --probe-counters it also runs a counters probe over every
process for N seconds. The state directory defaults to ~/.loom."

/// Parse arguments.
///
/// ## Examples
///
/// ```gleam
/// cli.parse(["attach", "--pid", "123"])
/// // -> Ok(Attach(AttachOptions(None, Some(123), None, None, None)))
/// ```
pub fn parse(arguments: List(String)) -> Result(Command, String) {
  case arguments {
    [] -> Ok(ShowBanner)
    ["--help"] | ["-h"] | ["help"] -> Ok(ShowHelp)
    ["attach", ..rest] ->
      parse_attach(
        rest,
        AttachOptions(None, None, None, None, None),
        None,
        None,
      )
    ["open", ..rest] ->
      parse_open(rest, OpenOptions(None, None, None, None, None, None))
    ["view", file, ..rest] ->
      case string.starts_with(file, "-") {
        True -> Error("view needs a capture file")
        False -> parse_view(rest, ViewOptions(file, None))
      }
    ["view"] -> Error("view needs a capture file")
    [other, ..] -> Error("unknown command: " <> other)
  }
}

fn parse_attach(
  arguments: List(String),
  options: AttachOptions,
  module: Option(String),
  seconds: Option(Int),
) -> Result(Command, String) {
  case arguments {
    [] -> finish_attach(options, module, seconds)
    ["--state-dir", value, ..rest] ->
      parse_attach(
        rest,
        AttachOptions(..options, state_dir: Some(value)),
        module,
        seconds,
      )
    ["--agent-ebin", value, ..rest] ->
      parse_attach(
        rest,
        AttachOptions(..options, agent_ebin: Some(value)),
        module,
        seconds,
      )
    ["--pid", value, ..rest] ->
      case int.parse(value) {
        Ok(pid) if pid > 0 ->
          parse_attach(
            rest,
            AttachOptions(..options, pid: Some(pid)),
            module,
            seconds,
          )
        _ -> Error("--pid must be a positive integer")
      }
    ["--out", value, ..rest] ->
      parse_attach(
        rest,
        AttachOptions(..options, once: Some(value)),
        module,
        seconds,
      )
    ["--once", ..rest] -> parse_attach(rest, options, module, seconds)
    ["--probe-counters", value, ..rest] ->
      parse_attach(rest, options, Some(value), seconds)
    ["--seconds", value, ..rest] ->
      case int.parse(value) {
        Ok(count) if count >= 1 && count <= 300 ->
          parse_attach(rest, options, module, Some(count))
        _ -> Error("--seconds must be between 1 and 300")
      }
    [flag, ..] -> Error("unknown or incomplete option: " <> flag)
  }
}

fn finish_attach(
  options: AttachOptions,
  module: Option(String),
  seconds: Option(Int),
) -> Result(Command, String) {
  case module, seconds {
    None, None -> Ok(Attach(options))
    _, _ if options.once != None -> Error("--once --out takes no probe options")
    Some(name), Some(count) ->
      Ok(Attach(
        AttachOptions(..options, probe: Some(ProbeOptions(name, count))),
      ))
    Some(_), None -> Error("--probe-counters needs --seconds")
    None, Some(_) -> Error("--seconds needs --probe-counters")
  }
}

fn parse_open(
  arguments: List(String),
  options: OpenOptions,
) -> Result(Command, String) {
  case arguments {
    [] -> Ok(Open(options))
    ["--state-dir", value, ..rest] ->
      parse_open(rest, OpenOptions(..options, state_dir: Some(value)))
    ["--agent-ebin", value, ..rest] ->
      parse_open(rest, OpenOptions(..options, agent_ebin: Some(value)))
    ["--save-dir", value, ..rest] ->
      parse_open(rest, OpenOptions(..options, save_dir: Some(value)))
    ["--pid", value, ..rest] ->
      case int.parse(value) {
        Ok(pid) if pid > 0 ->
          parse_open(rest, OpenOptions(..options, pid: Some(pid)))
        _ -> Error("--pid must be a positive integer")
      }
    ["--port", value, ..rest] ->
      case int.parse(value) {
        Ok(port) if port >= 1 && port <= 65_535 ->
          parse_open(rest, OpenOptions(..options, port: Some(port)))
        _ -> Error("--port must be between 1 and 65535")
      }
    ["--cadence", value, ..rest] ->
      case int.parse(value) {
        Ok(seconds) if seconds >= 1 && seconds <= 3600 ->
          parse_open(rest, OpenOptions(..options, cadence_s: Some(seconds)))
        _ -> Error("--cadence must be between 1 and 3600 seconds")
      }
    [flag, ..] -> Error("unknown or incomplete option: " <> flag)
  }
}

fn parse_view(
  arguments: List(String),
  options: ViewOptions,
) -> Result(Command, String) {
  case arguments {
    [] -> Ok(View(options))
    ["--port", value, ..rest] ->
      case int.parse(value) {
        Ok(port) if port >= 1 && port <= 65_535 ->
          parse_view(rest, ViewOptions(..options, port: Some(port)))
        _ -> Error("--port must be between 1 and 65535")
      }
    [flag, ..] -> Error("unknown or incomplete option: " <> flag)
  }
}

/// Discover the target and attach to it. The state directory defaults to
/// `~/.loom`.
///
/// ## Examples
///
/// ```gleam
/// cli.connect(None, None, None)
/// ```
pub fn connect(
  state_dir: Option(String),
  pid: Option(Int),
  agent_ebin: Option(String),
) -> Result(#(discover.Target, Session), String) {
  use state_dir <- result.try(state_directory(state_dir))
  use target <- result.try(
    discover.find(state_dir, pid) |> result.map_error(describe_discovery),
  )
  use session <- result.map(attach.attach(
    target,
    option.to_result(agent_ebin, Nil),
  ))

  #(target, session)
}

/// Run an attach command and return the process exit status.
///
/// ## Examples
///
/// ```gleam
/// cli.run_attach(options)
/// // -> 0
/// ```
pub fn run_attach(options: AttachOptions) -> Int {
  case attach_and_report(options) {
    Ok(text) -> {
      io.println(text)

      0
    }
    Error(message) -> {
      io.println_error("pickglass: " <> message)

      1
    }
  }
}

fn attach_and_report(options: AttachOptions) -> Result(String, String) {
  use #(_, session) <- result.try(connect(
    options.state_dir,
    options.pid,
    options.agent_ebin,
  ))

  // Detach runs whether or not the requests succeed, so an error never
  // leaves a probe counting on the target.
  let observed = observe(session, options.probe)
  let unload = attach.detach(session)

  use text <- result.map(observed)

  text <> "\n" <> describe_unload(unload)
}

fn state_directory(named: Option(String)) -> Result(String, String) {
  case named {
    Some(directory) -> Ok(directory)
    None ->
      case ffi_os.getenv("HOME") {
        Ok(home) -> Ok(home <> "/.loom")
        Error(Nil) -> Error("HOME is unset; pass --state-dir")
      }
  }
}

fn describe_discovery(error: discover.DiscoverError) -> String {
  case error {
    discover.NoTarget ->
      "no profiled daemon found; start loomd with --profile and check --state-dir"
    discover.Ambiguous(pids) ->
      "several profiled processes found ("
      <> string.join(list.map(pids, int.to_string), ", ")
      <> "); choose one with --pid"
    discover.StateUnreadable(path) -> "cannot read " <> path
    discover.CookieRefused(reason) -> reason
  }
}

fn describe_unload(unload: attach.Unload) -> String {
  case unload {
    attach.ModulesUnloaded ->
      "detached; the agent's modules are unloaded from the target"
    attach.ModulesRemain(count) ->
      "detached; "
      <> int.to_string(count)
      <> " agent modules were still loaded after the wait"
    attach.ModulesUnreadable ->
      "detached; the target could not be asked whether the agent unloaded"
  }
}

fn observe(
  session: Session,
  probe: Option(ProbeOptions),
) -> Result(String, String) {
  use pong <- result.try(expect_pong(attach.request(session, wire.AskPing)))
  use memory <- result.try(
    expect_memory(attach.request(session, wire.AskMemory)),
  )
  use census <- result.try(
    expect_census(attach.request(session, wire.AskCensus(200_000, 200))),
  )

  let report = render_report(pong, memory, census)

  case probe {
    None -> Ok(report)
    Some(options) -> {
      use probe_text <- result.map(run_probe(session, options))

      report <> "\n\n" <> probe_text
    }
  }
}

fn expect_pong(
  reply: Result(wire.Reply, String),
) -> Result(wire.PongInfo, String) {
  case reply {
    Ok(wire.Pong(info)) -> Ok(info)
    Ok(_) -> Error("unexpected reply to ping")
    Error(message) -> Error(message)
  }
}

fn expect_memory(
  reply: Result(wire.Reply, String),
) -> Result(wire.MemorySnapshot, String) {
  case reply {
    Ok(wire.MemoryReport(info)) -> Ok(info)
    Ok(_) -> Error("unexpected reply to memory")
    Error(message) -> Error(message)
  }
}

fn expect_census(
  reply: Result(wire.Reply, String),
) -> Result(wire.CensusSnapshot, String) {
  case reply {
    Ok(wire.CensusReport(info)) -> Ok(info)
    Ok(_) -> Error("unexpected reply to census")
    Error(message) -> Error(message)
  }
}

// A probe also turns on scheduler wall time so the report can say how busy
// the node was while it ran, and reads the probe's counters twice a second
// while it waits, which is what a live view would do. The agent, not this
// loop, enforces the deadline, so a viewer that dies mid-probe leaves
// nothing counting.
fn run_probe(
  session: Session,
  options: ProbeOptions,
) -> Result(String, String) {
  use _ <- result.try(attach.request(
    session,
    wire.AskScheduler(wire.SchedulerOn),
  ))
  use before <- result.try(scheduler_readings(session))
  use started <- result.try(attach.request(
    session,
    wire.AskStartCounters(
      options.module,
      "_",
      wire.AllProcesses,
      options.seconds * 1000 + 5000,
    ),
  ))

  case started {
    wire.CountersStarted(probe_id, matched, _) -> {
      let polls = poll_while_waiting(session, probe_id, options.seconds * 2, 0)

      use after <- result.try(scheduler_readings(session))
      use stopped <- result.try(attach.request(
        session,
        wire.AskStopCounters(probe_id),
      ))

      case stopped {
        wire.CountersReport(snapshot) ->
          Ok(
            render_probe(options.module, matched, options.seconds, snapshot)
            <> "\n  scheduler utilization during the probe: "
            <> utilization(before, after)
            <> "\n  the probe was read "
            <> int.to_string(polls)
            <> " times while it ran",
          )
        _ -> Error("unexpected reply to stop_counters")
      }
    }
    _ -> Error("unexpected reply to start_counters")
  }
}

fn scheduler_readings(
  session: Session,
) -> Result(List(wire.SchedulerReading), String) {
  case attach.request(session, wire.AskScheduler(wire.SchedulerRead)) {
    Ok(wire.SchedulerReport(report)) -> Ok(report.readings)
    Ok(_) -> Error("unexpected reply to scheduler")
    Error(message) -> Error(message)
  }
}

// Sum of active time over sum of total time, across the change between two
// readings, as a percentage with one decimal.
fn utilization(
  before: List(wire.SchedulerReading),
  after: List(wire.SchedulerReading),
) -> String {
  let active =
    total_of(after, fn(r) { r.active }) - total_of(before, fn(r) { r.active })
  let total =
    total_of(after, fn(r) { r.total }) - total_of(before, fn(r) { r.total })

  case total > 0 {
    False -> "not available"
    True -> {
      let tenths = active * 1000 / total

      int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10) <> "%"
    }
  }
}

fn total_of(
  readings: List(wire.SchedulerReading),
  pick: fn(wire.SchedulerReading) -> Int,
) -> Int {
  list.fold(readings, 0, fn(sum, reading) { sum + pick(reading) })
}

fn poll_while_waiting(
  session: Session,
  probe_id: Int,
  remaining: Int,
  polls: Int,
) -> Int {
  case remaining > 0 {
    False -> polls
    True -> {
      let _ = attach.request(session, wire.AskReadCounters(probe_id))

      sleep(500)

      poll_while_waiting(session, probe_id, remaining - 1, polls + 1)
    }
  }
}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

// ---------------------------------------------------------------- rendering

/// Format the ping, memory and census replies as text.
///
/// ## Examples
///
/// ```gleam
/// cli.render_report(pong, memory, census)
/// // -> "node: ...\n..."
/// ```
pub fn render_report(
  pong: wire.PongInfo,
  memory: wire.MemorySnapshot,
  census: wire.CensusSnapshot,
) -> String {
  let coverage = census.coverage

  string.join(
    [
      "node: " <> pong.node <> "  OTP " <> pong.otp_release,
      "",
      "memory (MiB)",
      string.join(list.map(memory.categories, memory_line), "\n"),
      "",
      "census: scanned "
        <> int.to_string(coverage.scanned)
        <> " of "
        <> int.to_string(coverage.total)
        <> " processes, "
        <> stop_text(coverage.stop)
        <> ", "
        <> int.to_string(coverage.elapsed_ms)
        <> " ms",
      "",
      "top 10 processes by memory",
      string.join(
        list.map(list.take(census.rows, 10), fn(row) { process_line(row) }),
        "\n",
      ),
      "",
      "owners",
      string.join(list.map(list.take(census.owners, 10), owner_line), "\n"),
    ],
    "\n",
  )
}

fn memory_line(category: #(String, Int)) -> String {
  "  " <> string.pad_end(category.0, 14, " ") <> mebibytes(category.1)
}

fn mebibytes(bytes: Int) -> String {
  let tenths = bytes * 10 / 1_048_576

  string.pad_start(
    int.to_string(tenths / 10) <> "." <> int.to_string(tenths % 10),
    9,
    " ",
  )
}

fn stop_text(stop: wire.CensusStop) -> String {
  case stop {
    wire.WalkFinished -> "complete"
    wire.ScanBudgetReached -> "stopped at the scan budget"
    wire.DeadlineReached -> "stopped at the deadline"
  }
}

fn process_line(row: wire.ProcessRow) -> String {
  let name = case row.registered_name {
    "" -> row.current_function
    registered -> registered
  }

  "  "
  <> string.pad_end(row.pid_text, 14, " ")
  <> mebibytes(row.memory)
  <> " MiB  queue "
  <> string.pad_start(int.to_string(row.queue_length), 5, " ")
  <> "  "
  <> string.pad_end(string.slice(name, 0, 33), 34, " ")
  <> owner_text(row.owner)
}

fn owner_line(total: wire.OwnerTotal) -> String {
  "  "
  <> string.pad_end(owner_text(total.owner), 40, " ")
  <> string.pad_start(int.to_string(total.processes), 7, " ")
  <> " processes "
  <> mebibytes(total.memory)
  <> " MiB"
}

fn owner_text(reading: wire.OwnerReading) -> String {
  case reading {
    wire.Unlabelled -> "unknown"
    wire.Labelled(path, role) ->
      owner.path_to_string(path) <> " (" <> role <> ")"
  }
}

/// Format a stopped counters probe: the top functions by call time.
///
/// ## Examples
///
/// ```gleam
/// cli.render_probe("lists", 12, 5, snapshot)
/// // -> "counters probe on lists ..."
/// ```
pub fn render_probe(
  module: String,
  matched: Int,
  seconds: Int,
  snapshot: wire.CountersSnapshot,
) -> String {
  string.join(
    [
      "counters probe on "
        <> module
        <> " for "
        <> int.to_string(seconds)
        <> " s: "
        <> int.to_string(matched)
        <> " functions traced, "
        <> int.to_string(snapshot.with_calls)
        <> " called, "
        <> int.to_string(snapshot.invalidated)
        <> " invalidated",
      "  call time sums over every traced process, and calls are not split by process",
      string.join(
        list.map(list.take(snapshot.rows, 10), fn(row) { function_line(row) }),
        "\n",
      ),
    ],
    "\n",
  )
}

fn function_line(row: wire.FunctionRow) -> String {
  "  "
  <> string.pad_end(
    row.module <> ":" <> row.function <> "/" <> int.to_string(row.arity),
    44,
    " ",
  )
  <> string.pad_start(int.to_string(row.calls), 12, " ")
  <> " calls "
  <> string.pad_start(int.to_string(row.time_us), 12, " ")
  <> " us"
}
