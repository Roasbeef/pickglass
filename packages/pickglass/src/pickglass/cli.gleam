//// The command line: parsing, running and printing.
////
//// `pickglass open` and `pickglass view` start the host (`serve` runs them),
//// and `pickglass attach --once --out` writes one capture (`once` runs it).
//// `pickglass attach` joins a node, prints what the agent
//// reports, and detaches. The node is found one of two ways: the Loom way
//// (`--state-dir` and `--pid`, a `loomd --profile` daemon) or by name
//// (`--node NAME@HOST` with a cookie file), which reaches any Erlang, Elixir
//// or Gleam node on this machine. `pickglass attach --probe-counters MODULE
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
//// - `parse` turns arguments into a `Command`. `extract_selection` takes the
////   target-selecting flags out first, so `selector_of` can check them
////   together: the two ways of finding a target are mutually exclusive, and a
////   cookie is only ever named by a file.
//// - `connect` resolves a `Selector` to an endpoint and attaches.
//// - `run_attach` connects, calls `observe` (which
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
import pickglass/endpoint
import pickglass/internal/ffi_dist
import pickglass/internal/ffi_os
import pickglass_core/owner
import pickglass_core/profile/activity
import pickglass_core/wire
import pickglass_web/wire as web_wire

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

  /// Print two captures side by side.
  Compare(baseline: String, candidate: String)

  /// Attach, run one stack probe through the gate, write the profile and
  /// detach.
  Profile(ProfileOptions)
}

/// What `pickglass profile` samples.
pub type ProfileTarget {
  /// The processes of one owner, as `kind:id` segments joined by `/`, or the
  /// word `unknown` for the processes nobody claimed.
  OwnerTarget(owner: String)

  /// The busiest processes of the node by reductions per second.
  TopTarget(count: Int)

  /// One process, by the pid text a census shows.
  ProcessTarget(pid_text: String)
}

/// The file `pickglass profile` writes.
pub type ProfileFormat {
  /// speedscope JSON, which opens at speedscope.app.
  SpeedscopeFormat

  /// Collapsed stacks, for flamegraph.pl and its relatives.
  CollapsedFormat

  /// A Chrome trace of the profile's function totals.
  ChromeFormat

  /// A `pickglass.capture/1` file holding the observations and the profile.
  PgcapFormat

  /// The summary and an indented call tree as text.
  TextFormat
}

/// How `pickglass profile` measures the processes it chose.
pub type ProfileMethod {
  /// Poll the stacks of the processes at a rate. `samples` is which of the
  /// samples the summary and the file include: by default only those taken
  /// while a process was running or runnable, because on an idle node most
  /// samples find processes waiting in `receive`.
  SampleStacks(rate_hz: Int, samples: activity.Inclusion)

  /// Trace the calls of the named modules in the processes and build a call
  /// tree with exact call counts and times. The modules are required: the
  /// agent refuses to trace every function of a node.
  TraceCalls(modules: List(String))
}

/// Options of `pickglass profile`.
pub type ProfileOptions {
  ProfileOptions(
    selector: Selector,
    agent_ebin: Option(String),
    target: ProfileTarget,
    /// How long to sample or trace, in seconds.
    seconds: Int,
    /// Where to write the file, or `None` for the format's default name in
    /// the current directory. The text format with no file prints only.
    out: Option(String),
    format: ProfileFormat,
    method: ProfileMethod,
  )
}

/// The longest a call trace may run, in seconds: the agent's limit.
pub const trace_seconds_max = 10

/// How long a call trace runs when `--seconds` is not given.
pub const trace_seconds_default = 5

/// The most processes a call trace may name: the agent's limit.
pub const trace_processes_max = 4

/// How the target is found.
pub type Selector {
  /// A profiled Loom daemon, found from the process table and a Loom state
  /// directory (default `~/.loom`), optionally by process id.
  LoomTarget(state_dir: Option(String), pid: Option(Int))

  /// Any node on this machine, by `NAME@HOST`, with its cookie read from a
  /// file: the named one, or `~/.erlang.cookie`.
  NamedNode(node: String, cookie_file: Option(String))
}

/// The target-selecting flags as typed, before they are checked against one
/// another.
pub type Selection {
  Selection(
    state_dir: Option(String),
    pid: Option(Int),
    node: Option(String),
    cookie_file: Option(String),
  )
}

/// Options of `pickglass open`.
pub type OpenOptions {
  OpenOptions(
    selector: Selector,
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
    selector: Selector,
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
  "usage: pickglass open TARGET [--agent-ebin DIR]
                      [--port N] [--save-dir DIR] [--cadence SECONDS]
       pickglass view FILE [--port N]
       pickglass compare BASELINE CANDIDATE
       pickglass attach TARGET [--agent-ebin DIR]
                        [--probe-counters MODULE --seconds N]
       pickglass attach TARGET --once --out FILE
       pickglass profile TARGET (--owner KIND:ID | --top N | --pid-text PID)
                         [--seconds S] [--rate HZ] [--include-waiting]
                         [--out FILE]
                         [--format speedscope|collapsed|chrome|pgcap|text]
       pickglass profile TARGET (--owner KIND:ID | --top N | --pid-text PID)
                         --trace-calls --module MODULE [--module MODULE ...]
                         [--seconds S] [--out FILE]
                         [--format speedscope|collapsed|chrome|pgcap|text]

TARGET is one of
  [--state-dir DIR] [--pid PID]
      a profiled Loom daemon (loomd --profile); the state directory defaults
      to ~/.loom
  --node NAME@HOST [--cookie-file PATH]
      any Erlang, Elixir or Gleam node on this machine, with NAME@HOST as
      its node name (app@127.0.0.1 for -name, app@myhost for -sname)
The two are mutually exclusive.

The cookie is read from a file and never from an argument or the
environment, because argument lists and environments are readable by other
local users and end up in shell history. --cookie and --setcookie are
refused. The file must be readable by its owner alone. Without
--cookie-file the cookie is read from ~/.erlang.cookie.

profile samples the stacks of an owner's processes (--owner session:abc, a
path such as session:abc/strand:def, or unknown), of the busiest N processes
(--top N, at most 16), or of one process (--pid-text <0.123.0>) for S
seconds (default 10) at HZ samples a second per process (default 100). It
goes through the same plan, confirm and audit path as the pages, as the
local owner, writes the profile (speedscope JSON by default, which opens at
speedscope.app) and prints a summary. --format text prints an indented call
tree instead of writing a file. By default only the samples taken while a
process was running or runnable are counted, since on an idle node the others
find processes waiting for a message; --include-waiting counts them too, and
the summary states how the samples split.

--trace-calls traces the calls of the modules named with --module (names of
loaded modules, or a prefix ending in one *, as in my_app*, which stands for
every loaded module that starts with it; repeated or separated by commas) in
at most 4
processes for at most 10 seconds (default 5) and builds a call tree from the
exact calls and their times. At least one module is required, because the
agent refuses to trace every function of a node. --rate and --include-waiting
apply to sampling only.

open attaches, serves the pages on 127.0.0.1 and prints a single-use URL.
view serves the pages over a capture file with no target. compare prints two
capture files side by side: which fields of their provenance differ, which
of those block a statement of direction, and each figure with its verdict.
attach prints memory, the top processes and the owner totals and detaches;
with --once --out it writes one capture and detaches; with --probe-counters
it also runs a counters probe over every process for N seconds."

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
    ["attach", ..rest] -> {
      use #(selection, rest) <- result.try(extract_selection(rest))
      use selector <- result.try(selector_of(selection))

      parse_attach(rest, AttachOptions(selector, None, None, None), None, None)
    }
    ["open", ..rest] -> {
      use #(selection, rest) <- result.try(extract_selection(rest))
      use selector <- result.try(selector_of(selection))

      parse_open(rest, OpenOptions(selector, None, None, None, None))
    }
    ["view", file, ..rest] ->
      case string.starts_with(file, "-") {
        True -> Error("view needs a capture file")
        False -> parse_view(rest, ViewOptions(file, None))
      }
    ["view"] -> Error("view needs a capture file")
    ["compare", baseline, candidate] ->
      case
        string.starts_with(baseline, "-") || string.starts_with(candidate, "-")
      {
        True -> Error("compare takes two capture files and no options")
        False -> Ok(Compare(baseline:, candidate:))
      }
    ["compare", ..] -> Error("compare needs two capture files")
    ["profile", ..rest] -> {
      use #(selection, rest) <- result.try(extract_selection(rest))
      use selector <- result.try(selector_of(selection))

      parse_profile(rest, selector)
    }
    [other, ..] -> Error("unknown command: " <> other)
  }
}

/// Take the target-selecting flags (`--state-dir`, `--pid`, `--node`,
/// `--cookie-file`) out of an argument list, returning them and the
/// arguments that remain. A cookie given as an argument is refused here,
/// whatever its spelling.
///
/// ## Examples
///
/// ```gleam
/// cli.extract_selection(["--node", "app@127.0.0.1", "--once"])
/// // -> Ok(#(Selection(None, None, Some("app@127.0.0.1"), None), ["--once"]))
/// ```
pub fn extract_selection(
  arguments: List(String),
) -> Result(#(Selection, List(String)), String) {
  extract(arguments, Selection(None, None, None, None), [])
}

fn extract(
  arguments: List(String),
  selection: Selection,
  kept: List(String),
) -> Result(#(Selection, List(String)), String) {
  case arguments {
    [] -> Ok(#(selection, list.reverse(kept)))
    ["--state-dir", value, ..rest] ->
      extract(rest, Selection(..selection, state_dir: Some(value)), kept)
    ["--node", value, ..rest] ->
      extract(rest, Selection(..selection, node: Some(value)), kept)
    ["--cookie-file", value, ..rest] ->
      extract(rest, Selection(..selection, cookie_file: Some(value)), kept)
    ["--pid", value, ..rest] ->
      case int.parse(value) {
        Ok(pid) if pid > 0 ->
          extract(rest, Selection(..selection, pid: Some(pid)), kept)
        _ -> Error("--pid must be a positive integer")
      }
    ["--cookie", ..] | ["--setcookie", ..] -> Error(cookie_argument_refused)
    [flag, ..rest] ->
      case string.starts_with(flag, "--cookie=") {
        True -> Error(cookie_argument_refused)
        False -> extract(rest, selection, [flag, ..kept])
      }
  }
}

const cookie_argument_refused =
  "a cookie is never taken from the command line, where other local users can read it; put it in a file readable by you alone and pass --cookie-file PATH (the default is ~/.erlang.cookie)"

/// Check the selecting flags against one another and choose how to find the
/// target. `--node` and the Loom flags are alternatives, and a cookie file
/// belongs to `--node` alone.
///
/// ## Examples
///
/// ```gleam
/// cli.selector_of(Selection(None, Some(7), Some("app@127.0.0.1"), None))
/// // -> Error("--node cannot be combined with --state-dir or --pid; ...")
/// ```
pub fn selector_of(selection: Selection) -> Result(Selector, String) {
  case selection {
    Selection(state_dir:, pid:, node: None, cookie_file: None) ->
      Ok(LoomTarget(state_dir, pid))
    Selection(node: None, cookie_file: Some(_), ..) ->
      Error("--cookie-file needs --node")
    Selection(state_dir: None, pid: None, node: Some(node), cookie_file:) ->
      endpoint.parse(node, "")
      |> result.map(fn(_) { NamedNode(node, cookie_file) })
      |> result.map_error(endpoint.describe_error)
    Selection(node: Some(_), ..) ->
      Error(
        "--node cannot be combined with --state-dir or --pid; choose one way "
        <> "to find the target",
      )
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
    ["--agent-ebin", value, ..rest] ->
      parse_attach(
        rest,
        AttachOptions(..options, agent_ebin: Some(value)),
        module,
        seconds,
      )
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
    ["--agent-ebin", value, ..rest] ->
      parse_open(rest, OpenOptions(..options, agent_ebin: Some(value)))
    ["--save-dir", value, ..rest] ->
      parse_open(rest, OpenOptions(..options, save_dir: Some(value)))
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

// `pickglass profile` takes exactly one of --owner, --top and --pid-text.
fn parse_profile(
  arguments: List(String),
  selector: Selector,
) -> Result(Command, String) {
  profile_flags(
    arguments,
    ProfileOptions(
      selector:,
      agent_ebin: None,
      target: TopTarget(0),
      seconds: 10,
      out: None,
      format: SpeedscopeFormat,
      method: SampleStacks(rate_hz: 100, samples: activity.OnSchedulerOnly),
    ),
    no_flags,
  )
}

// What the flags have said so far that depends on which method is chosen:
// the method is known only once every flag has been read, so a flag that
// belongs to one is held here and checked against it at the end.
type Flags {
  Flags(
    targets: List(ProfileTarget),
    seconds: Option(Int),
    rate_hz: Option(Int),
    waiting: Option(Nil),
    tracing: Option(Nil),
    modules: List(String),
  )
}

const no_flags =
  Flags(
    targets: [],
    seconds: None,
    rate_hz: None,
    waiting: None,
    tracing: None,
    modules: [],
  )

fn profile_flags(
  arguments: List(String),
  options: ProfileOptions,
  flags: Flags,
) -> Result(Command, String) {
  case arguments {
    [] -> finish_profile(options, flags)
    ["--agent-ebin", value, ..rest] ->
      profile_flags(
        rest,
        ProfileOptions(..options, agent_ebin: Some(value)),
        flags,
      )
    ["--out", value, ..rest] ->
      profile_flags(rest, ProfileOptions(..options, out: Some(value)), flags)
    ["--owner", value, ..rest] -> {
      use owner_text <- result.try(owner_argument(value))

      profile_flags(
        rest,
        options,
        Flags(..flags, targets: [OwnerTarget(owner_text), ..flags.targets]),
      )
    }
    ["--top", value, ..rest] ->
      case int.parse(value) {
        Ok(count) if count >= 1 && count <= 16 ->
          profile_flags(
            rest,
            options,
            Flags(..flags, targets: [TopTarget(count), ..flags.targets]),
          )
        _ -> Error("--top must be between 1 and 16, the agent's limit")
      }
    ["--pid-text", value, ..rest] ->
      case pid_text_shaped(value) {
        True ->
          profile_flags(
            rest,
            options,
            Flags(..flags, targets: [ProcessTarget(value), ..flags.targets]),
          )
        False -> Error("--pid-text must look like <0.123.0>")
      }
    ["--seconds", value, ..rest] ->
      case int.parse(value) {
        Ok(count) if count >= 1 && count <= 60 ->
          profile_flags(rest, options, Flags(..flags, seconds: Some(count)))
        _ -> Error("--seconds must be between 1 and 60 for a stack probe")
      }
    ["--rate", value, ..rest] ->
      case int.parse(value) {
        Ok(hz) if hz >= 1 && hz <= 1000 ->
          profile_flags(rest, options, Flags(..flags, rate_hz: Some(hz)))
        _ -> Error("--rate must be between 1 and 1000 samples a second")
      }
    ["--include-waiting", ..rest] ->
      profile_flags(rest, options, Flags(..flags, waiting: Some(Nil)))
    ["--trace-calls", ..rest] ->
      profile_flags(rest, options, Flags(..flags, tracing: Some(Nil)))
    ["--module", value, ..rest] -> {
      use named <- result.try(module_arguments(value))

      profile_flags(
        rest,
        options,
        Flags(..flags, modules: list.append(flags.modules, named)),
      )
    }
    ["--format", value, ..rest] ->
      case profile_format(value) {
        Ok(format) ->
          profile_flags(rest, ProfileOptions(..options, format:), flags)
        Error(Nil) ->
          Error(
            "--format must be one of speedscope, collapsed, chrome, pgcap, text",
          )
      }
    [flag, ..] -> Error("unknown or incomplete option: " <> flag)
  }
}

// The flags are read; now they are checked against the method they chose.
// Each flag that belongs to one method only is refused under the other, so a
// command line never silently ignores part of what it says.
fn finish_profile(
  options: ProfileOptions,
  flags: Flags,
) -> Result(Command, String) {
  use target <- result.try(case flags.targets {
    [one] -> Ok(one)
    [] -> Error("profile needs one of --owner, --top and --pid-text")
    _ -> Error("profile takes only one of --owner, --top and --pid-text")
  })

  case flags.tracing {
    None -> finish_sampling(options, flags, target)
    Some(Nil) -> finish_tracing(options, flags, target)
  }
}

fn finish_sampling(
  options: ProfileOptions,
  flags: Flags,
  target: ProfileTarget,
) -> Result(Command, String) {
  case flags.modules {
    [_, ..] ->
      Error("--module applies to --trace-calls, which names what to trace")
    [] ->
      Ok(Profile(
        ProfileOptions(
          ..options,
          target:,
          seconds: option.unwrap(flags.seconds, 10),
          method: SampleStacks(
            rate_hz: option.unwrap(flags.rate_hz, 100),
            samples: case flags.waiting {
              Some(Nil) -> activity.IncludeWaiting
              None -> activity.OnSchedulerOnly
            },
          ),
        ),
      ))
  }
}

fn finish_tracing(
  options: ProfileOptions,
  flags: Flags,
  target: ProfileTarget,
) -> Result(Command, String) {
  let seconds = option.unwrap(flags.seconds, trace_seconds_default)

  case flags.modules, flags.rate_hz, flags.waiting, target {
    [], _, _, _ ->
      Error(
        "--trace-calls needs at least one --module: the agent refuses to trace every function of a node",
      )
    _, Some(_), _, _ ->
      Error("--rate applies to stack sampling, not to --trace-calls")
    _, _, Some(_), _ ->
      Error(
        "--include-waiting applies to stack sampling: a call trace records no process status",
      )
    _, _, _, TopTarget(count) if count > trace_processes_max ->
      Error(
        "--top must be between 1 and "
        <> int.to_string(trace_processes_max)
        <> " for --trace-calls, the agent's limit",
      )
    _, _, _, _ ->
      case seconds <= trace_seconds_max {
        False ->
          Error(
            "--seconds must be between 1 and "
            <> int.to_string(trace_seconds_max)
            <> " for --trace-calls, the agent's limit",
          )
        True ->
          Ok(Profile(
            ProfileOptions(
              ..options,
              target:,
              seconds:,
              method: TraceCalls(modules: flags.modules),
            ),
          ))
      }
  }
}

// A `--module` value is one name or several joined by commas or spaces, from
// the alphabet the page's form accepts, each optionally ending in one `*` as
// a prefix of the loaded module names. Any other `*` is refused here with the
// reason, as the page's form refuses it.
fn module_arguments(value: String) -> Result(List(String), String) {
  case web_wire.module_patterns(value) {
    Error(web_wire.NoPatterns) -> Error("--module needs a module name")
    Error(web_wire.TooManyPatterns) ->
      Error("--module names too many modules for one call trace")
    Error(web_wire.BadPattern(text:)) ->
      Error("--module takes letters, digits, _ and @ only; refused: " <> text)
    Error(web_wire.WildcardPattern(text:)) ->
      Error(
        "--module "
        <> text
        <> " has a misplaced wildcard: only a trailing * after a module name prefix, as in runtime@*, is accepted",
      )
    Ok(names) -> Ok(names)
  }
}

fn profile_format(text: String) -> Result(ProfileFormat, Nil) {
  case text {
    "speedscope" -> Ok(SpeedscopeFormat)
    "collapsed" -> Ok(CollapsedFormat)
    "chrome" -> Ok(ChromeFormat)
    "pgcap" -> Ok(PgcapFormat)
    "text" -> Ok(TextFormat)
    _ -> Error(Nil)
  }
}

// An owner is `unknown` or one or more `kind:id` segments joined by `/`, the
// way the owners page writes a path. Each segment must be one core accepts.
fn owner_argument(text: String) -> Result(String, String) {
  case text {
    "unknown" -> Ok(text)
    _ ->
      case
        list.try_map(string.split(text, "/"), fn(segment) {
          case string.split_once(segment, ":") {
            Ok(#(kind, id)) -> owner.segment(kind, id)
            Error(Nil) -> Error(Nil)
          }
        })
      {
        Ok(_) -> Ok(text)
        Error(Nil) ->
          Error(
            "--owner must be unknown or KIND:ID segments joined by /, such as session:abc",
          )
      }
  }
}

// A pid as the census prints it: `<` three numbers joined by dots `>`.
fn pid_text_shaped(text: String) -> Bool {
  case string.starts_with(text, "<") && string.ends_with(text, ">") {
    False -> False
    True ->
      case string.split(string.slice(text, 1, string.length(text) - 2), ".") {
        [a, b, c] -> list.all([a, b, c], digits)
        _ -> False
      }
  }
}

fn digits(text: String) -> Bool {
  text != "" && result.is_ok(int.parse(text)) && !string.starts_with(text, "-")
}

/// Find the target and attach to it. A Loom target is discovered under the
/// state directory, which defaults to `~/.loom`. A named node is checked
/// against the loopback scope, its cookie file is resolved, and its
/// operating-system process id is read once attached.
///
/// ## Examples
///
/// ```gleam
/// cli.connect(LoomTarget(None, None), None)
/// cli.connect(NamedNode("app@127.0.0.1", None), None)
/// ```
pub fn connect(
  selector: Selector,
  agent_ebin: Option(String),
) -> Result(#(discover.Target, Session), String) {
  let beams = option.to_result(agent_ebin, Nil)

  case selector {
    LoomTarget(state_dir, pid) -> {
      use state_dir <- result.try(state_directory(state_dir))
      use target <- result.try(
        discover.find(state_dir, pid) |> result.map_error(describe_discovery),
      )
      use named <- result.try(
        endpoint.parse(target.node, target.cookie_file)
        |> result.map_error(endpoint.describe_error),
      )
      use session <- result.map(
        attach.attach(named, beams) |> result.map_error(attach.describe),
      )

      #(target, session)
    }
    NamedNode(node, cookie_file) -> {
      use cookie_file <- result.try(cookie_file_of(cookie_file))
      use named <- result.try(
        endpoint.parse(node, cookie_file)
        |> result.map_error(endpoint.describe_error),
      )
      use _ <- result.try(
        endpoint.check_loopback(
          named.host,
          result.unwrap(ffi_dist.local_hostname(), ""),
        )
        |> result.map_error(endpoint.describe_error),
      )
      use session <- result.try(
        attach.attach(named, beams) |> result.map_error(attach.describe),
      )

      // The process id comes from the node itself. A node that cannot say
      // is detached from, so the failed command leaves no agent behind.
      case attach.os_pid(session) {
        Ok(os_pid) -> Ok(#(discover.Target(os_pid, node, cookie_file), session))
        Error(message) -> {
          let _ = attach.detach(session)

          Error(message)
        }
      }
    }
  }
}

fn cookie_file_of(named: Option(String)) -> Result(String, String) {
  case named {
    Some(path) -> Ok(path)
    None ->
      endpoint.default_cookie_file(ffi_os.getenv("HOME"))
      |> result.replace_error("HOME is unset; pass --cookie-file")
  }
}

/// The role a capture records for the target: `loomd` for a profiled Loom
/// daemon, `node` for a node named with `--node`.
///
/// ## Examples
///
/// ```gleam
/// cli.role(NamedNode("app@127.0.0.1", None))
/// // -> "node"
/// ```
pub fn role(selector: Selector) -> String {
  case selector {
    LoomTarget(..) -> "loomd"
    NamedNode(..) -> "node"
  }
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
  use #(_, session) <- result.try(connect(options.selector, options.agent_ebin))

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
    attach.OtherViewersRemain(count) ->
      "detached; the agent stays on the target for the other viewers ("
      <> int.to_string(count)
      <> " attached)"
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
