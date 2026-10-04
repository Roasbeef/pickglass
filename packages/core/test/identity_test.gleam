import gleam/string
import pg_data_gen as gen
import pickglass_core/identity.{
  CoarseStart, Different, Indeterminate, OsProcess, PreciseStart, Same,
  SameWithinCoarseResolution, UnreadableStart,
}

fn boot(text: String) -> identity.BootId {
  case identity.boot_id(text) {
    Ok(id) -> id
    Error(Nil) -> panic as "test boot id must be valid"
  }
}

pub fn boot_ids_are_restricted_test() {
  assert identity.boot_id("7f3a9c") |> is_ok
  assert identity.boot_id("a-b_C9") |> is_ok
  assert identity.boot_id("") == Error(Nil)
  assert identity.boot_id("has:colon") == Error(Nil)
  assert identity.boot_id("has space") == Error(Nil)
  assert identity.boot_id(string.repeat("a", 65)) == Error(Nil)
  assert identity.boot_id(string.repeat("a", 64)) |> is_ok
}

fn is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn property_pin_text_round_trips_test() {
  use #(b, serial) <- gen.check(gen.tuple2(gen.boot_id(), gen.non_negative()))
  let assert Ok(token) = identity.pin(b, serial) as "serial is non-negative"
  assert identity.parse_pin(identity.pin_to_string(token)) == Ok(token)
}

pub fn malformed_pin_text_is_refused_test() {
  assert identity.parse_pin("") == Error(Nil)
  assert identity.parse_pin("abc") == Error(Nil)
  assert identity.parse_pin("abc:") == Error(Nil)
  assert identity.parse_pin(":3") == Error(Nil)
  assert identity.parse_pin("abc:-1") == Error(Nil)
  assert identity.parse_pin("abc:x") == Error(Nil)
  assert identity.parse_pin("a:b:3") == Error(Nil)
  assert identity.pin(boot("abc"), -1) == Error(Nil)
}

// A token issued under one boot id must not be accepted under another:
// that is what stops a stale token from naming a different process after
// the daemon restarts.
pub fn pins_from_another_incarnation_are_refused_test() {
  let assert Ok(token) = identity.pin(boot("aaaa"), 3) as "valid pin"

  assert identity.check_pin(token, boot("bbbb"))
    == Error(identity.OtherIncarnation(token_boot: "aaaa", current_boot: "bbbb"))
}

pub fn pins_from_the_current_incarnation_are_live_test() {
  let assert Ok(token) = identity.pin(boot("aaaa"), 3) as "valid pin"
  let assert Ok(live) = identity.check_pin(token, boot("aaaa"))
    as "same boot id"

  assert identity.live_token(live) == token
}

pub fn property_pins_are_live_only_under_their_own_boot_test() {
  use #(a, b, serial) <- gen.check(gen.tuple3(
    gen.boot_id(),
    gen.boot_id(),
    gen.non_negative(),
  ))
  let assert Ok(token) = identity.pin(a, serial) as "valid pin"

  case identity.check_pin(token, b) {
    Ok(_) -> {
      assert identity.boot_id_text(a) == identity.boot_id_text(b)
    }
    Error(_) -> {
      assert identity.boot_id_text(a) != identity.boot_id_text(b)
    }
  }
}

pub fn os_process_identity_test() {
  let precise = OsProcess(7, PreciseStart("a"))

  assert identity.same_os_process(precise, precise) == Same
  assert identity.same_os_process(precise, OsProcess(8, PreciseStart("a")))
    == Different
  assert identity.same_os_process(precise, OsProcess(7, PreciseStart("b")))
    == Different
  assert identity.same_os_process(precise, OsProcess(7, UnreadableStart))
    == Indeterminate
  assert identity.same_os_process(OsProcess(7, UnreadableStart), precise)
    == Indeterminate
  assert identity.same_os_process(
      OsProcess(7, CoarseStart("x")),
      OsProcess(7, CoarseStart("x")),
    )
    == SameWithinCoarseResolution
  assert identity.same_os_process(
      OsProcess(7, CoarseStart("x")),
      OsProcess(7, PreciseStart("x")),
    )
    == Different
}

// A different pid is always a different process, whatever the start
// identity says, including when it cannot be read.
pub fn property_different_pids_differ_test() {
  use #(a, b) <- gen.check(gen.tuple2(gen.os_process(), gen.os_process()))

  case a.pid == b.pid {
    False -> {
      assert identity.same_os_process(a, b) == Different
    }
    True -> Nil
  }
}

pub fn display_text_test() {
  assert identity.display_text(identity.ProcessDisplay("<0.4112.0>", 18_204))
    == "<0.4112.0>@18204"
}
