//// The host's request rules, as pure functions of a request.
////
//// A page served from loopback is reachable by every other page the same
//// browser has open, and by every program on the machine. The bind to
//// `127.0.0.1` keeps out the network; these rules are what keep out the
//// rest. Each is a function of the request alone, generic over its body, so
//// a test can hand it any header a browser, a DNS-rebinding page or a plain
//// program might send, with no listener.
////
//// - `loopback_host`: the `Host` must name loopback. A page that rebinds a
////   name to `127.0.0.1` reaches the listener under its own name, and is
////   refused here.
//// - `navigation_allowed`: when a browser sends `Sec-Fetch-Site`, it must
////   say `none` (a link or bookmark) or `same-origin`. `same-site` (another
////   loopback port) and `cross-site` are refused. A request with no such
////   header is a program that is not a browser; it still needs the ticket or
////   the cookie.
//// - `origin_matches`: a WebSocket upgrade must carry an `Origin` equal to
////   `http://` and the request's own `Host`. A cross-site page cannot forge
////   it, and a program that sends none is refused.
//// - `session_cookies`: the viewer's cookie values, bounded.
////
//// The CSP, the cookie and the response headers are here too, so that one
//// module says what every response carries.
////
//// ## Flow
////
//// - `route` names what a request asks for.
//// - The predicates check a request; `secured` and `refused` add the headers.

import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The name of the session cookie.
pub const cookie_name = "pickglass_session"

/// What a request asks for.
pub type Route {
  /// `GET /t/<ticket>`: the ticket exchange.
  Exchange(ticket: String)

  /// `GET /`: sent to the overview.
  Root

  /// `GET /<page>` or `GET /process/<key>`: a page, by its route slug.
  Page(slug: String)

  /// `GET /ws?page=<slug>&csrf-token=<nonce>`: the component's socket.
  Socket(slug: String, nonce: Option(String))

  /// `GET /assets/<name>`.
  Asset(name: String)

  /// `GET /download/<ticket>`: a file the viewer built, handed over once.
  Download(ticket: String)

  /// Anything else, including every method but `GET`.
  Unknown
}

/// The pages and the slugs the application knows them by.
const page_slugs = [
  "overview", "owners", "processes", "memory", "supervision", "probes",
  "profile", "timeline", "compare", "audit",
]

/// Name what a request asks for.
///
/// ## Examples
///
/// ```gleam
/// rules.route(request)
/// // -> Page("owners")
/// ```
pub fn route(request: Request(body)) -> Route {
  case request.method, request.path_segments(request) {
    http.Get, [] -> Root
    http.Get, ["t", ticket] -> Exchange(ticket)
    http.Get, ["ws"] ->
      case query(request, "page") {
        Some(slug) -> Socket(slug, query(request, "csrf-token"))
        None -> Unknown
      }
    http.Get, ["assets", name] -> Asset(name)
    http.Get, ["download", ticket] -> Download(ticket)
    http.Get, ["process", subject] ->
      case
        string.length(subject) <= 64
        && list.all(string.to_graphemes(subject), subject_char)
      {
        True -> Page("process-detail:" <> subject)
        False -> Unknown
      }
    http.Get, [slug] ->
      case list.contains(page_slugs, slug) {
        True -> Page(slug)
        False -> Unknown
      }
    _, _ -> Unknown
  }
}

// A process key is letters, digits, underscore, dot, colon and hyphen: the
// alphabet the web package's keys are drawn from, so the address cannot carry
// anything else into the page's route.
fn subject_char(grapheme: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-",
    grapheme,
  )
}

fn query(request: Request(body), name: String) -> Option(String) {
  request.get_query(request)
  |> result.unwrap([])
  |> list.key_find(name)
  |> option.from_result
}

/// The request's `Host` when it names loopback, with any port.
///
/// ## Examples
///
/// ```gleam
/// rules.loopback_host(request)
/// // -> Ok("127.0.0.1:4000")
/// ```
pub fn loopback_host(request: Request(body)) -> Result(String, Nil) {
  use host <- result.try(request.get_header(request, "host"))

  let #(name, suffix) = case string.split_once(host, "]") {
    Ok(#(literal, rest)) -> #(literal <> "]", rest)
    Error(Nil) ->
      case string.split_once(host, ":") {
        Ok(#(name, port)) -> #(name, ":" <> port)
        Error(Nil) -> #(host, "")
      }
  }

  case string.lowercase(name), valid_port(suffix) {
    "127.0.0.1", True | "[::1]", True | "localhost", True -> Ok(host)
    _, _ -> Error(Nil)
  }
}

fn valid_port(suffix: String) -> Bool {
  case suffix {
    "" -> True
    ":" <> digits ->
      digits != ""
      && string.length(digits) <= 5
      && list.all(string.to_graphemes(digits), fn(digit) {
        string.contains("0123456789", digit)
      })
    _ -> False
  }
}

/// Whether a navigation may proceed. `Sec-Fetch-Site`, when present, must be
/// `none` or `same-origin`.
///
/// ## Examples
///
/// ```gleam
/// rules.navigation_allowed(request)
/// ```
pub fn navigation_allowed(request: Request(body)) -> Bool {
  case request.get_header(request, "sec-fetch-site") {
    Ok("none") | Ok("same-origin") | Error(Nil) -> True
    Ok(_) -> False
  }
}

/// Whether a WebSocket upgrade came from this origin: `Origin` is present
/// and is `http://` followed by the request's host.
///
/// ## Examples
///
/// ```gleam
/// rules.origin_matches(request, "127.0.0.1:4000")
/// ```
pub fn origin_matches(request: Request(body), host: String) -> Bool {
  case request.get_header(request, "origin") {
    Ok(origin) -> origin == "http://" <> host
    Error(Nil) -> False
  }
}

/// The viewer's cookie values the request carries, in the order sent, at
/// most four.
///
/// ## Examples
///
/// ```gleam
/// rules.session_cookies(request)
/// // -> ["value"]
/// ```
pub fn session_cookies(request: Request(body)) -> List(String) {
  request.get_cookies(request)
  |> list.filter_map(fn(pair) {
    case pair.0 == cookie_name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> list.take(4)
}

/// The `Set-Cookie` value for a session: `HttpOnly` so no script reads it,
/// `SameSite=Strict` so a cross-site navigation does not carry it, and a
/// path of `/` because the pages link to each other from the root. It has no
/// `Max-Age`, so the browser drops it when the browser session ends.
pub fn set_cookie(value: String) -> String {
  cookie_name <> "=" <> value <> "; HttpOnly; SameSite=Strict; Path=/"
}

/// The content security policy of a page response. Scripts are the host's
/// own files and the one module tag that carries the page nonce; styles are
/// the host's stylesheet; the only connection is the socket back to this
/// host; nothing may frame the page or submit a form.
///
/// ## Examples
///
/// ```gleam
/// rules.content_security_policy("127.0.0.1:4000", "abc")
/// ```
pub fn content_security_policy(host: String, nonce: String) -> String {
  "default-src 'none'; script-src 'self' 'nonce-"
  <> nonce
  <> "'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; "
  <> "connect-src 'self' ws://"
  <> host
  <> "; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
}

/// The headers every response carries.
pub fn hardened(response: Response(body)) -> Response(body) {
  response
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("referrer-policy", "no-referrer")
  |> response.set_header("cache-control", "no-store")
}

/// A refusal made before the host was trusted: the policy allows nothing to
/// load.
pub fn refused(response: Response(body)) -> Response(body) {
  response
  |> response.set_header(
    "content-security-policy",
    "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  )
  |> hardened
}

/// A page response: the strict policy with this page's nonce.
pub fn secured(
  response: Response(body),
  host: String,
  nonce: String,
) -> Response(body) {
  response
  |> response.set_header(
    "content-security-policy",
    content_security_policy(host, nonce),
  )
  |> hardened
}
