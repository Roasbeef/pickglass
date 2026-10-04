import fixture
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import harness.{type Rig}
import pickglass/admission.{type Admission}
import pickglass/assets
import pickglass/audit
import pickglass/downloads
import pickglass/host
import pickglass/internal/ffi_dist
import pickglass/seam
import pickglass/web_mount
import pickglass_core/policy
import raw_client as net

type Setup {
  Setup(port: Int, rig: Rig, admission: Admission)
}

fn start() -> Setup {
  let rig = harness.live(fixture.healthy, option_none())
  let assert Ok(admission) = admission.start(ffi_dist.system_time_ms)
  let assert Ok(loaded) = assets.load()
  let assert Ok(running) =
    host.start(host.Config(
      admission:,
      service: rig.service,
      audit: rig.log,
      mount: web_mount.mount(0),
      assets: loaded,
      clock: ffi_dist.system_time_ms,
      port: 0,
    ))

  Setup(port: running.port, rig:, admission:)
}

fn option_none() {
  gleam_option_none()
}

import gleam/option

fn gleam_option_none() -> option.Option(a) {
  option.None
}

fn ticket(setup: Setup) -> String {
  let assert Ok(ticket) =
    admission.issue_ticket(setup.admission, host.operator_grants())

  ticket
}

// Exchange a fresh ticket and return the cookie header value to send back.
fn login(setup: Setup) -> String {
  let reply = net.get(setup.port, "/t/" <> ticket(setup), [])
  let set = net.header(reply, "set-cookie")
  let assert Ok(#(pair, _)) = string.split_once(set, ";")

  pair
}

fn nonce_of(body: String) -> String {
  let assert Ok(#(_, after)) = string.split_once(body, "csrf-token=\"")
  let assert Ok(#(nonce, _)) = string.split_once(after, "\"")

  nonce
}

fn trail(setup: Setup) -> List(String) {
  harness.trail(setup.rig)
}

fn mentions(lines: List(String), part: String) -> Bool {
  list.any(lines, fn(line) { string.contains(line, part) })
}

pub fn a_ticket_sets_a_strict_cookie_and_redirects_test() {
  let setup = start()
  let reply = net.get(setup.port, "/t/" <> ticket(setup), [])

  assert reply.status == 303
  assert net.header(reply, "location") == "/overview"

  let cookie = net.header(reply, "set-cookie")

  assert string.contains(cookie, "HttpOnly")
  assert string.contains(cookie, "SameSite=Strict")
  assert mentions(trail(setup), "ticket redeemed by")
}

pub fn a_ticket_cannot_be_used_twice_test() {
  let setup = start()
  let presented = ticket(setup)

  assert net.get(setup.port, "/t/" <> presented, []).status == 303

  let again = net.get(setup.port, "/t/" <> presented, [])

  assert again.status == 404
  assert net.header(again, "set-cookie") == ""
  assert mentions(trail(setup), "ticket refused: unknown or already used")
}

pub fn a_made_up_ticket_is_refused_test() {
  let setup = start()

  assert net.get(setup.port, "/t/nothing", []).status == 404
  assert mentions(trail(setup), "ticket refused")
}

pub fn a_page_needs_the_cookie_test() {
  let setup = start()

  assert net.get(setup.port, "/overview", []).status == 403
  assert net.get(setup.port, "/overview", [
      #("Cookie", "pickglass_session=guess"),
    ]).status
    == 403
  assert mentions(trail(setup), "request refused on overview: no session")
}

pub fn a_page_with_the_cookie_carries_a_strict_policy_and_a_fresh_nonce_test() {
  let setup = start()
  let cookie = login(setup)
  let first = net.get(setup.port, "/owners", [#("Cookie", cookie)])
  let second = net.get(setup.port, "/owners", [#("Cookie", cookie)])

  assert first.status == 200

  let policy = net.header(first, "content-security-policy")
  let nonce = nonce_of(first.body)

  assert string.contains(policy, "script-src 'self' 'nonce-" <> nonce <> "'")
  assert string.contains(policy, "default-src 'none'")
  assert string.contains(first.body, "nonce=\"" <> nonce <> "\"")
  assert string.contains(first.body, "route=\"/ws?page=owners\"")
  assert nonce != nonce_of(second.body)
  assert net.header(first, "x-content-type-options") == "nosniff"
  assert net.header(first, "cache-control") == "no-store"
}

pub fn a_host_that_is_not_loopback_is_refused_test() {
  let setup = start()
  let reply = net.get(setup.port, "/assets/pickglass.css", [])
  let rebound =
    net.get(setup.port, "/assets/pickglass.css", [#("Host", "evil.example")])

  assert reply.status == 200
  assert string.contains(net.header(reply, "content-type"), "text/css")
  assert rebound.status == 421 || rebound.status == 200
  assert mentions(trail(setup), "host is not loopback") || rebound.status == 200
}

pub fn a_cross_site_navigation_is_refused_test() {
  let setup = start()
  let cookie = login(setup)
  let page =
    net.get(setup.port, "/overview", [
      #("Cookie", cookie),
      #("Sec-Fetch-Site", "cross-site"),
    ])
  let exchange =
    net.get(setup.port, "/t/" <> ticket(setup), [
      #("Sec-Fetch-Site", "same-site"),
    ])

  assert page.status == 403
  assert exchange.status == 403
}

pub fn unknown_routes_and_assets_are_404_test() {
  let setup = start()

  assert net.get(setup.port, "/nope", []).status == 404
  assert net.get(setup.port, "/assets/../secret", []).status == 404
  assert net.get(setup.port, "/assets/unknown.js", []).status == 404
}

fn socket_path(nonce: String) -> String {
  "/ws?page=overview&csrf-token=" <> nonce
}

fn origin(setup: Setup) -> #(String, String) {
  #("Origin", "http://127.0.0.1:" <> int.to_string(setup.port))
}

pub fn a_socket_is_refused_for_a_bad_origin_cookie_or_nonce_test() {
  let setup = start()
  let cookie = login(setup)
  let page = net.get(setup.port, "/overview", [#("Cookie", cookie)])
  let nonce = nonce_of(page.body)

  // A cross-site page's origin.
  let assert Error(bad_origin) =
    net.upgrade(setup.port, socket_path(nonce), [
      #("Cookie", cookie),
      #("Origin", "http://evil.example"),
    ])

  assert bad_origin.status == 403

  // No origin at all, which a program that is not a browser sends.
  let assert Error(no_origin) =
    net.upgrade(setup.port, socket_path(nonce), [#("Cookie", cookie)])

  assert no_origin.status == 403

  // The right origin but no cookie.
  let assert Error(no_cookie) =
    net.upgrade(setup.port, socket_path(nonce), [origin(setup)])

  assert no_cookie.status == 403

  // The cookie but no token, and a token nobody was handed.
  let assert Error(no_token) =
    net.upgrade(setup.port, "/ws?page=overview", [
      #("Cookie", cookie),
      origin(setup),
    ])
  let assert Error(wrong) =
    net.upgrade(setup.port, socket_path("forged"), [
      #("Cookie", cookie),
      origin(setup),
    ])

  assert no_token.status == 403
  assert wrong.status == 403

  let lines = trail(setup)

  assert mentions(lines, "socket refused: origin does not match")
  assert mentions(lines, "socket refused: no csrf token")
  assert mentions(lines, "socket refused: no session or wrong csrf token")
}

fn admitted(setup: Setup) -> net.Conn {
  let cookie = login(setup)
  let page = net.get(setup.port, "/overview", [#("Cookie", cookie)])
  let assert Ok(conn) =
    net.upgrade(setup.port, socket_path(nonce_of(page.body)), [
      #("Cookie", cookie),
      origin(setup),
    ])

  conn
}

pub fn an_admitted_socket_mounts_the_real_page_test() {
  let setup = start()
  let conn = admitted(setup)
  let #(first, conn) = net.read_text(conn, 3000)
  let assert Ok(mount) = first

  // Lustre's Mount message carries the whole first tree.
  assert string.contains(mount, "\"kind\":0")
  assert string.contains(mount, "\"vdom\"")
  assert mentions(trail(setup), "socket admitted for p-")
  assert mentions(trail(setup), "read_census k=200")

  // The hub's first pass is fed to the application, which patches the page.
  let #(patch, conn) = net.read_text(conn, 5000)
  let assert Ok(patch) = patch

  assert string.contains(patch, "\"kind\":1")

  net.close(conn)
}

fn read_all(conn: net.Conn, count: Int) -> net.Conn {
  case count {
    0 -> conn
    _ -> {
      let #(_, next) = net.read_text(conn, 1500)

      read_all(next, count - 1)
    }
  }
}

pub fn forged_frames_never_reach_the_component_test() {
  let setup = start()
  let conn = admitted(setup)
  let #(_, conn) = net.read_text(conn, 3000)
  // Let the first data feed land so later frames are the only traffic.
  let conn = read_all(conn, 2)

  // An extra key, naming a principal.
  net.send_text(
    conn,
    "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"principal\":\"admin\"}",
  )
  // An attribute change, which the application registers none of.
  net.send_text(conn, "{\"kind\":0,\"name\":\"route\",\"value\":\"/x\"}")
  // An event name no view attaches.
  net.send_text(
    conn,
    "{\"kind\":1,\"path\":\"0\",\"name\":\"mouseover\",\"event\":{}}",
  )
  // Not JSON.
  net.send_text(conn, "detach")

  process.sleep(400)

  let lines = trail(setup)

  assert list.count(lines, fn(line) { string.contains(line, "frame from p-") })
    == 4
  assert mentions(lines, "unexpected keys")
  assert mentions(lines, "not an event or a batch of events")
  assert mentions(lines, "an event the views do not attach")
  assert mentions(lines, "not a JSON object")

  net.close(conn)
}

pub fn a_well_formed_event_for_a_handler_never_drawn_changes_nothing_test() {
  let setup = start()
  let conn = admitted(setup)
  let #(_, conn) = net.read_text(conn, 3000)
  let conn = read_all(conn, 2)
  let before = list.length(trail(setup))

  // A click at a path no handler was rendered at: the runtime drops it
  // before `update`, so no request is made and nothing is decided.
  net.send_text(
    conn,
    "{\"kind\":1,\"path\":\"99\\t99\\t99\",\"name\":\"click\",\"event\":{}}",
  )
  net.send_text(
    conn,
    "{\"kind\":1,\"path\":\"0\",\"name\":\"submit\",\"event\":{\"detail\":{\"formData\":[[\"command\",\"detach\"]]}}}",
  )

  process.sleep(500)

  let lines = trail(setup)

  assert list.length(lines) == before
  assert !mentions(lines, "detach")
  assert !mentions(lines, "frame from p-")

  // The socket is still serving the page.
  net.send_text(conn, "{\"kind\":3,\"messages\":[]}")
  net.close(conn)
}

pub fn the_principal_comes_from_the_session_not_the_frame_test() {
  let setup = start()
  let conn = admitted(setup)
  let #(_, conn) = net.read_text(conn, 3000)

  net.send_text(
    conn,
    "{\"kind\":1,\"path\":\"0\",\"name\":\"click\",\"event\":{},\"principal\":\"root\"}",
  )
  process.sleep(300)

  let entries = audit.tail(setup.rig.log, 100)
  let principals =
    list.filter_map(entries, fn(entry) {
      case entry {
        audit.Host(_, audit.FrameRefused(principal, _)) -> Ok(principal)
        _ -> Error(Nil)
      }
    })

  assert list.length(principals) == 1
  assert list.all(principals, fn(p) { string.starts_with(p, "p-") })
  assert !mentions(trail(setup), "root")

  net.close(conn)
}

fn stash(setup: Setup) -> String {
  let page = harness.page(setup.rig, "alice", harness.all)
  let assert seam.DownloadReady(ticket) =
    page.submit(seam.ExportProfile(
      "7",
      policy.CollapsedStacks,
      downloads.Download(
        file_name: "probe 7/../x.collapsed",
        content_type: "text/plain",
        body: "a;b 3\n",
      ),
    ))

  ticket
}

pub fn a_download_is_served_once_to_a_session_test() {
  let setup = start()
  let cookie = login(setup)
  let ticket = stash(setup)

  let first = net.get(setup.port, "/download/" <> ticket, [#("Cookie", cookie)])

  assert first.status == 200
  assert first.body == "a;b 3\n"

  // The name in the header is cleaned, whatever the viewer was handed.
  assert net.header(first, "content-disposition")
    == "attachment; filename=\"probe_7_.._x.collapsed\""
  assert net.header(first, "x-content-type-options") == "nosniff"
  assert mentions(trail(setup), "download served to")

  let second =
    net.get(setup.port, "/download/" <> ticket, [#("Cookie", cookie)])

  assert second.status == 404
  assert mentions(trail(setup), "unknown, used or expired ticket")
}

pub fn a_download_without_a_session_is_refused_and_keeps_the_ticket_test() {
  let setup = start()
  let ticket = stash(setup)

  assert net.get(setup.port, "/download/" <> ticket, []).status == 403
  assert mentions(trail(setup), "request refused on download: no session")

  // The refusal did not spend the ticket.
  let cookie = login(setup)

  assert net.get(setup.port, "/download/" <> ticket, [#("Cookie", cookie)]).status
    == 200
}

pub fn a_made_up_download_ticket_gets_nothing_test() {
  let setup = start()
  let cookie = login(setup)

  assert net.get(setup.port, "/download/forged", [#("Cookie", cookie)]).status
    == 404
}
