//// The viewer's HTTP and WebSocket host on loopback.
////
//// Everything between a browser and the viewer's pages passes through this
//// module, in the order the checks must run:
////
//// 1. **Host.** The `Host` header must name loopback, or the request is
////    refused before anything else is looked at (DNS rebinding).
//// 2. **The route's own check.** The ticket exchange accepts a ticket once.
////    A page needs a live session cookie. A socket needs the cookie, an
////    `Origin` equal to the host, and the nonce its page was served with.
//// 3. **Admission.** The session behind the cookie fixes the socket's
////    principal and grants. The principal never comes from an event.
////
//// Every refusal is appended to the audit log with its reason and answered
//// with a plain status, so the Audit page shows what was tried. A refusal
//// never says which of several secrets was wrong.
////
//// A page response carries the strict content security policy with a fresh
//// nonce, and that nonce is also the `csrf-token` the page's socket must
//// present. The static files are the closed list in `assets`. A socket
//// starts one component per connection through the `seam.Mount` it was
//// given, in the socket's own process, and stops it when the browser goes
//// away.
////
//// ## Flow
////
//// - `start` binds loopback on a port (zero asks the system for one) and
////   returns the port.
//// - `handle` runs the checks and dispatches `exchange`, `page`, `socket`
////   and `asset`.
//// - `socket` upgrades; the socket's handler forwards frames that pass
////   `frame.check` and writes the component's frames to the browser.

import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/set
import lustre/attribute
import lustre/element
import lustre/element/html
import lustre/server_component
import mist
import pickglass/admission.{type Admission}
import pickglass/assets.{type Assets}
import pickglass/audit.{type Log}
import pickglass/frame
import pickglass/rules
import pickglass/seam
import pickglass/service.{type Service}
import pickglass/ticket
import pickglass_core/policy

/// What the host is built from.
pub type Config {
  Config(
    admission: Admission,
    service: Service,
    audit: Log,
    mount: seam.Mount,
    assets: Assets,
    /// Wall-clock milliseconds, for audit entries.
    clock: fn() -> Int,
    /// The port to bind, or zero for any free one.
    port: Int,
  )
}

/// A running host.
pub type Host {
  Host(port: Int)
}

/// Bind loopback and serve. `Error` when the port cannot be bound.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(host) = host.start(config)
/// ```
pub fn start(config: Config) -> Result(Host, String) {
  let ready: Subject(Int) = process.new_subject()

  let started =
    mist.new(fn(request) { handle(config, request) })
    |> mist.bind("127.0.0.1")
    |> mist.port(config.port)
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(ready, port)
    })
    |> mist.start

  case started {
    Error(_) -> Error("cannot listen on 127.0.0.1")
    Ok(_) ->
      process.receive(ready, 5000)
      |> result.map(fn(port) { Host(port:) })
      |> result.replace_error("the host did not report its port")
  }
}

/// The URL `pickglass open` prints for a ticket.
///
/// ## Examples
///
/// ```gleam
/// host.ticket_url(host, "abc")
/// // -> "http://127.0.0.1:4000/t/abc"
/// ```
pub fn ticket_url(host: Host, ticket: String) -> String {
  "http://127.0.0.1:" <> int.to_string(host.port) <> "/t/" <> ticket
}

// ---------------------------------------------------------------- handling

fn handle(
  config: Config,
  request: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case rules.loopback_host(request) {
    Error(Nil) -> {
      refuse_request(config, "any", "host is not loopback")

      status(421, "misdirected request") |> rules.refused
    }
    Ok(host) ->
      case rules.route(request) {
        rules.Exchange(presented) -> exchange(config, request, presented)
        rules.Root -> redirect("/overview") |> rules.refused
        rules.Page(slug) -> page(config, request, host, slug)
        rules.Socket(slug, nonce) -> socket(config, request, host, slug, nonce)
        rules.Asset(name) -> asset(config, name)
        rules.Unknown -> status(404, "not found") |> rules.refused
      }
  }
}

fn refuse_request(config: Config, route: String, reason: String) -> Nil {
  audit.append(
    config.audit,
    audit.Host(config.clock(), audit.RequestRefused(route, reason)),
  )
}

fn status(code: Int, text: String) -> Response(mist.ResponseData) {
  response.new(code)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
}

fn redirect(location: String) -> Response(mist.ResponseData) {
  response.new(303)
  |> response.set_header("location", location)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

// The ticket is consumed by the attempt, whatever it does. A refusal is a
// bare 404 so the response does not say whether the ticket never existed,
// was used, or expired.
fn exchange(
  config: Config,
  request: Request(mist.Connection),
  presented: String,
) -> Response(mist.ResponseData) {
  case rules.navigation_allowed(request) {
    False -> {
      refuse_request(config, "exchange", "cross-site navigation")

      status(403, "forbidden") |> rules.refused
    }
    True ->
      case admission.redeem(config.admission, presented) {
        Ok(redeemed) -> {
          audit.append(
            config.audit,
            audit.Host(
              config.clock(),
              audit.TicketRedeemed(redeemed.session.principal.text),
            ),
          )

          redirect("/overview")
          |> response.set_header(
            "set-cookie",
            rules.set_cookie(redeemed.cookie),
          )
          |> rules.refused
        }
        Error(refusal) -> {
          audit.append(
            config.audit,
            audit.Host(
              config.clock(),
              audit.TicketRefused(refusal_text(refusal)),
            ),
          )

          status(404, "not found") |> rules.refused
        }
      }
  }
}

fn refusal_text(refusal: ticket.TicketRefusal) -> String {
  case refusal {
    ticket.UnknownTicket -> "unknown or already used"
    ticket.ExpiredTicket -> "expired"
    ticket.TooManySessions -> "too many sessions"
  }
}

fn page(
  config: Config,
  request: Request(mist.Connection),
  host: String,
  slug: String,
) -> Response(mist.ResponseData) {
  case rules.navigation_allowed(request) {
    False -> {
      refuse_request(config, slug, "cross-site navigation")

      status(403, "forbidden") |> rules.refused
    }
    True ->
      case
        admission.begin_page(config.admission, rules.session_cookies(request))
      {
        Error(_) -> {
          refuse_request(config, slug, "no session")

          status(403, "open the URL that pickglass printed") |> rules.refused
        }
        Ok(#(_, nonce)) ->
          response.new(200)
          |> response.set_header("content-type", "text/html; charset=utf-8")
          |> response.set_body(
            mist.Bytes(bytes_tree.from_string(shell(slug, nonce))),
          )
          |> rules.secured(host, nonce)
      }
  }
}

// The page shell. `csrf-token` comes before `route`, because the client
// runtime reads the token at the moment `route` is set.
fn shell(slug: String, nonce: String) -> String {
  html.html([attribute.lang("en")], [
    html.head([], [
      html.meta([attribute.charset("utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute.content("width=device-width, initial-scale=1"),
      ]),
      html.title([], "pickglass"),
      html.link([
        attribute.rel("stylesheet"),
        attribute.href("/assets/" <> assets.stylesheet_name),
      ]),
      html.script(
        [
          attribute.type_("module"),
          attribute.src("/assets/" <> assets.runtime_name),
          attribute.nonce(nonce),
        ],
        "",
      ),
    ]),
    html.body([], [
      server_component.element(
        [
          server_component.csrf_token(nonce),
          server_component.route("/ws?page=" <> slug),
        ],
        [
          html.noscript([], [
            html.text("pickglass needs scripts to draw its pages."),
          ]),
        ],
      ),
    ]),
  ])
  |> element.to_document_string
}

fn asset(config: Config, name: String) -> Response(mist.ResponseData) {
  case assets.get(config.assets, name) {
    Error(Nil) -> status(404, "not found") |> rules.refused
    Ok(file) ->
      response.new(200)
      |> response.set_header("content-type", file.content_type)
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(file.bytes)))
      |> rules.hardened
  }
}

// ------------------------------------------------------------------ socket

type Phase {
  Serving(running: seam.Running, principal: String)
  Failed
}

type Signal {
  Frame(json.Json)
  Fail
}

fn socket(
  config: Config,
  request: Request(mist.Connection),
  host: String,
  slug: String,
  nonce: option.Option(String),
) -> Response(mist.ResponseData) {
  let admitted = case rules.origin_matches(request, host), nonce {
    False, _ -> Error("origin does not match")
    True, None -> Error("no csrf token")
    True, Some(presented) ->
      admission.admit_socket(
        config.admission,
        rules.session_cookies(request),
        presented,
      )
      |> result.map_error(fn(_) { "no session or wrong csrf token" })
  }

  case admitted {
    Error(reason) -> {
      audit.append(
        config.audit,
        audit.Host(config.clock(), audit.SocketRefused(reason)),
      )

      status(403, "forbidden") |> rules.refused
    }
    Ok(session) -> {
      let principal =
        policy.Principal(id: session.principal, grants: session.grants)
      let page = service.page_for(config.service, principal)

      audit.append(
        config.audit,
        audit.Host(config.clock(), audit.SocketAdmitted(principal.id.text)),
      )

      upgrade(config, request, page, slug, principal.id.text)
    }
  }
}

// One component per connection, started in the socket's own process by
// `on_init`, so a socket that dies takes its component with it.
fn upgrade(
  config: Config,
  request: Request(mist.Connection),
  page: seam.Page,
  slug: String,
  principal: String,
) -> Response(mist.ResponseData) {
  mist.websocket(
    request:,
    on_init: fn(_connection) {
      let frames = process.new_subject()
      let signals = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(frames, Frame)
        |> process.select(signals)

      case
        config.mount(page, slug, fn(encoded) { process.send(frames, encoded) })
      {
        Ok(running) -> #(Serving(running, principal), Some(selector))
        Error(_) -> {
          process.send(signals, Fail)

          #(Failed, Some(selector))
        }
      }
    },
    handler: fn(phase, message, connection) {
      case phase, message {
        // A frame from the browser is forwarded only if it is one the
        // client runtime could have sent for this page.
        Serving(running, principal), mist.Text(text) -> {
          case frame.check(text) {
            Ok(Nil) -> running.forward(text)
            Error(reason) ->
              audit.append(
                config.audit,
                audit.Host(
                  config.clock(),
                  audit.FrameRefused(principal, reason),
                ),
              )
          }

          mist.continue(phase)
        }

        // A frame from the component goes to the browser.
        Serving(..), mist.Custom(Frame(encoded)) ->
          case mist.send_text_frame(connection, json.to_string(encoded)) {
            Ok(Nil) -> mist.continue(phase)
            Error(_) -> mist.stop()
          }

        Serving(..), mist.Binary(_)
        | Serving(..), mist.Closed
        | Serving(..), mist.Shutdown
        | Serving(..), mist.Custom(Fail)
        | Failed, mist.Text(_)
        | Failed, mist.Binary(_)
        | Failed, mist.Closed
        | Failed, mist.Shutdown
        | Failed, mist.Custom(_)
        -> mist.stop()
      }
    },
    on_close: fn(phase) {
      case phase {
        Serving(running, _) -> running.shutdown()
        Failed -> Nil
      }
    },
  )
}

/// The grants a ticket for an interactive `pickglass open` carries: every
/// capability. The viewer is a fully trusted administrative component, and
/// the gate still checks each command.
pub fn operator_grants() -> List(policy.Capability) {
  policy.all_capabilities
}

/// The grants a ticket for `pickglass view` carries: observing and exporting
/// a capture file, with no target to act on.
pub fn viewer_grants() -> List(policy.Capability) {
  set.to_list(set.from_list([policy.Observe, policy.Export]))
}
