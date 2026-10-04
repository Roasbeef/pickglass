import gleam/string
import pickglass/internal/ffi_dist

// Starting distribution in a VM with no cookie of its own would make OTP
// create ~/.erlang.cookie in the operator's home. The test VM is started the
// ordinary way, so the viewer must refuse instead of starting.
pub fn distribution_is_refused_without_a_private_cookie_test() {
  assert !ffi_dist.has_private_cookie()

  let assert Error(message) =
    ffi_dist.start_hidden_node("pickglass_cookie_test@127.0.0.1", "longnames")

  assert string.contains(message, "-nocookie")
  assert string.contains(message, "~/.erlang.cookie")
}
