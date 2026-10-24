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
//// function. A host counts as local when it is a loopback name, this
//// machine's host name, or an address assigned to one of this machine's own
//// network interfaces, such as a Tailscale address. The interface addresses
//// are read by the caller and passed in, which keeps the decision pure.
////
//// A cookie is never taken from the command line or the environment, where
//// other local users can read it. It comes from a file, either the one named
//// with `--cookie-file` or `~/.erlang.cookie`.
////
//// ## Flow
////
//// - `parse` splits `NAME@HOST` and chooses the naming mode.
//// - `check_loopback` refuses a host that is not on this machine, comparing an
////   address host with the interface addresses by value (`address_groups`).
//// - `default_cookie_file` names `~/.erlang.cookie` from the home directory.
//// - `node_name` and `describe_error` turn the facts and failures back into
////   text for the operator.

import gleam/bool
import gleam/int
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
/// its first label, in either case. So is an address currently assigned to one
/// of the machine's own network interfaces, such as a Tailscale address: the
/// caller reads those addresses once and passes them as text in
/// `interface_addresses`, so this function stays pure.
///
/// Addresses are compared by value, not by spelling, so `::1` and
/// `0:0:0:0:0:0:0:1` match, and so do upper and lower case hex. A host that
/// is not an address is never matched against the list, and no name is
/// resolved: a name that merely resolves to a local address is refused. An
/// IPv6 zone id (`fe80::1%en0`) is not accepted.
///
/// ## Examples
///
/// ```gleam
/// endpoint.check_loopback("127.0.0.1", "mybox", [])
/// // -> Ok(Nil)
/// endpoint.check_loopback("mybox", "mybox.local", [])
/// // -> Ok(Nil)
/// endpoint.check_loopback("100.75.241.68", "mybox", ["100.75.241.68"])
/// // -> Ok(Nil)
/// endpoint.check_loopback("db.example.com", "mybox", [])
/// // -> Error(NonLoopback("db.example.com"))
/// ```
pub fn check_loopback(
  host: String,
  local_hostname: String,
  interface_addresses: List(String),
) -> Result(Nil, EndpointError) {
  let host_text = string.lowercase(host)
  let local = string.lowercase(local_hostname)

  case
    list.contains(["127.0.0.1", "::1", "localhost"], host_text)
    || host_text == local
    || host_text == first_label(local)
    || is_interface_address(host_text, interface_addresses)
  {
    True -> Ok(Nil)
    False -> Error(NonLoopback(host))
  }
}

// An address host matches when some interface address has the same value.
fn is_interface_address(
  host: String,
  interface_addresses: List(String),
) -> Bool {
  case address_groups(host) {
    Error(Nil) -> False
    Ok(wanted) ->
      list.any(interface_addresses, fn(candidate) {
        address_groups(string.lowercase(candidate)) == Ok(wanted)
      })
  }
}

/// An IPv4 or IPv6 literal as its numeric groups: four bytes for IPv4 and
/// eight 16-bit groups for IPv6, so two spellings of one address give one
/// value. `Error` for anything else, including a zone id, a name, and an
/// IPv4 octet with a leading zero.
///
/// ## Examples
///
/// ```gleam
/// endpoint.address_groups("100.75.241.68")
/// // -> Ok([100, 75, 241, 68])
/// endpoint.address_groups("::1")
/// // -> Ok([0, 0, 0, 0, 0, 0, 0, 1])
/// endpoint.address_groups("mybox")
/// // -> Error(Nil)
/// ```
pub fn address_groups(text: String) -> Result(List(Int), Nil) {
  case string.contains(text, ":") {
    True -> ipv6_groups(text)
    False -> ipv4_groups(text)
  }
}

fn ipv4_groups(text: String) -> Result(List(Int), Nil) {
  let parts = string.split(text, ".")

  use <- bool.guard(when: list.length(parts) != 4, return: Error(Nil))
  list.try_map(parts, fn(part) { bounded_number(part, 10, 3, 255) })
}

// A number written in `base` with one to `width` digits, at most `largest`,
// and no sign. Decimal text keeps no leading zero, since some resolvers read
// one as octal.
fn bounded_number(
  text: String,
  base: Int,
  width: Int,
  largest: Int,
) -> Result(Int, Nil) {
  let length = string.length(text)
  let digits_only =
    list.all(string.to_graphemes(text), fn(grapheme) {
      string.contains("0123456789abcdef", grapheme)
    })
  let padded = base == 10 && length > 1 && string.starts_with(text, "0")

  use <- bool.guard(
    when: length < 1 || length > width || !digits_only || padded,
    return: Error(Nil),
  )
  use value <- result.try(int.base_parse(text, base))

  case value <= largest {
    True -> Ok(value)
    False -> Error(Nil)
  }
}

// A trailing dotted quad becomes its two hex groups, so the rest of the
// parse sees only colon-separated groups.
fn ipv6_groups(text: String) -> Result(List(Int), Nil) {
  use expanded <- result.try(case string.contains(text, ".") {
    False -> Ok(text)
    True -> expand_dotted_tail(text)
  })

  case string.split(expanded, "::") {
    [whole] -> {
      use groups <- result.try(hex_groups(whole))
      case list.length(groups) {
        8 -> Ok(groups)
        _ -> Error(Nil)
      }
    }
    [left, right] -> {
      use before <- result.try(hex_groups(left))
      use after <- result.try(hex_groups(right))
      let missing = 8 - list.length(before) - list.length(after)

      case missing >= 1 {
        True -> Ok(list.flatten([before, list.repeat(0, missing), after]))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn expand_dotted_tail(text: String) -> Result(String, Nil) {
  use #(head, tail) <- result.try(split_last_colon(text))
  use bytes <- result.try(ipv4_groups(tail))

  case bytes {
    [a, b, c, d] ->
      Ok(string.lowercase(
        head
        <> ":"
        <> int.to_base16(a * 256 + b)
        <> ":"
        <> int.to_base16(c * 256 + d),
      ))
    _ -> Error(Nil)
  }
}

fn split_last_colon(text: String) -> Result(#(String, String), Nil) {
  let parts = string.split(text, ":")

  use last <- result.try(list.last(parts))
  let head = string.drop_end(text, string.length(last) + 1)

  Ok(#(head, last))
}

// Colon-separated groups of one to four hex digits. The empty text is no
// groups, which is what `::` leaves on its empty side.
fn hex_groups(text: String) -> Result(List(Int), Nil) {
  case text {
    "" -> Ok([])
    _ ->
      string.split(text, ":")
      |> list.try_map(fn(group) { bounded_number(group, 16, 4, 65_535) })
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
      <> "127.0.0.1, this machine's host name, or an address assigned to one "
      <> "of its network interfaces"
  }
}
