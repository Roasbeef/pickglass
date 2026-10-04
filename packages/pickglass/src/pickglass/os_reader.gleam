//// What the operating system says about the target's OS process and the
//// processes it started.
////
//// The BEAM reports its own memory, but not what the kernel charges to it:
//// the resident set includes the emulator's allocations, loaded code,
//// shared libraries and memory the VM has freed and not returned. A memory
//// question about a daemon is only answered with both numbers side by
//// side, so the viewer reads the OS's figure for the target and for the
//// children the target started (for Loom, helpers such as sandboxes and
//// code-mode satellites).
////
//// Two sources are used. `ps` with one fixed command line, no argument
//// built from outside text, reads the whole process table: resident set,
//// accumulated CPU time, start time and parent. On Linux `/proc/<pid>/status`
//// and `/proc/<pid>/stat` add what `ps` cannot: the anonymous part of the
//// resident set, and a start time in clock ticks that identifies the
//// process exactly. macOS has neither, so there anon is `Missing` with the
//// reason `UnsupportedOnPlatform`, and the start time is the `ps` text
//// marked coarse, which resolves to a second. A reading that cannot be
//// taken is a `Missing` measurement that says why; it is never a zero.
////
//// A child is any process whose parent chain reaches the target within
//// `max_depth` steps, up to `max_children` of them. The bound keeps one
//// reading from growing with a process table the viewer does not control.
////
//// ## Flow
////
//// - `read` takes a reading of the target and its children now.
//// - `parse_table` and `parse_proc_status` are the pure parsers, tested on
////   the text each platform prints.
//// - `children_of` selects the descendants of a pid from a parsed table.

import gleam/int
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string
import pickglass/internal/ffi_os
import pickglass_core/identity
import pickglass_core/measure.{type Measurement, Known, Missing}
import simplifile

/// The deepest descendant read, counting the target's own children as one.
pub const max_depth = 3

/// The most child processes read.
pub const max_children = 16

/// The one command line that reads the process table. It has no argument
/// that comes from outside, so there is nothing to inject.
pub const table_command = "ps -ww -axo pid=,ppid=,rss=,time=,lstart=,comm="

/// One OS process as the viewer reports it.
pub type Reading {
  Reading(
    pid: Int,
    /// `target` for the node's own OS process, otherwise `child` followed
    /// by the executable's name.
    role: String,
    /// The resident set in bytes.
    rss: Measurement,
    /// The anonymous part of the resident set in bytes.
    anon: Measurement,
    /// CPU time used so far, in milliseconds.
    cpu_ms: Measurement,
    /// What tells this process from another one that reused its pid.
    start: identity.StartIdentity,
  )
}

/// One row of the process table.
pub type Row {
  Row(
    pid: Int,
    parent: Int,
    /// Resident set in kibibytes, as `ps` prints it.
    rss_kib: Int,
    /// CPU time in milliseconds.
    cpu_ms: Int,
    /// The start time as text, to the second.
    started: String,
    command: String,
  )
}

/// What `/proc/<pid>/status` says.
pub type ProcStatus {
  ProcStatus(rss_kib: Option(Int), anon_kib: Option(Int))
}

/// Which platform the reader found itself on.
pub type Platform {
  /// A kernel with `/proc/<pid>`.
  ProcFs

  /// Anything else; `ps` is all there is.
  PsOnly
}

// ------------------------------------------------------------------ parsing

/// Parse the process table `table_command` prints. A line that does not
/// have the expected shape is skipped.
///
/// ## Examples
///
/// ```gleam
/// os_reader.parse_table("  42     1  10240  0:01.50 Fri Oct  3 12:00:00 2026 /usr/bin/beam.smp")
/// ```
pub fn parse_table(text: String) -> List(Row) {
  text
  |> string.split("\n")
  |> list.filter_map(parse_row)
}

fn parse_row(line: String) -> Result(Row, Nil) {
  case string.split(string.trim(line), " ") |> list.filter(non_empty) {
    [pid, parent, rss, cpu, weekday, month, day, clock, year, ..command] -> {
      use pid <- result.try(int.parse(pid))
      use parent <- result.try(int.parse(parent))
      use rss_kib <- result.try(int.parse(rss))
      use cpu_ms <- result.try(parse_cpu_time(cpu))

      Ok(Row(
        pid:,
        parent:,
        rss_kib:,
        cpu_ms:,
        started: string.join([weekday, month, day, clock, year], " "),
        command: string.join(command, " "),
      ))
    }
    _ -> Error(Nil)
  }
}

fn non_empty(text: String) -> Bool {
  text != ""
}

/// Parse the CPU time `ps` prints into milliseconds: `mm:ss.hh` on macOS,
/// `[dd-]hh:mm:ss` on Linux, and the forms between.
///
/// ## Examples
///
/// ```gleam
/// os_reader.parse_cpu_time("1:02.50")
/// // -> Ok(62_500)
/// os_reader.parse_cpu_time("1-00:00:01")
/// // -> Ok(86_401_000)
/// ```
pub fn parse_cpu_time(text: String) -> Result(Int, Nil) {
  let #(days, clock) = case string.split_once(text, "-") {
    Ok(#(days, rest)) -> #(int.parse(days), rest)
    Error(Nil) -> #(Ok(0), text)
  }

  use days <- result.try(days)

  case string.split(clock, ":") {
    [minutes, seconds] -> {
      use minutes <- result.try(int.parse(minutes))
      use seconds <- result.map(parse_seconds(seconds))

      days * 86_400_000 + minutes * 60_000 + seconds
    }
    [hours, minutes, seconds] -> {
      use hours <- result.try(int.parse(hours))
      use minutes <- result.try(int.parse(minutes))
      use seconds <- result.map(parse_seconds(seconds))

      days * 86_400_000 + hours * 3_600_000 + minutes * 60_000 + seconds
    }
    _ -> Error(Nil)
  }
}

// Whole seconds with an optional fraction, in milliseconds. A fraction is
// cut to three digits, so `ps`'s hundredths and a finer reading both work.
fn parse_seconds(text: String) -> Result(Int, Nil) {
  case string.split_once(text, ".") {
    Ok(#(whole, fraction)) -> {
      use whole <- result.try(int.parse(whole))
      use millis <- result.map(
        int.parse(string.pad_end(string.slice(fraction, 0, 3), 3, "0")),
      )

      whole * 1000 + millis
    }
    Error(Nil) -> int.parse(text) |> result.map(fn(whole) { whole * 1000 })
  }
}

/// Parse `/proc/<pid>/status` for the resident set and its anonymous part,
/// both in kibibytes. A field that is absent is `None`.
///
/// ## Examples
///
/// ```gleam
/// os_reader.parse_proc_status("VmRSS:\t  2048 kB\nRssAnon:\t  1024 kB\n")
/// // -> ProcStatus(rss_kib: Some(2048), anon_kib: Some(1024))
/// ```
pub fn parse_proc_status(text: String) -> ProcStatus {
  let field = fn(name) {
    text
    |> string.split("\n")
    |> list.find_map(fn(line) {
      case string.split_once(line, ":") {
        Ok(#(key, value)) if key == name -> {
          case string.split(string.trim(value), " ") {
            [number, ..] -> int.parse(number)
            [] -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })
    |> option.from_result
  }

  ProcStatus(rss_kib: field("VmRSS"), anon_kib: field("RssAnon"))
}

/// Parse `/proc/<pid>/stat` for the start time in clock ticks since boot,
/// which identifies a process more exactly than `ps` can. The command name
/// is in parentheses and may itself contain spaces and parentheses, so the
/// fields are counted from the last closing parenthesis.
///
/// ## Examples
///
/// ```gleam
/// os_reader.parse_proc_start("42 (beam.smp) S 1 42 42 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 8 0 987654 1 2")
/// // -> Ok("987654")
/// ```
pub fn parse_proc_start(text: String) -> Result(String, Nil) {
  use #(_, after) <- result.try(split_after_last(text, ")"))

  case string.split(string.trim(after), " ") |> list.drop(19) {
    [ticks, ..] -> Ok(ticks)
    [] -> Error(Nil)
  }
}

fn split_after_last(
  text: String,
  separator: String,
) -> Result(#(String, String), Nil) {
  case string.split(text, separator) |> list.reverse {
    [last, ..front] if front != [] ->
      Ok(#(string.join(list.reverse(front), separator), last))
    _ -> Error(Nil)
  }
}

// ----------------------------------------------------------------- children

/// The descendants of `pid` in a process table, nearest first, to
/// `max_depth` levels and at most `max_children` of them. A cycle in a
/// corrupt table cannot loop: each pid is visited once.
///
/// ## Examples
///
/// ```gleam
/// os_reader.children_of(rows, 100)
/// ```
pub fn children_of(rows: List(Row), pid: Int) -> List(Row) {
  descend(rows, [pid], [pid], max_depth, [])
  |> list.take(max_children)
}

fn descend(
  rows: List(Row),
  frontier: List(Int),
  seen: List(Int),
  depth: Int,
  found: List(Row),
) -> List(Row) {
  case depth, frontier {
    0, _ | _, [] -> list.reverse(found)
    _, _ -> {
      let level =
        list.filter(rows, fn(row) {
          list.contains(frontier, row.parent) && !list.contains(seen, row.pid)
        })

      descend(
        rows,
        list.map(level, fn(row) { row.pid }),
        list.append(seen, list.map(level, fn(row) { row.pid })),
        depth - 1,
        list.append(list.reverse(level), found),
      )
    }
  }
}

// ------------------------------------------------------------------ reading

/// Read the target and its children now. `Error` only when there is no way
/// to read the process table at all; a target that is not in the table is a
/// reading whose figures say so.
///
/// ## Examples
///
/// ```gleam
/// os_reader.read(48211)
/// ```
pub fn read(target: Int) -> Result(List(Reading), String) {
  let table = parse_table(ffi_os.run(table_command))
  let platform = platform()

  case table {
    [] -> Error("the OS process table could not be read")
    _ -> {
      let own = case list.find(table, fn(row) { row.pid == target }) {
        Ok(row) -> reading_of(row, "target", platform)
        Error(Nil) -> gone(target)
      }
      let children =
        children_of(table, target)
        |> list.map(fn(row) {
          reading_of(row, "child " <> executable(row.command), platform)
        })

      Ok([own, ..children])
    }
  }
}

fn platform() -> Platform {
  case simplifile.is_directory("/proc/self") {
    Ok(True) -> ProcFs
    _ -> PsOnly
  }
}

fn gone(pid: Int) -> Reading {
  Reading(
    pid:,
    role: "target",
    rss: Missing(measure.ProcessExited),
    anon: Missing(measure.ProcessExited),
    cpu_ms: Missing(measure.ProcessExited),
    start: identity.UnreadableStart,
  )
}

// A `ps` row, refined by `/proc` where the platform has it. On a platform
// without it the anonymous resident set is not something `ps` can say, and
// the start time is the text `ps` prints, good to a second.
fn reading_of(row: Row, role: String, platform: Platform) -> Reading {
  let base =
    Reading(
      pid: row.pid,
      role:,
      rss: Known(row.rss_kib * 1024),
      anon: Missing(measure.UnsupportedOnPlatform),
      cpu_ms: Known(row.cpu_ms),
      start: identity.CoarseStart(row.started),
    )

  case platform {
    PsOnly -> base
    ProcFs -> refine(base)
  }
}

fn refine(base: Reading) -> Reading {
  let pid = int.to_string(base.pid)
  let status =
    simplifile.read("/proc/" <> pid <> "/status")
    |> result.map(parse_proc_status)
  let start =
    simplifile.read("/proc/" <> pid <> "/stat")
    |> result.replace_error(Nil)
    |> result.try(parse_proc_start)

  Reading(
    ..base,
    rss: case status {
      Ok(ProcStatus(rss_kib: Some(kib), ..)) -> Known(kib * 1024)
      _ -> base.rss
    },
    anon: case status {
      Ok(ProcStatus(anon_kib: Some(kib), ..)) -> Known(kib * 1024)
      _ -> Missing(measure.UnsupportedOnRuntime)
    },
    start: case start {
      Ok(ticks) -> identity.PreciseStart(ticks)
      Error(Nil) -> base.start
    },
  )
}

// The executable's file name, without its directory.
fn executable(command: String) -> String {
  case list.last(string.split(command, "/")) {
    Ok(name) if name != "" -> name
    _ -> command
  }
}

/// The reading of the target among a snapshot, if it is there.
pub fn target_of(readings: List(Reading)) -> Option(Reading) {
  list.find(readings, fn(reading) { reading.role == "target" })
  |> option.from_result
}
