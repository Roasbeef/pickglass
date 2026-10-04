//// The viewer's end of the agent link: one process that owns the requests
//// in flight.
////
//// The agent monitors one process on the viewer, and that process is this
//// actor. Its death, or the death of the VM it runs in, is what the agent
//// reads as "the viewer is gone", so the actor lives exactly as long as the
//// attach. It sends every request in an envelope that names itself as the
//// reply address, matches each reply to its caller by the reference the
//// request carried, and sends a ping on a timer so the agent's lease is
//// renewed while the viewer is idle.
////
//// A caller that times out leaves its entry behind until the reply arrives
//// or the heartbeat prunes it; a late reply to a caller that stopped
//// waiting is dropped. Replies the actor cannot decode are dropped and
//// counted nowhere: the wire is the agent's, and a malformed term from it
//// is a bug to fix in `wire.gleam`, which its totality tests cover.
////
//// ## Flow
////
//// - `start` creates the actor addressed at one target node.
//// - `ask` sends a request and waits for its decoded reply.
//// - `handle` runs for each message: `Ask` records the caller and sends,
////   `Incoming` completes the matching caller, `Heartbeat` pings the agent
////   and prunes stale entries.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid, type Subject}
import pickglass/internal/ffi_dist
import pickglass_core/wire
import weft/actor

/// How often the actor pings the agent to renew its lease, in milliseconds.
const heartbeat_ms = 5000

/// How long an unanswered request is kept before the heartbeat drops it.
const stale_ms = 60_000

/// Why a request got no usable reply.
pub type AskError {
  /// No reply arrived within the caller's timeout.
  TimedOut
}

/// What the actor receives.
pub type Message {
  /// A caller's request, with where to send the decoded reply.
  Ask(request: wire.Request, caller: Subject(wire.Reply))

  /// A message that arrived from outside, expected to be an agent reply.
  Incoming(Dynamic)

  /// The lease-renewal timer fired.
  Heartbeat
}

/// A running link.
pub type Link {
  Link(subject: Subject(Message), pid: Pid)
}

type Pending {
  Pending(caller: Subject(wire.Reply), sent_ms: Int)
}

type State {
  State(target: Atom, own: Dynamic, pending: Dict(Dynamic, Pending))
}

/// Start the link actor, addressed at the agent on `target`. The actor is
/// linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(link) = link.start(node)
/// ```
pub fn start(target: Atom) -> Result(Link, String) {
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_other(Incoming)

      actor.initialised(State(
        target: target,
        own: ffi_dist.to_dynamic(process.self()),
        pending: dict.new(),
      ))
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.periodic(every: heartbeat_ms, sending: Heartbeat)

  case actor.start(builder) {
    Ok(started) -> Ok(Link(subject: started.data, pid: started.pid))
    Error(_) -> Error("the agent link did not start")
  }
}

/// Send a request and wait for its reply.
///
/// ## Examples
///
/// ```gleam
/// link.ask(link, wire.AskPing, 5000)
/// // -> Ok(wire.Pong(...))
/// ```
pub fn ask(
  link: Link,
  request: wire.Request,
  timeout_ms: Int,
) -> Result(wire.Reply, AskError) {
  let caller = process.new_subject()

  process.send(link.subject, Ask(request, caller))

  case process.receive(caller, timeout_ms) {
    Ok(reply) -> Ok(reply)
    Error(Nil) -> Error(TimedOut)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Ask(request, caller) -> actor.continue(send_request(state, request, caller))
    Incoming(term) -> actor.continue(complete(state, term))
    Heartbeat -> actor.continue(heartbeat(state))
  }
}

// The reference is the key a reply is matched on, so it is created here
// and never reused, and the envelope names this actor as the reply address.
fn send_request(
  state: State,
  request: wire.Request,
  caller: Subject(wire.Reply),
) -> State {
  let reference = ffi_dist.make_ref()

  ffi_dist.send_named(
    state.target,
    "pickglass_agent",
    wire.encode_request(state.own, reference, request),
  )

  State(
    ..state,
    pending: dict.insert(
      state.pending,
      reference,
      Pending(caller, ffi_dist.now_ms()),
    ),
  )
}

// A reply completes the caller that holds its reference. One that decodes
// to nothing, or matches no caller, is a late or foreign message and is
// dropped.
fn complete(state: State, term: Dynamic) -> State {
  case wire.decode_envelope(term) {
    Error(_) -> state
    Ok(wire.Envelope(reference, reply)) ->
      case dict.get(state.pending, reference) {
        Error(Nil) -> state
        Ok(pending) -> {
          process.send(pending.caller, reply)

          State(..state, pending: dict.delete(state.pending, reference))
        }
      }
  }
}

// The ping's reply matches no caller and is dropped; its purpose is that the
// agent hears from the viewer.
fn heartbeat(state: State) -> State {
  ffi_dist.send_named(
    state.target,
    "pickglass_agent",
    wire.encode_request(state.own, ffi_dist.make_ref(), wire.AskPing),
  )

  let now = ffi_dist.now_ms()

  State(
    ..state,
    pending: dict.filter(state.pending, fn(_, pending) {
      now - pending.sent_ms < stale_ms
    }),
  )
}
