//// Attaching to a running node: join it, push the agent, start it, and talk
//// to it.
////
//// Pickglass is an independent program. It does not ask the target to embed
//// it. It joins the target's distribution as a hidden node that does not
//// listen, reads the target's cookie from an owner-only file, loads the
//// agent's modules into the target with `code:load_binary`, and starts the
//// agent as one registered process that monitors the viewer's link process.
//// From then on the target holds nothing the viewer did not put there, and
//// everything it holds is released if the viewer disappears.
////
//// Before pushing, the attach refuses a target older than OTP 28, because
//// trace sessions and the process iterator need it, refuses a target that
//// already has a pickglass agent running, and unloads agent modules left by
//// an agent that was killed outright.
////
//// ## Flow
////
//// - `attach` runs the steps below in order and returns a `Session`.
//// - `prepare_target` checks the release and clears a stale agent.
//// - `push` loads every beam, and `start_agent` starts the agent with the
////   link process as its monitored viewer.
//// - `request` sends a request through the link, and `detach` ends the
////   attach and waits for the agent's modules to be unloaded.

import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pickglass/agent_beams.{type Beam}
import pickglass/discover.{type Target}
import pickglass/internal/ffi_dist
import pickglass/link.{type Link}
import pickglass_core/identity
import pickglass_core/wire

/// The oldest OTP release the agent supports.
const minimum_otp = 28

/// How long the agent waits without hearing from the viewer before it tears
/// itself down, in milliseconds.
const lease_ms = 30_000

/// An attach to one node.
pub type Session {
  Session(node: Atom, link: Link, boot_id: String)
}

/// The target node's name.
///
/// ## Examples
///
/// ```gleam
/// attach.node_name(session)
/// // -> "loom_daemon_profile_1_ab@127.0.0.1"
/// ```
pub fn node_name(session: Session) -> String {
  atom.to_string(session.node)
}

/// Whether the agent's modules were gone from the target when `detach`
/// finished waiting.
pub type Unload {
  ModulesUnloaded
  ModulesRemain(count: Int)

  /// The target could not be asked, so nothing is claimed either way.
  ModulesUnreadable
}

/// Attach to a discovered target, pushing the agent from `beams_directory`
/// or from the default location.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = attach.attach(target, Error(Nil))
/// ```
pub fn attach(
  target: Target,
  beams_directory: Result(String, Nil),
) -> Result(Session, String) {
  use cookie <- result.try(
    discover.read_cookie(target.home)
    |> result.map_error(fn(_) { "the target's cookie file was refused" }),
  )
  use beams <- result.try(agent_beams.load(beams_directory))
  use node <- result.try(join(target, cookie))
  use _ <- result.try(prepare_target(node))
  use _ <- result.try(push(node, beams))
  use link <- result.try(link.start(node))
  use boot_id <- result.try(start_agent(node, link))
  let session = Session(node:, link:, boot_id:)

  use _ <- result.try(verify(session))

  Ok(session)
}

// The viewer's own node name is unique per attach, and the cookie is set for
// this one peer, so the target's cookie never becomes the viewer's own.
fn join(target: Target, cookie: String) -> Result(Atom, String) {
  use _ <- result.try(ffi_dist.start_hidden_node(
    "pickglass_viewer_" <> ffi_dist.random_id() <> "@127.0.0.1",
  ))

  let node = atom.create(target.node)

  ffi_dist.set_cookie(node, atom.create(cookie))
  use _ <- result.try(ffi_dist.connect(node))

  Ok(node)
}

fn prepare_target(node: Atom) -> Result(Nil, String) {
  use release <- result.try(otp_release(node))

  case release >= minimum_otp {
    False ->
      Error(
        "the target runs OTP "
        <> int.to_string(release)
        <> "; pickglass needs OTP "
        <> int.to_string(minimum_otp)
        <> " or newer",
      )
    True -> clear_stale_agent(node)
  }
}

fn otp_release(node: Atom) -> Result(Int, String) {
  use chars <- result.try(ffi_dist.call(
    node,
    "erlang",
    "system_info",
    [ffi_dist.to_dynamic(atom.create("otp_release"))],
    5000,
  ))

  ffi_dist.text_of(chars)
  |> result.try(int.parse)
  |> result.replace_error("could not read the target's OTP release")
}

// A registered agent means another viewer is attached. Agent modules with
// no registered agent are what a killed agent leaves behind, and are
// unloaded before the new push.
fn clear_stale_agent(node: Atom) -> Result(Nil, String) {
  use running <- result.try(ffi_dist.call(
    node,
    "erlang",
    "whereis",
    [ffi_dist.to_dynamic(atom.create("pickglass_agent"))],
    5000,
  ))

  case
    decode.run(running, decode.dynamic)
    == Ok(ffi_dist.to_dynamic(atom.create("undefined")))
  {
    False -> Error("another pickglass agent is already attached to this node")
    True -> {
      use modules <- result.try(loaded_agent_modules(node))

      list.each(modules, fn(module) { unload(node, module) })

      Ok(Nil)
    }
  }
}

/// The agent modules currently loaded on a node.
pub fn loaded_agent_modules(node: Atom) -> Result(List(String), String) {
  use loaded <- result.try(ffi_dist.call(node, "code", "all_loaded", [], 10_000))
  use entries <- result.try(
    decode.run(
      loaded,
      decode.list(decode.field(0, atom.decoder(), decode.success)),
    )
    |> result.replace_error("unexpected answer from code:all_loaded"),
  )

  Ok(
    entries
    |> list.map(atom.to_string)
    |> list.filter(fn(name) { string.starts_with(name, "pickglass_agent@") }),
  )
}

fn unload(node: Atom, module: String) -> Nil {
  let argument = [ffi_dist.to_dynamic(atom.create(module))]
  let _ = ffi_dist.call(node, "code", "purge", argument, 5000)
  let _ = ffi_dist.call(node, "code", "delete", argument, 5000)
  let _ = ffi_dist.call(node, "code", "purge", argument, 5000)

  Nil
}

fn push(node: Atom, beams: List(Beam)) -> Result(Nil, String) {
  list.try_each(beams, fn(beam) {
    ffi_dist.load_binary(node, beam.module, beam.file_name, beam.bytes)
  })
}

// The link process is the viewer the agent monitors, so it is what the
// start arguments name.
fn start_agent(node: Atom, link: Link) -> Result(String, String) {
  let boot_id = "pg" <> ffi_dist.random_id()
  let arguments = ffi_dist.to_dynamic(#(link.pid, boot_id, lease_ms))

  use started <- result.try(ffi_dist.call(
    node,
    "pickglass_agent@server",
    "start",
    [arguments],
    10_000,
  ))

  case decode.run(started, decode.field(0, atom.decoder(), decode.success)) {
    Ok(tag) ->
      case atom.to_string(tag) {
        "ok" -> Ok(boot_id)
        _ -> Error("the agent did not start: " <> string.inspect(started))
      }
    Error(_) -> Error("the agent did not start")
  }
}

// The first ping proves the agent is registered, answering, and the one
// this attach started: its boot id is the one the viewer generated.
fn verify(session: Session) -> Result(Nil, String) {
  case request(session, wire.AskPing) {
    Ok(wire.Pong(pong)) ->
      case identity.boot_id_text(pong.boot_id) == session.boot_id {
        True -> Ok(Nil)
        False -> Error("the agent that answered is not the one just started")
      }
    Ok(_) -> Error("the agent answered a ping with something else")
    Error(message) -> Error(message)
  }
}

/// Send a request to the agent and wait for its reply.
///
/// ## Examples
///
/// ```gleam
/// attach.request(session, wire.AskMemory)
/// // -> Ok(wire.MemoryReport(...))
/// ```
pub fn request(
  session: Session,
  request: wire.Request,
) -> Result(wire.Reply, String) {
  case link.ask(session.link, request, 15_000) {
    Ok(wire.Refused(code, detail)) ->
      Error("the agent refused (" <> code <> "): " <> detail)
    Ok(reply) -> Ok(reply)
    Error(link.TimedOut) -> Error("the agent did not answer in time")
  }
}

/// End the attach. The agent destroys every session it holds, releases every
/// flag, and exits; this waits briefly for its modules to be unloaded and
/// reports whether they were.
///
/// ## Examples
///
/// ```gleam
/// attach.detach(session)
/// // -> ModulesUnloaded
/// ```
pub fn detach(session: Session) -> Unload {
  let _ = request(session, wire.AskDetach)

  wait_for_unload(session.node, 40)
}

fn wait_for_unload(node: Atom, tries: Int) -> Unload {
  case loaded_agent_modules(node) {
    Ok([]) -> ModulesUnloaded
    Ok(remaining) ->
      case tries > 0 {
        True -> {
          process.sleep(50)

          wait_for_unload(node, tries - 1)
        }
        False -> ModulesRemain(list.length(remaining))
      }
    Error(_) -> ModulesUnreadable
  }
}
