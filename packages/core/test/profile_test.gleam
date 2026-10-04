import fixtures
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pickglass_core/profile.{
  Exact, Function, FunctionLevel, NoLine, Sample, ValueType,
}
import pickglass_core/profile/codec
import pickglass_core/unit

fn function(id: Int) -> profile.Function {
  Function(
    id: id,
    module: "loom@strand_runtime",
    name: "step",
    arity: 4,
    file: Some("src/loom/strand_runtime.gleam"),
    line: Some(118),
    precision: FunctionLevel,
  )
}

pub fn new_refuses_inconsistent_profiles_test() {
  let types = [ValueType("samples", unit.Count)]
  let source = profile.TracedCalls

  assert profile.new(source, [], [], []) == Error(profile.NoValueTypes)

  assert profile.new(source, types, [function(1), function(1)], [])
    == Error(profile.DuplicateFunction(1))

  assert profile.new(source, types, [function(1)], [
      Sample(frames: [], values: [1], labels: []),
    ])
    == Error(profile.EmptyStack(0))

  assert profile.new(source, types, [function(1)], [
      Sample(frames: [1], values: [1], labels: []),
      Sample(frames: [1, 7], values: [1], labels: []),
    ])
    == Error(profile.UnknownFunction(1, 7))

  assert profile.new(source, types, [function(1)], [
      Sample(frames: [1], values: [1, 2], labels: []),
    ])
    == Error(profile.ValueCountMismatch(0, 1, 2))
}

pub fn totals_sum_absolute_values_test() {
  let p = fixtures.calls([#(["a"], 5), #(["b"], -3)])
  assert profile.total(p, fixtures.column(p)) == 8
}

// When any sample is labelled as the base of a diff, only those samples
// make up the total, so percentages are relative to the base.
pub fn base_label_restricts_the_total_test() {
  let p =
    fixtures.labelled([
      #(["a"], 10, []),
      #(["a"], -4, [profile.base_label]),
      #(["b"], -6, [profile.base_label]),
    ])
  assert profile.total(p, fixtures.column(p)) == 10
}

pub fn package_of_gleam_modules_test() {
  assert profile.package_of("loom@provider@gateway") == "loom"
  assert profile.package_of("lists") == "lists"
  assert profile.function_name(function(1)) == "loom@strand_runtime:step/4"
}

pub fn columns_are_checked_against_the_profile_test() {
  let p = fixtures.calls([#(["a"], 1)])
  assert profile.column(p, 0) != Error(Nil)
  assert profile.column(p, 1) == Error(Nil)
  assert profile.column(p, -1) == Error(Nil)
  assert profile.column_named(p, "samples") != Error(Nil)
  assert profile.column_named(p, "nope") == Error(Nil)
}

pub fn shape_follows_the_source_test() {
  assert profile.shape(profile.TracedCounters) == profile.FunctionTotals
  assert profile.shape(profile.AllocationCounts) == profile.FunctionTotals
  assert profile.shape(profile.TracedCalls) == profile.CallStacks
  assert profile.shape(profile.SampledStacks("x", 1)) == profile.CallStacks
}

fn round_trip(p: profile.Profile) -> Result(profile.Profile, json.DecodeError) {
  codec.encode(p) |> json.to_string |> json.parse(codec.decoder())
}

pub fn codec_round_trips_a_rich_profile_test() {
  let assert Ok(p) =
    profile.new(
      profile.SampledStacks("polled_stacks", 50),
      [ValueType("samples", unit.Count), ValueType("time", unit.Nanoseconds)],
      [
        function(1),
        Function(
          id: 2,
          module: "lists",
          name: "map",
          arity: 2,
          file: None,
          line: None,
          precision: NoLine,
        ),
        Function(
          id: 3,
          module: "m",
          name: "exact",
          arity: 0,
          file: Some("src/m.gleam"),
          line: Some(3),
          precision: Exact,
        ),
      ],
      [
        Sample(frames: [2, 1], values: [3, 3000], labels: [#("session", "s1")]),
        Sample(frames: [3, 1], values: [1, 10], labels: []),
        Sample(frames: [2, 1], values: [2, 20], labels: [
          #("session", "s2"),
          #("role", "keeper"),
        ]),
      ],
    )
  assert round_trip(p) == Ok(p)
}

pub fn codec_writes_a_shared_stack_once_test() {
  let p = fixtures.calls([#(["a", "b"], 1), #(["a", "b"], 2), #(["a"], 3)])
  let text = codec.encode(p) |> json.to_string
  let assert Ok(back) = json.parse(text, codec.decoder())
  assert back == p
  assert list.length(profile.samples(back)) == 3
}

// Equal profiles encode to equal text, which a capture's footer hash needs.
pub fn encoding_is_deterministic_test() {
  let p = fixtures.calls([#(["a", "b"], 1), #(["c"], 2)])
  assert json.to_string(codec.encode(p)) == json.to_string(codec.encode(p))
}

pub fn codec_round_trips_random_profiles_test() {
  check_random(1, 60)
}

fn check_random(seed: Int, remaining: Int) -> Nil {
  case remaining {
    0 -> Nil
    _ -> {
      let #(p, seed) = fixtures.random_calls(seed, 8, 12, 6)
      assert round_trip(p) == Ok(p)
      check_random(seed, remaining - 1)
    }
  }
}

fn decodes(text: String) -> Bool {
  case json.parse(text, codec.decoder()) {
    Ok(_) -> True
    Error(_) -> False
  }
}

const valid: String =
  "{\"source\":{\"kind\":\"traced_calls\"},\"value_types\":[{\"name\":\"t\",\"unit\":\"nanoseconds\"}],\"functions\":[{\"id\":0,\"module\":\"m\",\"function\":\"f\",\"arity\":0,\"precision\":\"none\"}],\"stacks\":[{\"id\":0,\"frames\":[0]}],\"rows\":[{\"stack\":0,\"values\":[5],\"labels\":[]}]}"

pub fn decoder_accepts_the_minimal_form_test() {
  assert decodes(valid)
}

// Every way a capture can be wrong must be refused, never repaired.
pub fn decoder_refuses_bad_input_test() {
  assert !decodes("")
  assert !decodes("[]")
  assert !decodes("{}")
  assert !decodes("not json at all")
  assert !decodes("{\"source\":")
}

pub fn decoder_refuses_a_bad_field_test() {
  let replace = fn(from: String, to: String) {
    json.parse(string.replace(valid, from, to), codec.decoder())
  }
  assert replace("nanoseconds", "words") |> is_error
  assert replace("traced_calls", "psychic") |> is_error
  assert replace("\"precision\":\"none\"", "\"precision\":\"vague\"")
    |> is_error
  assert replace("\"stack\":0", "\"stack\":9") |> is_error
  assert replace("\"frames\":[0]", "\"frames\":[4]") |> is_error
  assert replace("\"frames\":[0]", "\"frames\":[]") |> is_error
  assert replace("\"values\":[5]", "\"values\":[5,6]") |> is_error
  assert replace("\"labels\":[]", "\"labels\":[[\"k\"]]") |> is_error
  assert replace(
      "\"value_types\":[{\"name\":\"t\",\"unit\":\"nanoseconds\"}]",
      "\"value_types\":[]",
    )
    |> is_error
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
