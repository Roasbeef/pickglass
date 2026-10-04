//// Naming a node to attach to, without reference to Loom.
////
//// `pickglass attach --node NAME@HOST` can reach any Erlang, Elixir or Gleam
//// node, not only a profiled Loom daemon. What the viewer needs in order to
//// join such a node is small: the node's full name, whether it uses long or
//// short names, and the file holding its cookie. This module holds those
//// three facts and the pure decisions around them, so each is testable
//// without a running node: splitting `NAME@HOST`, choosing the viewer's
//// naming mode from the shape of the host, refusing a host that is not on
//// this machine, and finding the default cookie file.
////
//// The viewer's hidden node must use the same naming mode as its target,
//// because a `-name` node and a `-sname` node refuse each other's
//// handshake. The mode is chosen from the host part: a host with a dot or a
//// colon (`127.0.0.1`, `app.example.com`, `::1`) is a long name, and a bare
//// word (`myhost`) is a short name. The one ambiguous case is `localhost`,
//// which is a bare word and so is treated as a short name. A target started
//// with `-name app@localhost` must be named by `app@127.0.0.1`.
////
//// Pickglass is scoped to targets on this machine for now, since the agent is
//// pushed over a trusted distribution connection and the plan keeps that
//// connection on loopback. `check_loopback` is the one place that decides
//// what counts as local, so relaxing the scope later is a change to one
//// function.
////
//// A cookie is never taken from the command line or the environment, where
//// other local users can read it. It comes from a file, either the one named
//// with `--cookie-file` or `~/.erlang.cookie`.
////
//// ## Flow
////
//// - `parse` splits `NAME@HOST` and chooses the naming mode.
//// - `check_loopback` refuses a host that is not on this machine.
//// - `default_cookie_file` names `~/.erlang.cookie` from the home directory.
//// - `node_name` and `describe_error` turn the facts and failures back into
////   text for the operator.

import gleam/bool
import gleam/list
import gleam/result
import gleam/string

/// Whether a node was started with `-name` or `-sname`.
pub type Naming {
  /// `-name app@host.example.com` or `-name app@127.0.0.1`.
  LongNames

  /// `-sname app`, whose full name is `app@` followed by the short host name.
  ShortNames
}

/// A node to attach to: its name split at the `@`, its naming mode, and the
/// owner-only file holding its cookie.
pub type Endpoint {
  Endpoint(name: String, host: String, naming: Naming, cookie_file: String)
}

/// Why a `--node` value cannot be used.
pub type EndpointError {
  /// The value is not `NAME@HOST` with a plain name and a non-empty host.
  MalformedNode(text: String)

  /// The host is not this machine; pickglass attaches to local nodes only.
  NonLoopback(host: String)
}

/// Split `NAME@HOST` and choose the naming mode from the host. The cookie
/// file is carried along unchanged.
///
/// ## Examples
///
/// ```gleam
/// endpoint.parse("app@127.0.0.1", "/home/me/.erlang.cookie")
/// // -> Ok(Endpoint("app", "127.0.0.1", LongNames, "/home/me/.erlang.cookie"))
/// endpoint.parse("app@myhost", "/c")
/// // -> Ok(Endpoint("app", "myhost", ShortNames, "/c"))
/// endpoint.parse("app", "/c")
/// // -> Error(MalformedNode("app"))
/// ```
pub fn parse(
  text: String,
  cookie_file: String,
) -> Result(Endpoint, EndpointError) {
  let malformed = MalformedNode(text)

  use #(name, host) <- result.try(
    string.split_once(text, "@") |> result.replace_error(malformed),
  )

  use <- bool.guard(
    when: !is_plain(name, name_characters),
    return: Error(malformed),
  )
  use <- bool.guard(
    when: !is_plain(host, host_characters),
    return: Error(malformed),
  )

  Ok(Endpoint(name:, host:, naming: naming_of(host), cookie_file:))
}

const name_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.+"

const host_characters =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:"

// A non-empty text made only of the allowed characters. The restriction
// keeps odd bytes out of the atom the node name becomes.
fn is_plain(text: String, allowed: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains(allowed, grapheme)
  })
}

/// The naming mode a host implies: a dot or a colon makes a long name.
///
/// ## Examples
///
/// ```gleam
/// endpoint.naming_of("127.0.0.1")
/// // -> LongNames
/// endpoint.naming_of("myhost")
/// // -> ShortNames
/// ```
pub fn naming_of(host: String) -> Naming {
  case string.contains(host, ".") || string.contains(host, ":") {
    True -> LongNames
    False -> ShortNames
  }
}

/// Refuse a host that is not this machine. The loopback addresses and
/// `localhost` are local, and so is the machine's own host name, whole or as
/// its first label, in either case.
///
/// ## Examples
///
/// ```gleam
/// endpoint.check_loopback("127.0.0.1", "mybox")
/// // -> Ok(Nil)
/// endpoint.check_loopback("mybox", "mybox.local")
/// // -> Ok(Nil)
/// endpoint.check_loopback("db.example.com", "mybox")
/// // -> Error(NonLoopback("db.example.com"))
/// ```
pub fn check_loopback(
  host: String,
  local_hostname: String,
) -> Result(Nil, EndpointError) {
  let host_text = string.lowercase(host)
  let local = string.lowercase(local_hostname)

  case
    list.contains(["127.0.0.1", "::1", "localhost"], host_text)
    || host_text == local
    || host_text == first_label(local)
  {
    True -> Ok(Nil)
    False -> Error(NonLoopback(host))
  }
}

fn first_label(hostname: String) -> String {
  case string.split_once(hostname, ".") {
    Ok(#(label, _)) -> label
    Error(Nil) -> hostname
  }
}

/// The path of the operator's own cookie file, given the `HOME` directory,
/// or `Error` when `HOME` is unset.
///
/// ## Examples
///
/// ```gleam
/// endpoint.default_cookie_file(Ok("/home/me"))
/// // -> Ok("/home/me/.erlang.cookie")
/// ```
pub fn default_cookie_file(home: Result(String, Nil)) -> Result(String, Nil) {
  case home {
    Ok("") | Error(Nil) -> Error(Nil)
    Ok(directory) -> Ok(directory <> "/.erlang.cookie")
  }
}

/// The node's full name, as the distribution knows it.
///
/// ## Examples
///
/// ```gleam
/// endpoint.node_name(endpoint)
/// // -> "app@127.0.0.1"
/// ```
pub fn node_name(endpoint: Endpoint) -> String {
  endpoint.name <> "@" <> endpoint.host
}

/// The option text OTP's `net_kernel:start/2` takes for a naming mode.
///
/// ## Examples
///
/// ```gleam
/// endpoint.domain(LongNames)
/// // -> "longnames"
/// ```
pub fn domain(naming: Naming) -> String {
  case naming {
    LongNames -> "longnames"
    ShortNames -> "shortnames"
  }
}

/// A one-line message for an operator.
///
/// ## Examples
///
/// ```gleam
/// endpoint.describe_error(NonLoopback("db.example.com"))
/// ```
pub fn describe_error(error: EndpointError) -> String {
  case error {
    MalformedNode(text) ->
      "--node must be NAME@HOST, such as app@127.0.0.1 or app@myhost, not "
      <> string.inspect(text)
    NonLoopback(host) ->
      "refusing "
      <> host
      <> ": pickglass attaches to nodes on this machine only for now; use "
      <> "127.0.0.1 or this machine's host name"
  }
}
