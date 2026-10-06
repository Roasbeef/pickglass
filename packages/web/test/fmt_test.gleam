import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleeunit/should
import pickglass_core/measure.{Known, Missing, NotApplicable}
import pickglass_core/policy
import pickglass_core/unit
import pickglass_web/fmt
import pickglass_web/msg
import pickglass_web/wire
import qcheck

pub fn counts_get_separators_test() {
  fmt.count(3412) |> should.equal("3,412")
  fmt.count(1_048_576) |> should.equal("1,048,576")
  fmt.count(7) |> should.equal("7")
  fmt.count(-12_345) |> should.equal("−12,345")
}

// A count of words keeps its unit in the text, so it is never read as bytes or
// as a plain count.
pub fn words_are_written_as_words_test() {
  fmt.known(1_234_567, unit.Words) |> should.equal("1,234,567 words")
  fmt.cell(Known(0), unit.Words) |> should.equal("0 words")
  fmt.cell(Missing(measure.UnsupportedOnRuntime), unit.Words)
  |> should.not_equal("0 words")
}

pub fn bytes_use_binary_prefixes_and_magnitude_dependent_decimals_test() {
  fmt.bytes(512) |> should.equal("512 B")
  fmt.bytes(2048) |> should.equal("2.00 KiB")
  fmt.bytes(181 * 1_048_576) |> should.equal("181 MiB")
  fmt.bytes(50 * 1_048_576 + 524_288) |> should.equal("50.5 MiB")
}

pub fn a_known_zero_is_a_number_but_an_absent_value_is_a_word_test() {
  fmt.cell(Known(0), unit.Count) |> should.equal("0")
  fmt.cell(Missing(measure.CounterDisabled), unit.Count)
  |> should.equal("missing (counter_disabled)")
  fmt.cell(NotApplicable, unit.Bytes) |> should.equal("n/a")
}

pub fn changes_carry_a_sign_test() {
  fmt.signed(Known(2048), unit.Bytes) |> should.equal("+2.00 KiB")
  fmt.signed(Known(-2048), unit.Bytes) |> should.equal("−2.00 KiB")
  fmt.signed(Known(0), unit.Bytes) |> should.equal("0")

  // A ratio change below the first decimal keeps its direction and says it is
  // small, instead of printing "+<0.1%".
  fmt.signed(Known(3), unit.Ratio(per: 10_000))
  |> should.equal("up under 0.1%")
  fmt.signed(Known(-3), unit.Ratio(per: 10_000))
  |> should.equal("down under 0.1%")
  fmt.signed(Known(0), unit.Ratio(per: 10_000)) |> should.equal("0")
  fmt.signed(Known(30), unit.Ratio(per: 10_000)) |> should.equal("+0.3%")
  fmt.signed(Known(-30), unit.Ratio(per: 10_000))
  |> should.equal("−0.3%")
  fmt.signed(Missing(measure.DeadlineReached), unit.Bytes)
  |> should.equal("missing (deadline_reached)")
}

pub fn ratios_are_percentages_test() {
  fmt.ratio(30, 10_000) |> should.equal("0.3%")
  fmt.share(1, of: 0) |> should.equal("–")
}

pub fn durations_pick_a_readable_unit_test() {
  fmt.duration_ms(250) |> should.equal("250 ms")
  fmt.duration_ms(2000) |> should.equal("2.00 s")
  fmt.duration_ms(8_040_000) |> should.equal("2 h 14 min")
}

pub fn clock_is_the_utc_time_of_day_test() {
  fmt.clock(1_700_000_062_118) |> should.equal("22:14:22.118")
}

// An absent reading never renders as a bare number, whatever the unit.
pub fn absent_readings_never_render_as_numbers_test() {
  qcheck.run(
    qcheck.default_config(),
    qcheck.from_generators(qcheck.constant(unit.Bytes), [
      qcheck.constant(unit.Count),
      qcheck.constant(unit.Reductions),
      qcheck.constant(unit.Nanoseconds),
    ]),
    fn(u) {
      list.each(measure.all_missing_reasons, fn(reason) {
        fmt.cell(Missing(reason), u)
        |> string.contains("missing")
        |> should.be_true
      })
    },
  )
}

pub fn counts_round_trip_through_their_digits_test() {
  qcheck.run(
    qcheck.default_config(),
    qcheck.bounded_int(0, 2_000_000_000),
    fn(n) {
      fmt.count(n) |> string.replace(",", "") |> should.equal(string.inspect(n))
    },
  )
}

pub fn module_patterns_accept_exact_names_test() {
  wire.module_patterns("loom@runtime@keeper lists")
  |> should.equal(Ok(["loom@runtime@keeper", "lists"]))
  wire.module_patterns("a, b") |> should.equal(Ok(["a", "b"]))
}

// A trailing star is a prefix over the loaded modules and is accepted.
pub fn module_patterns_accept_a_trailing_prefix_test() {
  wire.module_patterns("runtime@*") |> should.equal(Ok(["runtime@*"]))
  wire.module_patterns("lists runtime@strand_*")
  |> should.equal(Ok(["lists", "runtime@strand_*"]))
}

// Any other star would be refused by the agent after the operator confirmed
// the plan, so the form refuses it first.
pub fn module_patterns_refuse_a_misplaced_wildcard_at_plan_time_test() {
  wire.module_patterns("runtime@**")
  |> should.equal(Error(wire.WildcardPattern("runtime@**")))
  wire.module_patterns("*lists")
  |> should.equal(Error(wire.WildcardPattern("*lists")))
  wire.module_patterns("lists a*b")
  |> should.equal(Error(wire.WildcardPattern("a*b")))
  wire.module_patterns("*") |> should.equal(Error(wire.WildcardPattern("*")))
}

pub fn module_patterns_refuse_everything_else_test() {
  wire.module_patterns("") |> should.equal(Error(wire.NoPatterns))
  wire.module_patterns("../etc")
  |> should.equal(Error(wire.BadPattern("../etc")))
  wire.module_patterns("a;b") |> should.equal(Error(wire.BadPattern("a;b")))
  wire.module_patterns(string.repeat("a ", 100))
  |> should.equal(Error(wire.TooManyPatterns))
}

fn target_value(value: String) -> Dynamic {
  let assert Ok(parsed) =
    json.parse("{\"target\":{\"value\":" <> value <> "}}", decode.dynamic)
    as "the forged event is valid json"

  parsed
}

pub fn text_longer_than_the_bound_is_refused_by_its_decoder_test() {
  let long = "\"" <> string.repeat("x", wire.max_text + 1) <> "\""
  let ok = "\"" <> string.repeat("x", wire.max_text) <> "\""

  decode.run(target_value(long), wire.text_decoder())
  |> result.is_error
  |> should.be_true

  decode.run(target_value(ok), wire.text_decoder())
  |> result.is_ok
  |> should.be_true
}

pub fn the_key_decoder_is_total_over_odd_json_test() {
  list.each(["7", "null", "[]", "{}", "\"a\\tb\"", "\"\""], fn(value) {
    decode.run(target_value(value), wire.key_decoder())
    |> result.is_error
    |> should.be_true
  })

  decode.run(target_value("\"row.1\""), wire.key_decoder())
  |> result.is_ok
  |> should.be_true
}

pub fn the_code_decoder_refuses_unknown_codes_test() {
  decode.run(
    target_value("\"launch_missiles\""),
    wire.code_decoder(msg.parse_probe, policy.Counters),
  )
  |> result.is_error
  |> should.be_true

  decode.run(
    target_value("\"sampling\""),
    wire.code_decoder(msg.parse_probe, policy.Counters),
  )
  |> should.equal(Ok(policy.Sampling))
}
