import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/list
import pickglass/internal/ffi_dist.{to_dynamic}

fn flag(name: String, value: Dynamic) -> Dynamic {
  to_dynamic(#(atom.create(name), value))
}

fn interface(name: String, flags: List(Dynamic)) -> Dynamic {
  to_dynamic(#(name, flags))
}

fn reply(interfaces: List(Dynamic)) -> Dynamic {
  to_dynamic(#(atom.create("ok"), interfaces))
}

// A reply shaped like `inet:getifaddrs/0` gives its IPv4 and IPv6 addresses
// and skips the flags that are not addresses.
pub fn addresses_are_read_from_a_getifaddrs_reply_test() {
  let found =
    reply([
      interface("lo0", [
        to_dynamic(atom.create("up")),
        flag("addr", to_dynamic(#(127, 0, 0, 1))),
        flag("netmask", to_dynamic(#(255, 0, 0, 0))),
        flag("addr", to_dynamic(#(0, 0, 0, 0, 0, 0, 0, 1))),
      ]),
      interface("utun4", [
        flag("hwaddr", to_dynamic([1, 2, 3])),
        flag("addr", to_dynamic(#(100, 75, 241, 68))),
        flag("addr", to_dynamic(#(64_890, 4444, 0, 0, 0, 0, 0, 255))),
      ]),
      interface("down0", []),
    ])
    |> ffi_dist.interface_addresses_of

  assert found
    == [
      "127.0.0.1",
      "0:0:0:0:0:0:0:1",
      "100.75.241.68",
      "FD7A:115C:0:0:0:0:0:FF",
    ]
}

// An error reply, an unexpected shape and malformed addresses give nothing
// rather than a crash.
pub fn malformed_replies_give_no_addresses_test() {
  assert ffi_dist.interface_addresses_of(
      to_dynamic(#(atom.create("error"), atom.create("enotsup"))),
    )
    == []
  assert ffi_dist.interface_addresses_of(to_dynamic("junk")) == []
  assert ffi_dist.interface_addresses_of(
      reply([
        interface("bad", [
          flag("addr", to_dynamic(#(300, 0, 0, 1))),
          flag("addr", to_dynamic(#(1, 2, 3))),
          flag("addr", to_dynamic("text")),
        ]),
        to_dynamic("not an interface"),
      ]),
    )
    == []
}

pub fn the_address_list_is_bounded_test() {
  let flags = list.repeat(flag("addr", to_dynamic(#(10, 0, 0, 1))), 1000)

  assert list.length(
      ffi_dist.interface_addresses_of(reply([interface("big", flags)])),
    )
    == 256
}

// The live call never crashes, whatever the machine has.
pub fn the_live_read_is_total_test() {
  let _ = ffi_dist.local_interface_addresses()
}
