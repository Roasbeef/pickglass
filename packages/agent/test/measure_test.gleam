import pickglass_agent/internal/ffi_term.{coerce}
import pickglass_agent/measure

@external(erlang, "erlang", "++")
fn append(front: List(Int), back: Int) -> Int

// A reply is a short list of named integers with a known unit, and nothing
// else.
pub fn well_formed_readings_are_valid_test() {
  assert measure.valid_readings(coerce([]))
  assert measure.valid_readings(
    coerce([#("callback", 120, "words"), #("queued", 3, "count")]),
  )
  assert measure.valid_readings(coerce([#("heap", 4096, "bytes")]))
}

// One bad reading makes the whole reply invalid: a name that is not
// printable ASCII, a value that is not an integer, a unit outside the three,
// or a tuple of the wrong size.
pub fn malformed_readings_are_invalid_test() {
  assert !measure.valid_readings(coerce(7))
  assert !measure.valid_readings(
    coerce([coerce(#("ok", 1, "words")), coerce(#("x", "1", "words"))]),
  )
  assert !measure.valid_readings(coerce([#("bad\nname", 1, "words")]))
  assert !measure.valid_readings(coerce([#("", 1, "words")]))
  assert !measure.valid_readings(coerce([#("x", 1, "furlongs")]))
  assert !measure.valid_readings(coerce([#("x", 1)]))
  assert !measure.valid_readings(coerce([7]))
}

// The count and the name length are bounded, and an improper list is refused
// without being walked.
pub fn readings_are_bounded_test() {
  let one = #("n", 1, "count")
  let many = [
    one, one, one, one, one, one, one, one, one, one, one, one, one, one, one,
    one, one, one, one, one, one, one, one, one, one, one, one, one, one, one,
    one, one,
  ]
  let long_name =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let improper: ffi_term.Term = coerce(append([1], 2))

  assert measure.valid_readings(coerce(many))
  assert !measure.valid_readings(coerce([one, ..many]))
  assert !measure.valid_readings(coerce([#(long_name, 1, "count")]))
  assert !measure.valid_readings(improper)
}
