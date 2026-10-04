//// Tickets, sessions and page nonces: who may reach the viewer's pages.
////
//// The viewer's HTTP host is on loopback, and every other page the same
//// browser loads can send requests to loopback. What keeps them out is a
//// chain of secrets, each worth less than the one before it and each
//// consumed or scoped so that a leak of one does not open the next:
////
//// 1. A **ticket** is printed once by `pickglass open` in a URL. It is valid
////    for one exchange and for `ticket_ttl_ms`. The exchange removes it
////    whether or not it succeeds, so a second use of the same URL always
////    fails.
//// 2. A successful exchange makes a **session**: a cookie value, a principal
////    id and the grants the ticket carried. The cookie is `HttpOnly` and
////    `SameSite=Strict`. Browsers do not scope cookies by port, so another
////    service on loopback may receive it; the page nonce below, the `Host`
////    check and `Sec-Fetch-Site` are what keep such a service from using it.
//// 3. Each page load receives a **nonce**, which is both the page's CSP
////    nonce and the `csrf-token` the WebSocket upgrade must present. A page
////    on another origin cannot read it.
////
//// The registry stores only SHA-256 digests of the three secrets, so a dump
//// of the viewer's memory does not hand out a usable cookie, and a lookup
//// by digest has no timing difference to measure. It is a pure value: the
//// caller generates the random secrets and passes them in, which lets tests
//// choose them. `admission` wraps it in an actor.
////
//// The principal's grants are fixed here, at the exchange, and are never
//// read from a request afterwards.
////
//// ## Flow
////
//// - `issue` records a ticket for printing.
//// - `redeem` exchanges it for a session.
//// - `session_for` finds the session a request's cookies name.
//// - `add_nonce` and `has_nonce` bind a page load to its socket.

import gleam/bit_array
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/set.{type Set}
import pickglass_core/policy.{type Capability, type PrincipalId}

/// How long a printed ticket stays redeemable, in milliseconds.
pub const ticket_ttl_ms = 120_000

/// How long a session lasts, in milliseconds.
pub const session_ttl_ms = 43_200_000

/// The most unredeemed tickets held at once.
pub const max_tickets = 16

/// The most live sessions held at once.
pub const max_sessions = 16

/// The most page nonces a session keeps. A reload adds one and the oldest
/// is dropped.
pub const max_nonces = 8

/// The most cookie values a request is searched for. A browser sends one
/// per cookie whose path covers the request; the bound keeps a request
/// stuffed with planted values from costing a lookup each.
pub const max_cookies = 4

type Issued {
  Issued(grants: Set(Capability), expires_ms: Int)
}

/// One live session.
pub type Session {
  Session(
    /// The principal every command from this session is made as.
    principal: PrincipalId,
    /// The grants the ticket carried.
    grants: Set(Capability),
    expires_ms: Int,
    /// Digests of the nonces handed to page loads, newest first.
    nonces: List(String),
  )
}

/// The registry: unredeemed tickets and live sessions, both by digest.
pub opaque type Registry {
  Registry(tickets: Dict(String, Issued), sessions: Dict(String, Session))
}

/// Why a ticket was refused.
pub type TicketRefusal {
  /// No such ticket: never issued, already redeemed, or swept.
  UnknownTicket

  /// The ticket was past its lifetime. It is removed all the same.
  ExpiredTicket

  /// The registry holds `max_sessions` live sessions.
  TooManySessions
}

/// Why a request's cookies named no session.
pub type SessionRefusal {
  /// The request carried no cookie of the viewer's.
  NoCookie

  /// None of the cookie values names a live session.
  NoSuchSession
}

/// An empty registry.
pub fn new() -> Registry {
  Registry(tickets: dict.new(), sessions: dict.new())
}

/// The digest of a secret, as lowercase hex. The registry keys everything by
/// it.
///
/// ## Examples
///
/// ```gleam
/// ticket.digest("abc") == ticket.digest("abc")
/// ```
pub fn digest(secret: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(secret))
  |> bit_array.base16_encode
}

/// Record a ticket valid until `ticket_ttl_ms` after `now_ms`. Expired
/// tickets are swept first, and when `max_tickets` live ones remain the new
/// one is not recorded, which is `Error`: the operator asked for too many
/// URLs.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(registry) = ticket.issue(ticket.new(), "secret", grants, 0)
/// ```
pub fn issue(
  registry: Registry,
  secret: String,
  grants: List(Capability),
  now_ms: Int,
) -> Result(Registry, Nil) {
  let live =
    dict.filter(registry.tickets, fn(_, held) { held.expires_ms > now_ms })

  case dict.size(live) >= max_tickets {
    True -> Error(Nil)
    False ->
      Ok(
        Registry(
          ..registry,
          tickets: dict.insert(
            live,
            digest(secret),
            Issued(set.from_list(grants), now_ms + ticket_ttl_ms),
          ),
        ),
      )
  }
}

/// Exchange a ticket for a session. `cookie` is a fresh secret the caller
/// generated, and `principal` is the new session's id.
///
/// The ticket is removed from the registry on every outcome, so a ticket
/// can be used once whatever the first use did.
///
/// ## Examples
///
/// ```gleam
/// let #(registry, outcome) =
///   ticket.redeem(registry, "secret", "cookie", principal, now)
/// ```
pub fn redeem(
  registry: Registry,
  secret: String,
  cookie: String,
  principal: PrincipalId,
  now_ms: Int,
) -> #(Registry, Result(Session, TicketRefusal)) {
  let hashed = digest(secret)
  let without =
    Registry(..registry, tickets: dict.delete(registry.tickets, hashed))
  let live_sessions =
    dict.filter(without.sessions, fn(_, session) { session.expires_ms > now_ms })
  let swept = Registry(..without, sessions: live_sessions)

  case dict.get(registry.tickets, hashed) {
    Error(Nil) -> #(swept, Error(UnknownTicket))
    Ok(held) ->
      case held.expires_ms > now_ms, dict.size(live_sessions) >= max_sessions {
        False, _ -> #(swept, Error(ExpiredTicket))
        True, True -> #(swept, Error(TooManySessions))
        True, False -> {
          let session =
            Session(
              principal:,
              grants: held.grants,
              expires_ms: now_ms + session_ttl_ms,
              nonces: [],
            )

          #(
            Registry(
              ..swept,
              sessions: dict.insert(swept.sessions, digest(cookie), session),
            ),
            Ok(session),
          )
        }
      }
  }
}

/// The session a request's cookie values name. The first value that names a
/// live session wins. At most `max_cookies` values are tried. The result
/// carries the digest of the matching cookie, which `add_nonce` takes.
///
/// ## Examples
///
/// ```gleam
/// ticket.session_for(registry, ["cookie"], now)
/// ```
pub fn session_for(
  registry: Registry,
  cookies: List(String),
  now_ms: Int,
) -> Result(#(String, Session), SessionRefusal) {
  case cookies {
    [] -> Error(NoCookie)
    _ ->
      cookies
      |> list.take(max_cookies)
      |> list.find_map(fn(cookie) {
        let hashed = digest(cookie)

        case dict.get(registry.sessions, hashed) {
          Ok(session) if session.expires_ms > now_ms -> Ok(#(hashed, session))
          Ok(_) | Error(Nil) -> Error(Nil)
        }
      })
      |> result.replace_error(NoSuchSession)
  }
}

/// Record a page nonce on the session whose cookie digest is `cookie_digest`,
/// keeping the newest `max_nonces`. A digest naming no session changes
/// nothing.
pub fn add_nonce(
  registry: Registry,
  cookie_digest: String,
  nonce: String,
) -> Registry {
  case dict.get(registry.sessions, cookie_digest) {
    Error(Nil) -> registry
    Ok(session) ->
      Registry(
        ..registry,
        sessions: dict.insert(
          registry.sessions,
          cookie_digest,
          Session(..session, nonces: [
            digest(nonce),
            ..list.take(session.nonces, max_nonces - 1)
          ]),
        ),
      )
  }
}

/// Whether a presented nonce was handed to a page load of this session.
///
/// ## Examples
///
/// ```gleam
/// ticket.has_nonce(session, presented)
/// ```
pub fn has_nonce(session: Session, nonce: String) -> Bool {
  list.contains(session.nonces, digest(nonce))
}

/// The number of unredeemed tickets and live sessions, for tests and the
/// Audit page's header.
pub fn counts(registry: Registry) -> #(Int, Int) {
  #(dict.size(registry.tickets), dict.size(registry.sessions))
}
