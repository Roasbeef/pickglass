import gleam/http
import gleam/http/request
import pickglass/rules

fn get(path: String) -> request.Request(String) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_path(path)
  |> request.set_header("host", "127.0.0.1:4000")
}

pub fn routes_test() {
  assert rules.route(get("/")) == rules.Root
  assert rules.route(get("/t/abc")) == rules.Exchange("abc")
  assert rules.route(get("/owners")) == rules.Page("owners")
  assert rules.route(get("/process/row.1"))
    == rules.Page("process-detail:row.1")
  assert rules.route(get("/assets/pickglass.css"))
    == rules.Asset("pickglass.css")
  assert rules.route(get("/nope")) == rules.Unknown
  assert rules.route(get("/owners/extra")) == rules.Unknown
}

pub fn only_get_routes_test() {
  assert rules.route(request.set_method(get("/owners"), http.Post))
    == rules.Unknown
  assert rules.route(request.set_method(get("/t/abc"), http.Head))
    == rules.Unknown
}

pub fn the_socket_route_carries_its_page_and_nonce_test() {
  let socket =
    request.set_query(get("/ws"), [#("page", "audit"), #("csrf-token", "n")])

  assert rules.route(socket) == rules.Socket("audit", Ok("n") |> option_of)
  assert rules.route(get("/ws")) == rules.Unknown
}

fn option_of(result: Result(String, Nil)) {
  case result {
    Ok(value) -> option.Some(value)
    Error(Nil) -> option.None
  }
}

pub fn only_loopback_hosts_pass_test() {
  let with = fn(host) { request.set_header(get("/"), "host", host) }

  assert rules.loopback_host(with("127.0.0.1:4000")) == Ok("127.0.0.1:4000")
  assert rules.loopback_host(with("localhost")) == Ok("localhost")
  assert rules.loopback_host(with("[::1]:80")) == Ok("[::1]:80")
  assert rules.loopback_host(with("evil.example")) == Error(Nil)
  assert rules.loopback_host(with("127.0.0.1.evil.example")) == Error(Nil)
  assert rules.loopback_host(with("127.0.0.1:99999999")) == Error(Nil)
  assert rules.loopback_host(with("127.0.0.1:")) == Error(Nil)
  assert rules.loopback_host(request.new()) == Error(Nil)
}

pub fn cross_site_navigations_are_refused_test() {
  let with = fn(value) { request.set_header(get("/"), "sec-fetch-site", value) }

  assert rules.navigation_allowed(with("none"))
  assert rules.navigation_allowed(with("same-origin"))
  assert !rules.navigation_allowed(with("same-site"))
  assert !rules.navigation_allowed(with("cross-site"))
  // A program that is not a browser sends none; it still needs the secrets.
  assert rules.navigation_allowed(get("/"))
}

pub fn the_origin_must_equal_the_host_test() {
  let with = fn(origin) { request.set_header(get("/ws"), "origin", origin) }

  assert rules.origin_matches(with("http://127.0.0.1:4000"), "127.0.0.1:4000")
  assert !rules.origin_matches(with("http://127.0.0.1:4001"), "127.0.0.1:4000")
  assert !rules.origin_matches(with("http://evil.example"), "127.0.0.1:4000")
  assert !rules.origin_matches(get("/ws"), "127.0.0.1:4000")
}

pub fn only_the_viewers_cookies_are_read_test() {
  let cookies =
    request.set_header(
      get("/"),
      "cookie",
      "other=1; pickglass_session=a; pickglass_session=b",
    )

  assert rules.session_cookies(cookies) == ["a", "b"]
  assert rules.session_cookies(get("/")) == []
}

pub fn the_cookie_is_http_only_and_strict_test() {
  let cookie = rules.set_cookie("v")

  assert cookie == "pickglass_session=v; HttpOnly; SameSite=Strict; Path=/"
}

pub fn the_policy_carries_the_nonce_and_no_unsafe_script_test() {
  let policy = rules.content_security_policy("127.0.0.1:4000", "N0nce")

  assert contains(policy, "script-src 'self' 'nonce-N0nce'")
  assert contains(policy, "default-src 'none'")
  assert contains(policy, "frame-ancestors 'none'")
  assert contains(policy, "form-action 'none'")
  assert contains(policy, "connect-src 'self' ws://127.0.0.1:4000")
  assert !contains(policy, "script-src 'unsafe-inline'")
  assert !contains(policy, "unsafe-eval")
}

import gleam/option
import gleam/string

fn contains(text: String, part: String) -> Bool {
  string.contains(text, part)
}

pub fn a_process_key_outside_the_alphabet_is_no_route_test() {
  assert rules.route(get("/process/a%20b")) == rules.Unknown
  assert rules.route(get("/process/a%3Cb")) == rules.Unknown
}
