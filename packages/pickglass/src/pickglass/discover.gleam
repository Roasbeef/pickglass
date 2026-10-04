//// Finding a profiled Loom daemon to attach to, and the cookie that opens
//// it.
////
//// A daemon started with `loomd --profile` runs a distributed node named
//// `loom_daemon_profile_<pid>_<32 hex digits>@127.0.0.1` whose home
//// directory, and so its cookie, is a private directory under
//// `<state-root>/tokens/`. `scripts/observer.sh` in Loom finds it by reading
//// the process table, and this module does the same, keeping the parts that
//// decide something pure so they can be tested without a daemon: reading
//// the process table, matching a node to a cookie directory, and checking
//// that the cookie file is readable by its owner alone.
////
//// The node name embeds the OS process id of the emulator, and discovery
//// requires the embedded id to equal the id `ps` reports. That rejects stale
//// credentials and unrelated emulators, including code-mode satellites. The
//// cookie is read from a file and never from an argument or the environment,
//// and this module never returns it in an error message.
////
//// ## Flow
////
//// - `candidates` reads a process table into profiled-node candidates.
//// - `choose` matches candidates with cookie directories and picks one.
//// - `find` reads the process table, lists the cookie directories and
////   calls `choose`.
//// - `read_cookie_file` checks a cookie file's permissions and reads it.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pickglass/internal/ffi_os
import simplifile

/// Which kind of Loom process a profiled node belongs to.
pub type Role {
  Daemon
  Client
}

/// A profiled node found in the process table, before its cookie directory
/// is matched.
pub type Candidate {
  Candidate(os_pid: Int, node: String, role: Role, command: String)
}

/// A node with the file holding its cookie. For a profiled Loom node the
/// file is `<cookie directory>/.erlang.cookie`; for a node named with
/// `--node` it is the file the operator chose.
pub type Target {
  Target(os_pid: Int, node: String, cookie_file: String)
}

/// Why no target was chosen.
pub type DiscoverError {
  /// No profiled process with a matching cookie directory was found.
  NoTarget

  /// More than one matched; the caller must name one with a pid.
  Ambiguous(os_pids: List(Int))

  /// The state directory could not be read.
  StateUnreadable(path: String)

  /// The cookie file is missing, unreadable, or readable by others.
  CookieRefused(reason: String)
}

/// Read profiled nodes out of a process table in `pid command` lines, as
/// `ps -ww -axo pid=,command=` prints it.
///
/// ## Examples
///
/// ```gleam
/// discover.candidates("123 erl -name loom_daemon_profile_123_" <> hex <> "@127.0.0.1 -home /x")
/// // -> [Candidate(123, "loom_daemon_profile_123_...@127.0.0.1", Daemon, ...)]
/// ```
pub fn candidates(table: String) -> List(Candidate) {
  table
  |> string.split("\n")
  |> list.filter_map(candidate)
}

fn candidate(line: String) -> Result(Candidate, Nil) {
  let line = string.trim(line)

  use #(pid_text, command) <- result.try(string.split_once(line, " "))
  use os_pid <- result.try(int.parse(pid_text))
  use node_name <- result.try(name_argument(string.split(command, " ")))
  use role <- result.try(profiled_role(node_name, os_pid))

  Ok(Candidate(
    os_pid:,
    node: node_name,
    role:,
    command: " " <> string.trim(command) <> " ",
  ))
}

// The token after `-name`.
fn name_argument(tokens: List(String)) -> Result(String, Nil) {
  case tokens {
    ["-name", name, ..] -> Ok(name)
    [_, ..rest] -> name_argument(rest)
    [] -> Error(Nil)
  }
}

// `loom_<role>_profile_<pid>_<32 lowercase hex>@127.0.0.1`, with the pid
// equal to the one `ps` reported.
fn profiled_role(node_name: String, os_pid: Int) -> Result(Role, Nil) {
  case string.split(node_name, "@") {
    [name, "127.0.0.1"] ->
      case string.split(name, "_") {
        ["loom", role, "profile", pid, suffix] -> {
          use role <- result.try(parse_role(role))
          use embedded <- result.try(int.parse(pid))

          case embedded == os_pid && is_hex32(suffix) {
            True -> Ok(role)
            False -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn parse_role(text: String) -> Result(Role, Nil) {
  case text {
    "daemon" -> Ok(Daemon)
    "client" -> Ok(Client)
    _ -> Error(Nil)
  }
}

fn is_hex32(text: String) -> Bool {
  string.length(text) == 32
  && list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains("0123456789abcdef", grapheme)
  })
}

/// Match candidates with cookie directories and choose one. A candidate
/// matches a directory when its command line carries `-home <directory>`.
/// With no pid requested only daemons are considered, as `observer.sh`
/// does; naming a pid permits a terminal client as well.
///
/// ## Examples
///
/// ```gleam
/// discover.choose(candidates, ["/state/tokens/loom-daemon-profile.AbC"], None)
/// // -> Ok(Target(123, node, "/state/tokens/loom-daemon-profile.AbC/.erlang.cookie"))
/// ```
pub fn choose(
  candidates: List(Candidate),
  cookie_directories: List(String),
  wanted_pid: Option(Int),
) -> Result(Target, DiscoverError) {
  let matches =
    list.flat_map(candidates, fn(candidate) {
      case wanted(candidate, wanted_pid) {
        False -> []
        True ->
          list.filter_map(cookie_directories, fn(directory) {
            case
              string.contains(candidate.command, " -home " <> directory <> " ")
            {
              True ->
                Ok(Target(
                  candidate.os_pid,
                  candidate.node,
                  directory <> "/.erlang.cookie",
                ))
              False -> Error(Nil)
            }
          })
      }
    })

  case matches {
    [] -> Error(NoTarget)
    [only] -> Ok(only)
    many -> Error(Ambiguous(list.map(many, fn(target) { target.os_pid })))
  }
}

fn wanted(candidate: Candidate, wanted_pid: Option(Int)) -> Bool {
  case wanted_pid {
    Some(pid) -> candidate.os_pid == pid
    None -> candidate.role == Daemon
  }
}

/// Find the profiled node to attach to under a state directory.
///
/// ## Examples
///
/// ```gleam
/// discover.find("/home/me/.loom", None)
/// // -> Ok(Target(...))
/// ```
pub fn find(
  state_dir: String,
  wanted_pid: Option(Int),
) -> Result(Target, DiscoverError) {
  let table = ffi_os.run(process_table_command(wanted_pid))
  let tokens = state_dir <> "/tokens"

  use entries <- result.try(
    simplifile.read_directory(tokens)
    |> result.replace_error(StateUnreadable(tokens)),
  )

  let directories =
    entries
    |> list.filter(fn(entry) { is_cookie_directory(entry) })
    |> list.map(fn(entry) { tokens <> "/" <> entry })
    |> list.filter(fn(directory) {
      simplifile.is_file(directory <> "/.erlang.cookie") == Ok(True)
    })

  choose(candidates(table), directories, wanted_pid)
}

fn process_table_command(wanted_pid: Option(Int)) -> String {
  case wanted_pid {
    Some(pid) -> "ps -ww -p " <> int.to_string(pid) <> " -o pid=,command="
    None -> "ps -ww -axo pid=,command="
  }
}

fn is_cookie_directory(entry: String) -> Bool {
  string.starts_with(entry, "loom-daemon-profile.")
  || string.starts_with(entry, "loom-client-profile.")
}

/// The permission bits that must be clear on a cookie file: anything for
/// group or others.
const others_mask = 0o77

/// Read a cookie from a file, refusing one that group or others can read.
/// The cookie grants full control of the target, so a file anyone can read
/// is not a credential this program will use. The cookie is trimmed of its
/// trailing newline and never appears in an error.
///
/// ## Examples
///
/// ```gleam
/// discover.read_cookie_file("/home/me/.erlang.cookie")
/// // -> Ok("...")
/// ```
pub fn read_cookie_file(path: String) -> Result(String, DiscoverError) {
  use info <- result.try(
    simplifile.file_info(path)
    |> result.replace_error(CookieRefused("the cookie file cannot be read")),
  )

  case
    int.bitwise_and(simplifile.file_info_permissions_octal(info), others_mask)
  {
    0 ->
      simplifile.read(path)
      |> result.map(string.trim)
      |> result.replace_error(CookieRefused("the cookie file cannot be read"))
    _ -> Error(CookieRefused("the cookie file is readable by group or others"))
  }
}
