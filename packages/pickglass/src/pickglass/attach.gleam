//// Attaching to a running node: join it, push the agent, start it, and talk
//// to it.
////
//// Pickglass is an independent program. It does not ask the target to embed
//// it. It joins the target's distribution as a hidden node that does not
//// listen, using the target's naming mode, reads the target's cookie from an
//// owner-only file, loads the
//// agent's modules into the target with `code:load_binary`, and starts the
//// agent as one registered process that monitors the viewer's link process.
//// From then on the target holds nothing the viewer did not put there, and
//// everything it holds is released if the viewer disappears.
////
//// Before pushing, the attach refuses a target older than OTP 28, because
//// trace sessions and the process iterator need it.
////
//// Any number of viewers may be attached to a node at once, and they share
//// one agent. The agent's modules have fixed names, so a second push would
//// reload code under a live agent, and the purge that follows kills the
//// processes still running the old code. A viewer therefore never pushes
//// over a running agent. It asks the agent to `join`, and the agent accepts
//// it only when the build it runs is the build this viewer carries, which
//// `agent_beams.identity` computes from the beams. A running agent of another
//// build is refused with both builds named, and nothing is replaced.
////
//// ## Flow
////
//// - `attach` runs the steps below in order and returns a `Session`, or an
////   `AttachError` whose `describe` is one line for the operator.
//// - `join` starts the viewer's node and connects. When the connection is
////   refused, `diagnose` asks the port mapper and tries the other naming mode to say
////   which of three causes it was, since OTP gives the same answer for all
////   of them.
//// - `check_release` refuses a target that is too old.
//// - `ensure_agent` attaches to the node by one of two routes. When an agent
////   is registered, `join_running` asks it to admit this viewer. When none is,
////   `start_fresh` takes the push claim, pushes every beam with `push`, and
////   `start_agent` starts the agent with the link process as its first
////   viewer. The claim is what lets two viewers attach to an empty node at
////   the same instant: one pushes, and the other waits and joins.
//// - `request` sends a request through the link, and `detach` ends this
////   viewer's attach. The agent unloads its modules when the last viewer
////   leaves, and `detach` waits for that only when it was the last.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import pickglass/agent_beams.{type Beam}
import pickglass/discover
import pickglass/endpoint.{type Endpoint, type Naming, LongNames, ShortNames}
import pickglass/internal/ffi_dist
import pickglass/link.{type Link}
import pickglass_core/identity
import pickglass_core/wire

/// The oldest OTP release the agent supports.
const minimum_otp = 28

/// How long the agent waits without hearing from the viewer before it tears
/// itself down, in milliseconds.
const lease_ms = 30_000

/// How long a join waits for the agent's answer, in milliseconds. A join that
/// goes unanswered means the agent stopped between the lookup and the join.
const join_timeout_ms = 5000

/// How many times an attach starts over because the agent on the node changed
/// under it: stopped while a join was in flight, or appeared while it was
/// starting one.
const attach_tries = 5

/// How long the push claim lives on the target if its holder dies, in
/// milliseconds. A claim is released as soon as the push finishes, so this
/// only bounds how long a viewer that died mid-push can block the others.
const claim_ttl_ms = 15_000

/// How many times a viewer polls for the push claim, 100 ms apart, before it
/// gives up. It covers one claim's whole life.
const claim_polls = 200

/// How many 50 ms turns a push waits for agent modules to leave the node
/// before it treats them as left by an agent that was killed.
const unload_patience = 20

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

  /// Other viewers are still attached, so the agent and its modules stay on
  /// the target until the last of them leaves.
  OtherViewersRemain(count: Int)

  /// The target could not be asked, so nothing is claimed either way.
  ModulesUnreadable
}

/// Why an attach failed. Each variant is a cause the operator can act on;
/// `describe` gives the one-line message.
pub type AttachError {
  /// The cookie file is missing, unreadable, or readable by others.
  CookieUnusable(path: String, reason: String)

  /// This VM could not start distribution.
  DistributionUnavailable(detail: String)

  /// `epmd` has no node of that name: it is not running, or was started
  /// without distribution.
  NodeNotRunning(node: String)

  /// The node is registered but refused the connection, and the other naming
  /// mode did not reach it either, so the cookie differs.
  CookieMismatch(node: String)

  /// The node is registered and answers in the other naming mode.
  NamingModeMismatch(node: String, given: Naming, reachable_as: String)

  /// The target's OTP release is older than the agent supports.
  OtpTooOld(release: Int, minimum: Int)

  /// An agent of another build is already running on the target, so this
  /// viewer cannot share it and does not replace it. `running` says which
  /// build the agent runs, in words that follow "it runs", and `own` is this
  /// viewer's build.
  AgentBuildMismatch(running: String, own: String)

  /// The agent on the target already serves as many viewers as it allows.
  TooManyViewers

  /// Any other failure, already in words.
  Failed(detail: String)
}

/// A one-line message for an operator. It never contains the cookie.
///
/// ## Examples
///
/// ```gleam
/// attach.describe(attach.NodeNotRunning("app@127.0.0.1"))
/// ```
pub fn describe(error: AttachError) -> String {
  case error {
    CookieUnusable(path, reason) -> "cookie file " <> path <> ": " <> reason
    DistributionUnavailable(detail) -> detail
    NodeNotRunning(node) ->
      node
      <> " is not running, or is not registered with epmd; check the name "
      <> "with `epmd -names` and that the node was started with -name or -sname"
    CookieMismatch(node) ->
      node
      <> " refused the connection: its cookie differs from the one in the "
      <> "cookie file"
    NamingModeMismatch(node, given, reachable_as) ->
      node
      <> " was treated as a "
      <> endpoint.domain(given)
      <> " node but is not; it answers as "
      <> reachable_as
      <> ", so pass that as --node"
    OtpTooOld(release, minimum) ->
      "the target runs OTP "
      <> int.to_string(release)
      <> "; pickglass needs OTP "
      <> int.to_string(minimum)
      <> " or newer"
    AgentBuildMismatch(running, own) ->
      "a pickglass agent of another build is already attached to this node "
      <> "(it runs "
      <> running
      <> "; this viewer carries build "
      <> own
      <> "), so it cannot be shared: detach the other viewers, or use the "
      <> "same pickglass build"
    TooManyViewers ->
      "the pickglass agent on this node already serves the most viewers it "
      <> "allows; detach one and try again"
    Failed(detail) -> detail
  }
}

/// Attach to a node, pushing the agent from `beams_directory` or from the
/// default location.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = attach.attach(target, Error(Nil))
/// ```
pub fn attach(
  target: Endpoint,
  beams_directory: Result(String, Nil),
) -> Result(Session, AttachError) {
  use cookie <- result.try(
    discover.read_cookie_file(target.cookie_file)
    |> result.map_error(fn(refused) {
      case refused {
        discover.CookieRefused(reason) ->
          CookieUnusable(target.cookie_file, reason)
        discover.NoTarget
        | discover.Ambiguous(_)
        | discover.StateUnreadable(_) ->
          CookieUnusable(target.cookie_file, "the cookie cannot be read")
      }
    }),
  )
  use beams <- result.try(
    agent_beams.load(beams_directory) |> result.map_error(Failed),
  )
  use node <- result.try(join(target, cookie))
  use _ <- result.try(check_release(node))
  use link <- result.try(link.start(node) |> result.map_error(Failed))

  let boot_id = "pg" <> ffi_dist.random_id()
  let plan =
    Plan(node:, link:, boot_id:, build: agent_beams.identity(beams), beams:)

  use _ <- result.try(ensure_agent(plan, attach_tries, claim_polls))

  let session = Session(node:, link:, boot_id:)

  use _ <- result.try(verify(session) |> result.map_error(Failed))

  Ok(session)
}

/// The target's operating-system process id, read over the connection. A
/// node named with `--node` has no process table entry to discover it from.
///
/// ## Examples
///
/// ```gleam
/// attach.os_pid(session)
/// // -> Ok(12345)
/// ```
pub fn os_pid(session: Session) -> Result(Int, String) {
  use chars <- result.try(ffi_dist.call(session.node, "os", "getpid", [], 5000))

  ffi_dist.text_of(chars)
  |> result.try(int.parse)
  |> result.replace_error("could not read the target's OS process id")
}

// The viewer's own node name is unique per attach, and the cookie is set for
// this one peer, so the target's cookie never becomes the viewer's own.
fn join(target: Endpoint, cookie: String) -> Result(Atom, AttachError) {
  use _ <- result.try(start_viewer(target.naming))

  let node = atom.create(endpoint.node_name(target))

  ffi_dist.set_cookie(node, atom.create(cookie))

  case ffi_dist.connect(node) {
    Ok(Nil) -> Ok(node)
    Error(Nil) -> Error(diagnose(target, cookie))
  }
}

// A short name is given without its host; a long name carries the loopback
// address, which is where the viewer lives.
fn start_viewer(naming: Naming) -> Result(Nil, AttachError) {
  let id = "pickglass_viewer_" <> ffi_dist.random_id()
  let name = case naming {
    LongNames -> id <> "@127.0.0.1"
    ShortNames -> id
  }

  ffi_dist.start_hidden_node(name, endpoint.domain(naming))
  |> result.map_error(DistributionUnavailable)
}

// OTP's `connect_node` answers `false` when the node is down, when the
// cookie differs and when the naming mode differs. `epmd` separates the
// first: a node it has not registered is not running. For the other two the
// viewer restarts its own distribution in the opposite mode and tries the
// same node name under that mode's host, which is the loopback address for
// a long name and this machine's short host name for a short name. A node
// reached that way is a naming mismatch; one that is not is a cookie
// mismatch.
fn diagnose(target: Endpoint, cookie: String) -> AttachError {
  let node = endpoint.node_name(target)

  case ffi_dist.registered_names(target.host) {
    Ok(names) ->
      case list.contains(names, target.name) {
        True -> probe_other_mode(target, cookie)
        False -> NodeNotRunning(node)
      }
    Error(Nil) -> NodeNotRunning(node)
  }
}

fn probe_other_mode(target: Endpoint, cookie: String) -> AttachError {
  let node = endpoint.node_name(target)
  let other = case target.naming {
    LongNames -> ShortNames
    ShortNames -> LongNames
  }

  ffi_dist.stop_distribution()

  let reached = {
    use _ <- result.try(start_viewer(other) |> result.replace_error(Nil))
    use host <- result.try(other_host(other))

    let candidate = target.name <> "@" <> host
    let peer = atom.create(candidate)

    ffi_dist.set_cookie(peer, atom.create(cookie))
    use _ <- result.map(ffi_dist.connect(peer))

    candidate
  }

  case reached {
    Ok(candidate) -> NamingModeMismatch(node, target.naming, candidate)
    Error(Nil) -> CookieMismatch(node)
  }
}

fn other_host(naming: Naming) -> Result(String, Nil) {
  case naming {
    LongNames -> Ok("127.0.0.1")
    ShortNames ->
      ffi_dist.local_hostname()
      |> result.map(fn(name) {
        case string.split_once(name, ".") {
          Ok(#(label, _)) -> label
          Error(Nil) -> name
        }
      })
  }
}

fn check_release(node: Atom) -> Result(Nil, AttachError) {
  use release <- result.try(otp_release(node) |> result.map_error(Failed))

  case release >= minimum_otp {
    False -> Error(OtpTooOld(release, minimum_otp))
    True -> Ok(Nil)
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

/// What an attach carries from step to step: where it is going, the link the
/// agent will answer to, the boot id this viewer's pin tokens will carry, and
/// the beams with the build they make.
type Plan {
  Plan(
    node: Atom,
    link: Link,
    boot_id: String,
    build: String,
    beams: List(Beam),
  )
}

// A registered agent is joined and never pushed over. The agent can stop
// between the lookup and the join, and another viewer can start one between
// the lookup and the claim, so each route that finds the other's situation
// starts over, a bounded number of times, instead of assuming what it saw.
fn ensure_agent(
  plan: Plan,
  tries: Int,
  polls: Int,
) -> Result(Nil, AttachError) {
  case tries <= 0 {
    True ->
      Error(Failed(
        "the agent on this node kept changing while attaching; try again",
      ))
    False -> {
      use running <- result.try(agent_running(plan.node))

      case running {
        True -> join_running(plan, tries, polls)
        False -> start_fresh(plan, tries, polls)
      }
    }
  }
}

fn agent_running(node: Atom) -> Result(Bool, AttachError) {
  use running <- result.try(
    ffi_dist.call(
      node,
      "erlang",
      "whereis",
      [ffi_dist.to_dynamic(atom.create("pickglass_agent"))],
      5000,
    )
    |> result.map_error(Failed),
  )

  Ok(
    decode.run(running, decode.dynamic)
    != Ok(ffi_dist.to_dynamic(atom.create("undefined"))),
  )
}

// The agent decides in its own mailbox order, with the viewers it holds. A
// join it handles before the last viewer's detach is counted, and the agent
// stays; one it handles after finds an agent that is stopping and is never
// answered. That silence is the signal to wait for the old modules to leave
// and start over, which then finds no agent and pushes a fresh one. A join
// that was answered late and is asked again is `already_attached`, which is
// success.
fn join_running(
  plan: Plan,
  tries: Int,
  polls: Int,
) -> Result(Nil, AttachError) {
  let join_request =
    wire.Extended(wire.AskJoin(plan.boot_id, lease_ms, plan.build))

  case link.ask(plan.link, join_request, join_timeout_ms) {
    Ok(wire.Joined(_)) -> Ok(Nil)
    Ok(wire.Refused("already_attached", _)) -> Ok(Nil)
    Ok(wire.Refused("build_mismatch", running)) ->
      Error(AgentBuildMismatch("build " <> running, plan.build))
    Ok(wire.Refused("bad_request", _)) ->
      Error(AgentBuildMismatch(
        "an older build that cannot be shared",
        plan.build,
      ))
    Ok(wire.Refused("too_many_viewers", _)) -> Error(TooManyViewers)
    Ok(wire.Refused(code, detail)) ->
      Error(Failed("the agent refused (" <> code <> "): " <> detail))
    Ok(_) -> Error(Failed("the agent answered a join with something else"))
    Error(link.TimedOut) -> {
      let _ = wait_for_unload(plan.node, unload_patience)

      ensure_agent(plan, tries - 1, polls)
    }
  }
}

// With no agent registered, one viewer pushes and the rest wait. The claim is
// a registered name on a process the target sleeps in for a bounded time, so
// registering it is atomic and a holder that dies releases it by expiry. The
// winner looks again once it holds the claim, because another viewer may have
// finished between the first lookup and the claim.
fn start_fresh(plan: Plan, tries: Int, polls: Int) -> Result(Nil, AttachError) {
  case claim_push(plan.node) {
    Error(Nil) ->
      case polls <= 0 {
        True ->
          Error(Failed(
            "another pickglass viewer has held this node's attach claim for "
            <> "too long; try again",
          ))
        False -> {
          process.sleep(100)

          ensure_agent(plan, tries, polls - 1)
        }
      }
    Ok(claim) -> {
      let outcome = push_and_start(plan)

      release_claim(claim)

      case outcome {
        Ok(Started) -> Ok(Nil)
        Ok(AgentAppeared) -> ensure_agent(plan, tries - 1, polls)
        Error(error) -> Error(error)
      }
    }
  }
}

type Pushed {
  /// This viewer pushed the agent and started it.
  Started

  /// An agent was registered by the time the push began, or while it ran.
  AgentAppeared
}

fn push_and_start(plan: Plan) -> Result(Pushed, AttachError) {
  use running <- result.try(agent_running(plan.node))

  case running {
    True -> Ok(AgentAppeared)
    False -> {
      use _ <- result.try(clear_leftover_modules(plan.node))
      use _ <- result.try(
        push(plan.node, plan.beams) |> result.map_error(Failed),
      )
      use started <- result.try(
        start_agent(plan.node, plan.link, plan.boot_id, plan.build)
        |> result.map_error(Failed),
      )

      case started {
        AgentStarted -> Ok(Started)
        AgentExisted -> Ok(AgentAppeared)
      }
    }
  }
}

/// A claim on the right to push the agent into a node. `holder` is the
/// process on the target that carries the registered name.
type Claim {
  Claim(node: Atom, holder: Dynamic)
}

fn claim_push(node: Atom) -> Result(Claim, Nil) {
  use holder <- result.try(
    ffi_dist.call(
      node,
      "erlang",
      "spawn",
      [
        ffi_dist.to_dynamic(atom.create("timer")),
        ffi_dist.to_dynamic(atom.create("sleep")),
        ffi_dist.to_dynamic([claim_ttl_ms]),
      ],
      5000,
    )
    |> result.replace_error(Nil),
  )

  case
    ffi_dist.call(
      node,
      "erlang",
      "register",
      [ffi_dist.to_dynamic(atom.create("pickglass_agent_claim")), holder],
      5000,
    )
  {
    Ok(_) -> Ok(Claim(node:, holder:))
    Error(_) -> {
      release_claim(Claim(node:, holder:))

      Error(Nil)
    }
  }
}

fn release_claim(claim: Claim) -> Nil {
  let _ =
    ffi_dist.call(
      claim.node,
      "erlang",
      "exit",
      [claim.holder, ffi_dist.to_dynamic(atom.create("kill"))],
      5000,
    )

  Nil
}

// Agent modules with no registered agent are either an agent that stopped a
// moment ago, whose janitor is still unloading them, or what a killed agent
// leaves behind. The janitor finishes in milliseconds, so the push waits a
// bounded time for the modules to go and treats what remains as left over:
// pushing while the janitor runs would let it delete the modules just loaded.
fn clear_leftover_modules(node: Atom) -> Result(Nil, AttachError) {
  case wait_for_unload(node, unload_patience) {
    ModulesUnreadable ->
      Error(Failed("the target could not be asked which modules are loaded"))
    ModulesUnloaded | ModulesRemain(_) | OtherViewersRemain(_) -> {
      use modules <- result.try(
        loaded_agent_modules(node) |> result.map_error(Failed),
      )

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

type Start {
  AgentStarted
  AgentExisted
}

// The link process is the first viewer the agent monitors, so it is what the
// start arguments name. `{error, {already_started, Pid}}` is not a failure
// here: the claim should have made it impossible, so it can only mean a
// viewer that does not take the claim registered an agent first, and the
// attach starts over and joins it.
fn start_agent(
  node: Atom,
  link: Link,
  boot_id: String,
  build: String,
) -> Result(Start, String) {
  let arguments = ffi_dist.to_dynamic(#(link.pid, boot_id, lease_ms, build))

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
        "ok" -> Ok(AgentStarted)
        _ ->
          case already_started(started) {
            True -> Ok(AgentExisted)
            False ->
              Error("the agent did not start: " <> string.inspect(started))
          }
      }
    Error(_) -> Error("the agent did not start")
  }
}

fn already_started(started: Dynamic) -> Bool {
  case decode.run(started, decode.at([1, 0], atom.decoder())) {
    Ok(reason) -> atom.to_string(reason) == "already_started"
    Error(_) -> False
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

/// End this viewer's attach. The agent destroys every session this viewer
/// holds and releases its pins and its claim on the accounting flag. When
/// other viewers are still attached the agent stays, and the answer says how
/// many. When this was the last viewer the agent exits, and this waits briefly
/// for its modules to be unloaded and reports whether they were.
///
/// ## Examples
///
/// ```gleam
/// attach.detach(session)
/// // -> ModulesUnloaded
/// ```
pub fn detach(session: Session) -> Unload {
  case request(session, wire.AskDetach) {
    Ok(wire.Left(remaining)) -> OtherViewersRemain(remaining)
    Ok(_) | Error(_) -> wait_for_unload(session.node, 40)
  }
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
