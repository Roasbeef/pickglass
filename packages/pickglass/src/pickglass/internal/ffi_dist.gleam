//// Distribution bindings: joining the target as a hidden node, calling
//// into it, and addressing the agent.
////
//// Every function binds an existing OTP function. `gleam_erlang` has no
//// distribution API beyond reading the node's own name, and weft has none,
//// so there is no library alternative. The viewer starts distribution with
//// `dist_listen` false: it opens no listening socket, so no third node can
//// reach it or route through it, and it is hidden, so it does not appear in
//// the target's `nodes()` for ordinary tools.
////
//// Calls into the target go through `rpc:call/5`, which returns
//// `{badrpc, Reason}` instead of raising, so a dead node or a bad call
//// becomes an `Error` value.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Identity cast to `Dynamic`, used to place pids and references into the
/// terms the wire carries.
@external(erlang, "gleam_stdlib", "identity")
pub fn to_dynamic(value: a) -> Dynamic

@external(erlang, "erlang", "is_alive")
fn is_alive() -> Bool

@external(erlang, "net_kernel", "start")
fn net_kernel_start(name: Atom, options: Dynamic) -> Dynamic

@external(erlang, "init", "get_argument")
fn init_get_argument(name: Atom) -> Dynamic

/// Whether this VM was started with its own cookie arrangement: `-nocookie`
/// or `-setcookie`. Without either, starting distribution makes OTP's `auth`
/// read `~/.erlang.cookie` and create it, with a random value, when it is
/// missing. A viewer that attaches to a node must not write into the
/// operator's home, so the launcher starts the VM with `-nocookie` and this
/// reports it.
///
/// ## Examples
///
/// ```gleam
/// has_private_cookie()
/// // -> True under the release launcher
/// ```
pub fn has_private_cookie() -> Bool {
  first_is_ok(init_get_argument(atom.create("nocookie")))
  || first_is_ok(init_get_argument(atom.create("setcookie")))
}

/// Start distribution as a hidden, non-listening node with a full name on
/// the loopback address. Does nothing if this VM is already distributed.
/// Refuses when the VM has no cookie arrangement of its own, because
/// starting distribution would then create `~/.erlang.cookie`.
///
/// With `-nocookie` the node holds no cookie at all: it is not listening,
/// so nothing connects to it, and the one cookie it uses is the target's,
/// set per peer by `set_cookie`.
///
/// `domain` is OTP's `name_domain` option, `"longnames"` or `"shortnames"`,
/// and must match the target's: a `-name` node and a `-sname` node refuse
/// each other's handshake. A short name is given without its host.
///
/// ## Examples
///
/// ```gleam
/// start_hidden_node("pickglass_viewer_1@127.0.0.1", "longnames")
/// // -> Ok(Nil)
/// ```
pub fn start_hidden_node(name: String, domain: String) -> Result(Nil, String) {
  case is_alive(), has_private_cookie() {
    True, _ -> Ok(Nil)
    False, False ->
      Error(
        "this VM has no cookie of its own, and starting distribution would "
        <> "create ~/.erlang.cookie; run the pickglass release, or start "
        <> "erl with -nocookie (ERL_FLAGS=-nocookie)",
      )
    False, True -> {
      let options =
        dynamic.properties([
          #(key("name_domain"), to_dynamic(atom.create(domain))),
          #(key("hidden"), to_dynamic(True)),
          #(key("dist_listen"), to_dynamic(False)),
        ])

      case first_is_ok(net_kernel_start(atom.create(name), options)) {
        True -> Ok(Nil)
        False -> Error("could not start distribution (is epmd reachable?)")
      }
    }
  }
}

fn key(name: String) -> Dynamic {
  to_dynamic(atom.create(name))
}

// `{ok, _}` is success; anything else, including `{error, _}`, is not.
fn first_is_ok(result: Dynamic) -> Bool {
  case decode.run(result, decode.field(0, atom.decoder(), decode.success)) {
    Ok(tag) -> atom.to_string(tag) == "ok"
    Error(_) -> False
  }
}

@external(erlang, "erlang", "set_cookie")
fn erlang_set_cookie(node: Atom, cookie: Atom) -> Bool

/// Set the cookie this node uses for one peer. It is set per target so that
/// the target's cookie never becomes this node's own.
pub fn set_cookie(node: Atom, cookie: Atom) -> Nil {
  let _ = erlang_set_cookie(node, cookie)

  Nil
}

@external(erlang, "net_kernel", "connect_node")
fn connect_node(node: Atom) -> Dynamic

/// Connect to a node. `Error` when it is unreachable, refuses the cookie, or
/// uses the other naming mode: OTP answers `false` for all three, so the
/// caller works out which.
pub fn connect(node: Atom) -> Result(Nil, Nil) {
  case connect_node(node) == to_dynamic(True) {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

@external(erlang, "net_kernel", "stop")
fn net_kernel_stop() -> Dynamic

/// Stop this VM's distribution, so it can be started again under the other
/// naming mode. Only the failure diagnosis does this.
pub fn stop_distribution() -> Nil {
  let _ = net_kernel_stop()

  Nil
}

@external(erlang, "erl_epmd", "names")
fn epmd_names(host: Dynamic) -> Dynamic

@external(erlang, "inet", "gethostname")
fn gethostname() -> Dynamic

/// The node names `epmd` on `host` has registered, or `Error` when `epmd`
/// cannot be asked. A node that is up and distributed is in this list; one
/// that is not running, or was started without distribution, is not.
///
/// ## Examples
///
/// ```gleam
/// registered_names("127.0.0.1")
/// // -> Ok(["app", "other"])
/// ```
pub fn registered_names(host: String) -> Result(List(String), Nil) {
  let reply = epmd_names(to_charlist(host))
  let names =
    decode.list(decode.field(
      0,
      decode.list(decode.int) |> decode.map(of_codes),
      decode.success,
    ))

  case decode.run(reply, decode.field(0, atom.decoder(), decode.success)) {
    Ok(tag) ->
      case atom.to_string(tag) {
        "ok" ->
          decode.run(reply, decode.field(1, names, decode.success))
          |> result.replace_error(Nil)
        _ -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
}

// Names are ASCII, so a code that is not a character is dropped.
fn of_codes(codes: List(Int)) -> String {
  codes
  |> list.filter_map(string.utf_codepoint)
  |> string.from_utf_codepoints
}

/// This machine's host name as the operating system reports it, which may be
/// a short name or a full one.
///
/// ## Examples
///
/// ```gleam
/// local_hostname()
/// // -> Ok("mybox")
/// ```
pub fn local_hostname() -> Result(String, Nil) {
  decode.run(
    gethostname(),
    decode.field(1, decode.list(decode.int), decode.success),
  )
  |> result.replace_error(Nil)
  |> result.map(of_codes)
}

@external(erlang, "rpc", "call")
fn rpc_call(
  node: Atom,
  module: Atom,
  function: Atom,
  args: List(Dynamic),
  timeout: Int,
) -> Dynamic

/// Call `module:function(args)` on a node and return the result, or an
/// `Error` describing why the call could not complete.
///
/// ## Examples
///
/// ```gleam
/// call(node, "erlang", "system_info", [to_dynamic(atom.create("otp_release"))], 5000)
/// ```
pub fn call(
  node: Atom,
  module: String,
  function: String,
  args: List(Dynamic),
  timeout: Int,
) -> Result(Dynamic, String) {
  let result =
    rpc_call(node, atom.create(module), atom.create(function), args, timeout)

  case decode.run(result, decode.field(0, atom.decoder(), decode.success)) {
    Ok(tag) ->
      case atom.to_string(tag) == "badrpc" {
        True -> Error(module <> ":" <> function <> " failed on the target")
        False -> Ok(result)
      }
    Error(_) -> Ok(result)
  }
}

@external(erlang, "erlang", "binary_to_list")
fn to_charlist(text: String) -> Dynamic

/// Load a module into a node from its compiled bytes. The file name is only
/// what the code server reports for the module.
pub fn load_binary(
  node: Atom,
  module: String,
  file_name: String,
  bytes: BitArray,
) -> Result(Nil, String) {
  use _ <- result_try(call(
    node,
    "code",
    "load_binary",
    [
      to_dynamic(atom.create(module)),
      to_charlist(file_name),
      to_dynamic(bytes),
    ],
    10_000,
  ))

  Ok(Nil)
}

fn result_try(
  result: Result(a, e),
  next: fn(a) -> Result(b, e),
) -> Result(b, e) {
  case result {
    Ok(value) -> next(value)
    Error(reason) -> Error(reason)
  }
}

/// A fresh reference.
@external(erlang, "erlang", "make_ref")
pub fn make_ref() -> Dynamic

@external(erlang, "erlang", "send")
fn erlang_send(destination: Dynamic, message: Dynamic) -> Dynamic

/// Send a message to the process registered as `name` on `node`. The agent
/// is addressed by its registered name so the viewer needs no pid for it.
pub fn send_named(node: Atom, name: String, message: Dynamic) -> Nil {
  let destination = to_dynamic(#(atom.create(name), node))
  let _ = erlang_send(destination, message)

  Nil
}

/// Milliseconds on the monotonic clock.
@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: Atom) -> Int

/// The monotonic clock in milliseconds, for measuring ages. It is negative
/// on some runtimes, so never use it as a wire value or a timestamp.
pub fn now_ms() -> Int {
  monotonic_time(atom.create("millisecond"))
}

/// The monotonic clock in nanoseconds, for timing a round trip. Like
/// `now_ms` it has no fixed origin and can be negative.
pub fn monotonic_ns() -> Int {
  monotonic_time(atom.create("nanosecond"))
}

@external(erlang, "erlang", "system_time")
fn system_time(unit: Atom) -> Int

/// Wall-clock milliseconds since the Unix epoch, for timestamps that appear
/// in captures and audit entries.
pub fn system_time_ms() -> Int {
  system_time(atom.create("millisecond"))
}

@external(erlang, "rand", "uniform")
fn uniform(upper: Int) -> Int

/// A random identifier of 16 hex digits, used as the boot id of one attach.
/// It is an identity, not a secret, so a non-cryptographic generator is
/// enough.
pub fn random_id() -> String {
  let high = int.to_base16(uniform(4_294_967_296))
  let low = int.to_base16(uniform(4_294_967_296))

  string.lowercase(
    string.pad_start(high, 8, "0") <> string.pad_start(low, 8, "0"),
  )
}

@external(erlang, "code", "priv_dir")
fn priv_dir(application: Atom) -> Dynamic

/// The `priv` directory of an application, if it is in the code path.
pub fn priv_directory(application: String) -> Result(String, Nil) {
  charlist_path(priv_dir(atom.create(application)))
}

@external(erlang, "unicode", "characters_to_binary")
fn characters_to_binary(chars: Dynamic) -> Dynamic

/// A charlist, which is a non-empty list of integers, as a string. `Error`
/// for anything else, such as the `{error, bad_name}` an OTP function
/// returns instead of a path.
pub fn text_of(chars: Dynamic) -> Result(String, Nil) {
  case decode.run(chars, decode.list(decode.int)) {
    Error(_) -> Error(Nil)
    Ok(codes) ->
      case list.is_empty(codes) {
        True -> Error(Nil)
        False ->
          decode.run(characters_to_binary(chars), decode.string)
          |> result_to_nil
      }
  }
}

// `code:priv_dir/1` returns a charlist.
fn charlist_path(chars: Dynamic) -> Result(String, Nil) {
  text_of(chars)
}

fn result_to_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}
