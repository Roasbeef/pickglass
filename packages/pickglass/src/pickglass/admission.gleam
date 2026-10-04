//// The admission actor: the one process that holds the ticket registry.
////
//// Every request to the host asks the same questions of the same secrets
//// (is this ticket live, which session does this cookie name, was this
//// nonce handed to a page), and two requests must never both redeem one
//// ticket. A single actor serializes those decisions. The decisions
//// themselves are `ticket`'s pure functions; this module generates the
//// random secrets, reads the clock, and keeps the registry between
//// messages.
////
//// Secrets are 32 bytes from the operating system's random source, encoded
//// as URL-safe base64 without padding, so a secret can sit in a URL path or
//// a cookie value without escaping.
////
//// ## Flow
////
//// - `start` creates the actor with a clock.
//// - `issue_ticket` mints the ticket `pickglass open` prints.
//// - `redeem` turns a ticket into a cookie.
//// - `begin_page` finds the session for a page request and mints its nonce.
//// - `admit_socket` checks the cookie and the nonce of an upgrade.

import gleam/erlang/process.{type Subject}
import gleam/result
import gleam/string
import pickglass/secret
import pickglass/ticket.{type Session, type SessionRefusal, type TicketRefusal}
import pickglass_core/policy.{type Capability, PrincipalId}
import weft/actor

/// A handle to the admission actor.
pub type Admission {
  Admission(subject: Subject(Message))
}

/// What a successful exchange returns: the cookie value to set and the new
/// session.
pub type Redeemed {
  Redeemed(cookie: String, session: Session)
}

/// Why a WebSocket upgrade was refused.
pub type SocketRefusal {
  /// The cookie named no session.
  NoSession(SessionRefusal)

  /// The `csrf-token` was missing or was not handed to a page load of the
  /// session.
  BadNonce
}

/// What the actor receives.
pub opaque type Message {
  Issue(grants: List(Capability), reply: Subject(Result(String, Nil)))
  Redeem(ticket: String, reply: Subject(Result(Redeemed, TicketRefusal)))
  BeginPage(
    cookies: List(String),
    reply: Subject(Result(#(Session, String), SessionRefusal)),
  )
  AdmitSocket(
    cookies: List(String),
    nonce: String,
    reply: Subject(Result(Session, SocketRefusal)),
  )
  CheckSession(
    cookies: List(String),
    reply: Subject(Result(Session, SessionRefusal)),
  )
}

type State {
  State(registry: ticket.Registry, clock: fn() -> Int)
}

/// Start the actor. `clock` returns milliseconds and is read once per
/// message.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(admission) = admission.start(ffi_dist.system_time_ms)
/// ```
pub fn start(clock: fn() -> Int) -> Result(Admission, String) {
  let builder =
    actor.new(State(ticket.new(), clock))
    |> actor.on_message(handle)

  case actor.start(builder) {
    Ok(started) -> Ok(Admission(subject: started.data))
    Error(_) -> Error("the admission actor did not start")
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let now = state.clock()

  case message {
    Issue(grants, reply) -> {
      let secret = secret()

      case ticket.issue(state.registry, secret, grants, now) {
        Ok(registry) -> {
          process.send(reply, Ok(secret))

          actor.continue(State(..state, registry:))
        }
        Error(Nil) -> {
          process.send(reply, Error(Nil))

          actor.continue(state)
        }
      }
    }

    Redeem(presented, reply) -> {
      let cookie = secret()
      let principal = PrincipalId("p-" <> string.slice(secret(), 0, 8))
      let #(registry, outcome) =
        ticket.redeem(state.registry, presented, cookie, principal, now)

      process.send(
        reply,
        result.map(outcome, fn(session) { Redeemed(cookie:, session:) }),
      )

      actor.continue(State(..state, registry:))
    }

    CheckSession(cookies, reply) -> {
      process.send(
        reply,
        ticket.session_for(state.registry, cookies, now)
          |> result.map(fn(found) { found.1 }),
      )

      actor.continue(state)
    }

    BeginPage(cookies, reply) -> {
      case ticket.session_for(state.registry, cookies, now) {
        Error(refusal) -> {
          process.send(reply, Error(refusal))

          actor.continue(state)
        }
        Ok(#(cookie_digest, session)) -> {
          let nonce = secret()

          process.send(reply, Ok(#(session, nonce)))

          actor.continue(
            State(
              ..state,
              registry: ticket.add_nonce(state.registry, cookie_digest, nonce),
            ),
          )
        }
      }
    }

    AdmitSocket(cookies, nonce, reply) -> {
      let admitted = case ticket.session_for(state.registry, cookies, now) {
        Error(refusal) -> Error(NoSession(refusal))
        Ok(#(_, session)) ->
          case ticket.has_nonce(session, nonce) {
            True -> Ok(session)
            False -> Error(BadNonce)
          }
      }

      process.send(reply, admitted)

      actor.continue(state)
    }
  }
}

// A secret is 32 random bytes, URL-safe, unpadded.
fn secret() -> String {
  secret.token(32)
}

/// Mint a ticket for the grants. `Error` when too many tickets are
/// outstanding.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(ticket) = admission.issue_ticket(admission, grants)
/// ```
pub fn issue_ticket(
  admission: Admission,
  grants: List(Capability),
) -> Result(String, Nil) {
  process.call(admission.subject, 5000, fn(reply) { Issue(grants, reply) })
}

/// Exchange a presented ticket for a session.
///
/// ## Examples
///
/// ```gleam
/// admission.redeem(admission, presented)
/// ```
pub fn redeem(
  admission: Admission,
  presented: String,
) -> Result(Redeemed, TicketRefusal) {
  process.call(admission.subject, 5000, fn(reply) { Redeem(presented, reply) })
}

/// Find the session a page request's cookies name, and mint the
/// nonce for this page load.
///
/// ## Examples
///
/// ```gleam
/// admission.begin_page(admission, cookies)
/// ```
pub fn begin_page(
  admission: Admission,
  cookies: List(String),
) -> Result(#(Session, String), SessionRefusal) {
  process.call(admission.subject, 5000, fn(reply) { BeginPage(cookies, reply) })
}

/// Check that a cookie names a live session, without starting a page. The
/// download route uses it: a download is a request with the session cookie
/// and no page behind it.
///
/// ## Examples
///
/// ```gleam
/// admission.check_session(admission, cookies)
/// ```
pub fn check_session(
  admission: Admission,
  cookies: List(String),
) -> Result(Session, SessionRefusal) {
  process.call(admission.subject, 5000, fn(reply) {
    CheckSession(cookies, reply)
  })
}

/// Check a WebSocket upgrade: the cookie must name a session
/// and `nonce` must have been handed to one of its page loads.
///
/// ## Examples
///
/// ```gleam
/// admission.admit_socket(admission, cookies, nonce)
/// ```
pub fn admit_socket(
  admission: Admission,
  cookies: List(String),
  nonce: String,
) -> Result(Session, SocketRefusal) {
  process.call(admission.subject, 5000, fn(reply) {
    AdmitSocket(cookies, nonce, reply)
  })
}
