import gleam/list
import gleam/string
import pickglass/endpoint.{
  Endpoint, LongNames, MalformedNode, NonLoopback, ShortNames,
}
import qcheck

// The host decides the naming mode: a dot or a colon is a long name, and a
// bare word is a short name.
pub fn the_host_chooses_the_naming_mode_test() {
  assert endpoint.parse("app@127.0.0.1", "/c")
    == Ok(Endpoint("app", "127.0.0.1", LongNames, "/c"))
  assert endpoint.parse("app@box.example.com", "/c")
    == Ok(Endpoint("app", "box.example.com", LongNames, "/c"))
  assert endpoint.parse("app@::1", "/c")
    == Ok(Endpoint("app", "::1", LongNames, "/c"))
  assert endpoint.parse("app@mybox", "/c")
    == Ok(Endpoint("app", "mybox", ShortNames, "/c"))

  // `localhost` has no dot, so it is a short name; `127.0.0.1` is the
  // spelling for a node started with `-name app@localhost`.
  assert endpoint.naming_of("localhost") == ShortNames
}

pub fn the_node_name_round_trips_test() {
  let assert Ok(parsed) = endpoint.parse("pg_test-1@127.0.0.1", "/c")
    as "a plain node name parses"

  assert endpoint.node_name(parsed) == "pg_test-1@127.0.0.1"
}

pub fn malformed_node_names_are_refused_test() {
  list.each(
    ["", "app", "@host", "app@", "a@b@c", "app @host", "a\"b@host", "a@h/x"],
    fn(text) {
      assert endpoint.parse(text, "/c") == Error(MalformedNode(text))
    },
  )
}

// Parsing is total, and what it accepts always splits back into the same
// name and host.
pub fn property_parse_is_total_and_consistent_test() {
  qcheck.run(qcheck.default_config(), qcheck.string(), fn(text) {
    case endpoint.parse(text, "/c") {
      Ok(parsed) -> {
        assert endpoint.node_name(parsed) == text
        assert endpoint.naming_of(parsed.host) == parsed.naming
      }
      Error(error) -> {
        assert error == MalformedNode(text)
      }
    }
  })
}

// The loopback check is the one place that decides what is local.
pub fn only_this_machine_is_accepted_test() {
  assert endpoint.check_loopback("127.0.0.1", "mybox", []) == Ok(Nil)
  assert endpoint.check_loopback("::1", "mybox", []) == Ok(Nil)
  assert endpoint.check_loopback("localhost", "mybox", []) == Ok(Nil)
  assert endpoint.check_loopback("mybox", "mybox", []) == Ok(Nil)
  assert endpoint.check_loopback("MyBox", "mybox.local", []) == Ok(Nil)
  assert endpoint.check_loopback("mybox.local", "mybox.local", []) == Ok(Nil)

  assert endpoint.check_loopback("10.0.0.5", "mybox", [])
    == Error(NonLoopback("10.0.0.5"))
  assert endpoint.check_loopback("db.example.com", "mybox", [])
    == Error(NonLoopback("db.example.com"))
  assert endpoint.check_loopback("otherbox", "mybox", [])
    == Error(NonLoopback("otherbox"))
  assert endpoint.check_loopback("127.0.0.2", "mybox", [])
    == Error(NonLoopback("127.0.0.2"))
}

// A host that merely begins with this machine's name is another machine.
pub fn a_host_name_prefix_is_not_local_test() {
  assert endpoint.check_loopback("mybox2", "mybox", [])
    == Error(NonLoopback("mybox2"))
  assert endpoint.check_loopback("mybox.evil.example", "mybox", [])
    == Error(NonLoopback("mybox.evil.example"))
}

pub fn the_refusal_names_the_host_and_the_remedy_test() {
  let message = endpoint.describe_error(NonLoopback("db.example.com"))

  assert string.contains(message, "db.example.com")
  assert string.contains(message, "this machine only")
}

pub fn the_default_cookie_file_is_in_home_test() {
  assert endpoint.default_cookie_file(Ok("/home/me"))
    == Ok("/home/me/.erlang.cookie")
  assert endpoint.default_cookie_file(Error(Nil)) == Error(Nil)
  assert endpoint.default_cookie_file(Ok("")) == Error(Nil)
}

pub fn the_domain_text_is_the_otp_option_value_test() {
  assert endpoint.domain(LongNames) == "longnames"
  assert endpoint.domain(ShortNames) == "shortnames"
}

const tailnet = [
  "127.0.0.1", "100.75.241.68", "fe80:0:0:0:1:2:3:4", "fd7a:115c:a1e0::1",
]

// A Tailscale address assigned to a local interface names this machine.
pub fn an_interface_address_is_accepted_test() {
  assert endpoint.check_loopback("100.75.241.68", "mybox", tailnet) == Ok(Nil)

  // Another machine's address, and a near miss, are still refused.
  assert endpoint.check_loopback("100.75.241.69", "mybox", tailnet)
    == Error(NonLoopback("100.75.241.69"))
  assert endpoint.check_loopback("100.75.241.68", "mybox", [])
    == Error(NonLoopback("100.75.241.68"))
}

// Two spellings of one IPv6 address are one address.
pub fn ipv6_forms_compare_by_value_test() {
  assert endpoint.check_loopback("fd7a:115c:a1e0:0:0:0:0:1", "b", tailnet)
    == Ok(Nil)
  assert endpoint.check_loopback("FD7A:115C:A1E0::1", "b", tailnet) == Ok(Nil)
  assert endpoint.check_loopback("fe80::1:2:3:4", "b", tailnet) == Ok(Nil)
  assert endpoint.check_loopback("::ffff:100.75.241.68", "b", [
      "0:0:0:0:0:ffff:644b:f144",
    ])
    == Ok(Nil)
  assert endpoint.check_loopback("fd7a:115c:a1e0::2", "b", tailnet)
    == Error(NonLoopback("fd7a:115c:a1e0::2"))
}

// A zone id, a name and malformed text never match, even when the list holds
// the same text.
pub fn only_plain_address_literals_match_test() {
  list.each(
    [
      "fe80::1:2:3:4%en0", "mybox", "100.75.241", "100.75.241.68.1",
      "100.75.241.256", "100.075.241.68", "1:2:3", "1::2::3", ":::", "1:::2",
      "fd7a:115c:a1e0::1:", "12345::1", "100.75.241.68%x", "",
    ],
    fn(text) {
      assert endpoint.check_loopback(text, "box", [text, ""])
        == Error(NonLoopback(text))
    },
  )
}

pub fn the_refusal_mentions_interface_addresses_test() {
  assert string.contains(
    endpoint.describe_error(NonLoopback("db.example.com")),
    "network interfaces",
  )
}
