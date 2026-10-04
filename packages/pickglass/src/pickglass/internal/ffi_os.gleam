//// Operating-system bindings: the process table and process exit.
////
//// `os:cmd/1` runs a fixed command line and returns its output. It is used
//// only with command lines the program assembles from constants and a
//// validated integer, never from text a user or a target supplied, so there
//// is no injection surface. A bounded port would give a deadline, but the
//// `ps` call here returns in milliseconds and the port machinery is the
//// weft extension the OS readers will need later.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

@external(erlang, "os", "cmd")
fn os_cmd(command: Dynamic) -> Dynamic

@external(erlang, "erlang", "binary_to_list")
fn to_charlist(text: String) -> Dynamic

@external(erlang, "unicode", "characters_to_binary")
fn characters_to_binary(chars: Dynamic) -> Dynamic

/// Run a command line and return what it wrote to standard output and
/// standard error.
///
/// ## Examples
///
/// ```gleam
/// run("ps -ww -axo pid=,command=")
/// ```
pub fn run(command: String) -> String {
  case
    decode.run(
      characters_to_binary(os_cmd(to_charlist(command))),
      decode.string,
    )
  {
    Ok(output) -> output
    Error(_) -> ""
  }
}

/// End the VM with an exit status.
@external(erlang, "erlang", "halt")
pub fn halt(status: Int) -> Nil

@external(erlang, "os", "getenv")
fn os_getenv(name: Dynamic) -> Dynamic

/// An environment variable, or `Error` when it is unset.
pub fn getenv(name: String) -> Result(String, Nil) {
  case
    decode.run(
      characters_to_binary(os_getenv(to_charlist(name))),
      decode.string,
    )
  {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}
