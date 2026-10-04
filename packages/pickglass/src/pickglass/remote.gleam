//// The target as the viewer's other modules see it: a node name, an agent
//// boot id, and a way to ask the agent.
////
//// Everything above the link (the hub that polls, the executor that runs
//// authorized commands, the gate that checks pins against a boot id) needs
//// only these three things, so they take a `Remote` and not an
//// `attach.Session`. That keeps them testable against a function that plays
//// the agent, and it keeps the one real constructor, `of_session`, next to
//// the type it fills.
////
//// `ask` returns what the agent said as a value. A refusal carries its
//// code, because the executor reads `stale_pin` and `target_gone` as "this
//// pin is dead", and a deadline that passed with no reply is `TimedOut`.

import gleam/result
import pickglass/attach.{type Session}
import pickglass/link
import pickglass_core/identity.{type BootId}
import pickglass_core/wire

/// Why an ask got no usable answer.
pub type Failure {
  /// No reply arrived within the deadline.
  TimedOut

  /// The agent answered with a refusal. `code` is its closed code, such as
  /// `busy`, `stale_pin` or `no_such_probe`.
  Refusal(code: String, detail: String)
}

/// An attached target.
pub type Remote {
  Remote(
    /// The node's name.
    node: String,
    /// The boot id of the agent this attach started.
    boot: BootId,
    /// Send a request and wait at most the given milliseconds for the reply.
    ask: fn(wire.Request, Int) -> Result(wire.Reply, Failure),
    /// End the attach: the agent destroys what it holds and unloads.
    detach: fn() -> Nil,
  )
}

/// The remote for an attach.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(remote) = remote.of_session(session)
/// ```
pub fn of_session(session: Session) -> Result(Remote, String) {
  use boot <- result.try(
    identity.boot_id(session.boot_id)
    |> result.replace_error("the agent's boot id is not well formed"),
  )

  Ok(
    Remote(
      node: attach.node_name(session),
      boot:,
      ask: fn(request, timeout_ms) {
        case link.ask(session.link, request, timeout_ms) {
          Ok(wire.Refused(code, detail)) -> Error(Refusal(code:, detail:))
          Ok(reply) -> Ok(reply)
          Error(link.TimedOut) -> Error(TimedOut)
        }
      },
      detach: fn() {
        let _ = attach.detach(session)

        Nil
      },
    ),
  )
}

/// A readable description of a failure.
///
/// ## Examples
///
/// ```gleam
/// remote.describe(remote.TimedOut)
/// // -> "the agent did not answer in time"
/// ```
pub fn describe(failure: Failure) -> String {
  case failure {
    TimedOut -> "the agent did not answer in time"
    Refusal(code, detail) -> "the agent refused (" <> code <> "): " <> detail
  }
}

/// A remote for a viewer with no target: every ask is refused with the code
/// `no_target`, and detaching does nothing. The service uses it so a capture
/// being viewed runs the same code path as a live attach and an agent command
/// simply fails with a reason.
///
/// ## Examples
///
/// ```gleam
/// remote.none(boot).ask(wire.AskPing, 100)
/// // -> Error(Refusal("no_target", "no target is attached"))
/// ```
pub fn none(boot: BootId) -> Remote {
  Remote(
    node: "",
    boot:,
    ask: fn(_, _) { Error(Refusal("no_target", "no target is attached")) },
    detach: fn() { Nil },
  )
}
