//// One-time downloads: files the viewer built for a page and hands to the
//// browser exactly once.
////
//// The pages run as server components over a WebSocket, so a file cannot
//// travel on it. An export is therefore built in memory, stored here under
//// a random ticket, and offered to the page as a link to `/download/<ticket>`.
//// The browser's request for that address is an ordinary HTTP request that
//// carries the session cookie.
////
//// The rules are the ones the front door applies to its own tickets. The
//// registry keeps only the SHA-256 digest of a ticket, so a dump of it does
//// not yield an address that works; a ticket is removed by the attempt to
//// use it, whether or not the attempt succeeds, so it cannot be tried twice;
//// an unused ticket expires after `ttl_ms`; and the registry holds at most
//// `capacity` files, dropping the oldest, so a page that keeps asking for
//// exports cannot grow the viewer's memory without bound.
////
//// The registry is a plain value. The service owns one and nothing else
//// mutates it, so two requests for one ticket are handled one after the
//// other and the second finds nothing.

import gleam/bit_array
import gleam/crypto
import gleam/list
import gleam/string

/// How long an unused ticket stays valid, in milliseconds.
pub const ttl_ms = 300_000

/// The most files held at once.
pub const capacity = 16

/// A file ready to be sent.
pub type Download {
  Download(
    /// The name the browser saves it under.
    file_name: String,
    /// The content type it is served with.
    content_type: String,
    /// The file's text.
    body: String,
  )
}

type Entry {
  Entry(digest: String, stored_ms: Int, download: Download)
}

/// The downloads waiting to be fetched, newest first.
pub opaque type Registry {
  Registry(entries: List(Entry))
}

/// Why a ticket gave nothing. A caller must not tell the browser which.
pub type Refusal {
  /// No such ticket: never issued, already used, or evicted.
  UnknownTicket

  /// The ticket was issued but is older than `ttl_ms`.
  ExpiredTicket
}

/// A registry with nothing in it.
pub fn new() -> Registry {
  Registry(entries: [])
}

/// Store a download under a ticket. Only the ticket's digest is kept. When
/// the registry is full the oldest download is dropped.
///
/// ## Examples
///
/// ```gleam
/// downloads.put(registry, "ticket", Download("a.txt", "text/plain", "x"), 0)
/// ```
pub fn put(
  registry: Registry,
  ticket: String,
  download: Download,
  now_ms: Int,
) -> Registry {
  Registry(entries: [
    Entry(digest: digest_of(ticket), stored_ms: now_ms, download:),
    ..list.take(registry.entries, capacity - 1)
  ])
}

/// Use a ticket. The ticket is removed whatever the outcome, so a second
/// attempt finds nothing.
///
/// ## Examples
///
/// ```gleam
/// let #(registry, outcome) = downloads.take(registry, "ticket", 10)
/// ```
pub fn take(
  registry: Registry,
  ticket: String,
  now_ms: Int,
) -> #(Registry, Result(Download, Refusal)) {
  let wanted = digest_of(ticket)
  let #(matching, rest) =
    list.partition(registry.entries, fn(entry) { entry.digest == wanted })

  case matching {
    [] -> #(registry, Error(UnknownTicket))
    [entry, ..] ->
      case now_ms - entry.stored_ms > ttl_ms {
        True -> #(Registry(entries: rest), Error(ExpiredTicket))
        False -> #(Registry(entries: rest), Ok(entry.download))
      }
  }
}

/// How many downloads are waiting.
pub fn size(registry: Registry) -> Int {
  list.length(registry.entries)
}

fn digest_of(ticket: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(ticket))
  |> bit_array.base16_encode
  |> string.lowercase
}
