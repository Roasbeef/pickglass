//// The viewer's audit log: every decision the gate made and every request
//// the front door refused, kept where the pages can show it.
////
//// `policy` already returns an `AuditEntry` beside every decision, so the
//// gate's allows and denies arrive here complete. The host adds a second
//// kind of entry for what `policy` never sees: a ticket that was redeemed or
//// refused, a request without the cookie, a socket whose `Origin` was wrong,
//// a frame the page could not have sent, a confirm for a plan that does not
//// exist. Both kinds go in one ring so the Audit page shows one history in
//// order.
////
//// An entry never holds a secret. A refused ticket is recorded by its
//// reason, not its value, and a principal is named by its id.
////
//// ## Flow
////
//// - `start` creates the log actor.
//// - `append` and `append_all` record entries from any process.
//// - `tail` reads the newest entries back, newest first.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import pickglass/ring.{type Ring}
import pickglass_core/policy.{type AuditEntry}
import weft/actor

/// How many entries the log keeps.
pub const capacity = 1000

/// One line of the audit history.
pub type Entry {
  /// A decision `policy` made at one of its three gates.
  Decision(entry: AuditEntry)

  /// Something the host did or refused outside `policy`.
  Host(at_ms: Int, event: HostEvent)
}

/// What the host records outside `policy`. Every field is a code or an id,
/// never a secret.
pub type HostEvent {
  /// A ticket was exchanged for a session.
  TicketRedeemed(principal: String)

  /// A ticket was refused: unknown, expired or already used.
  TicketRefused(reason: String)

  /// An HTTP request was refused before it reached a page: no cookie, a
  /// `Host` that is not loopback, a cross-site navigation, an unknown route.
  RequestRefused(route: String, reason: String)

  /// A WebSocket was upgraded for this principal.
  SocketAdmitted(principal: String)

  /// A one-time download was served to this principal.
  DownloadServed(principal: String)

  /// A WebSocket upgrade was refused: bad `Origin`, no cookie, no nonce.
  SocketRefused(reason: String)

  /// A frame from an admitted page was dropped before it reached the
  /// component.
  FrameRefused(principal: String, reason: String)

  /// A confirm named a plan that does not exist, was already confirmed, or
  /// expired and was swept.
  PlanUnknown(principal: String)

  /// A request from a page could not be turned into a command.
  RequestMalformed(principal: String, reason: String)

  /// Pins were dropped because the target went away.
  PinsInvalidated(reason: String)

  /// The oldest of a bounded list the service keeps were let go to make
  /// room: `what` names the list, `count` how many.
  RecordsDropped(what: String, count: Int)
}

/// A handle to the log actor.
pub type Log {
  Log(subject: Subject(Message))
}

/// What the actor receives.
pub opaque type Message {
  Append(List(Entry))
  Tail(count: Int, reply: Subject(List(Entry)))
}

/// Start the log.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(log) = audit.start()
/// ```
pub fn start() -> Result(Log, String) {
  let builder =
    actor.new(ring.new(capacity))
    |> actor.on_message(handle)

  case actor.start(builder) {
    Ok(started) -> Ok(Log(subject: started.data))
    Error(_) -> Error("the audit log did not start")
  }
}

fn handle(
  entries: Ring(Entry),
  message: Message,
) -> actor.Next(Ring(Entry), Message) {
  case message {
    Append(new) ->
      actor.continue(
        list.fold(new, entries, fn(ring, entry) { ring.push(ring, entry) }),
      )
    Tail(count, reply) -> {
      process.send(reply, list.take(ring.to_list(entries), count))

      actor.continue(entries)
    }
  }
}

/// Record one entry.
///
/// ## Examples
///
/// ```gleam
/// audit.append(log, audit.Host(now, audit.TicketRefused("used")))
/// ```
pub fn append(log: Log, entry: Entry) -> Nil {
  process.send(log.subject, Append([entry]))
}

/// Record several entries in order, as one message.
pub fn append_all(log: Log, entries: List(Entry)) -> Nil {
  process.send(log.subject, Append(entries))
}

/// The newest `count` entries, newest first.
///
/// ## Examples
///
/// ```gleam
/// audit.tail(log, 50)
/// ```
pub fn tail(log: Log, count: Int) -> List(Entry) {
  process.call(log.subject, 5000, fn(reply) { Tail(count, reply) })
}

/// A one-line description of an entry, for the Audit page and for tests.
///
/// ## Examples
///
/// ```gleam
/// audit.describe(Host(0, TicketRefused("used")))
/// // -> "ticket refused: used"
/// ```
pub fn describe(entry: Entry) -> String {
  case entry {
    Decision(entry) ->
      policy.stage_code(entry.stage)
      <> " "
      <> entry.principal
      <> " "
      <> entry.command
      <> case entry.decision {
        policy.Allowed -> ": allowed"
        policy.Denied(reason) -> ": denied, " <> reason
      }
    Host(_, event) -> describe_event(event)
  }
}

fn describe_event(event: HostEvent) -> String {
  case event {
    TicketRedeemed(principal) -> "ticket redeemed by " <> principal
    TicketRefused(reason) -> "ticket refused: " <> reason
    RequestRefused(route, reason) ->
      "request refused on " <> route <> ": " <> reason
    SocketAdmitted(principal) -> "socket admitted for " <> principal
    DownloadServed(principal) -> "download served to " <> principal
    SocketRefused(reason) -> "socket refused: " <> reason
    FrameRefused(principal, reason) ->
      "frame from " <> principal <> " refused: " <> reason
    PlanUnknown(principal) -> "confirm by " <> principal <> " names no plan"
    RequestMalformed(principal, reason) ->
      "request from " <> principal <> " refused: " <> reason
    PinsInvalidated(reason) -> "pins invalidated: " <> reason
    RecordsDropped(what, count) ->
      int.to_string(count) <> " oldest " <> what <> " dropped at the limit"
  }
}
