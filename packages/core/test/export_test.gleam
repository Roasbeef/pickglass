import fixtures
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import pickglass_core/export
import pickglass_core/export/chrome_trace.{Counter, Instant, Slice, Track}
import pickglass_core/export/collapsed
import pickglass_core/export/speedscope
import pickglass_core/profile
import pickglass_core/unit

fn small() -> profile.Profile {
  fixtures.calls([#(["a", "b"], 5), #(["a", "c"], 3), #(["a"], 2)])
}

// The collapsed text for a known profile, byte for byte. Lines are sorted,
// and a stack that is a prefix of another sorts before it.
pub fn collapsed_stacks_match_an_exact_string_test() {
  let p = small()
  let assert Ok(result) = collapsed.export(p, fixtures.column(p))
  assert result.body == "m:a/0 2\nm:a/0;m:b/0 5\nm:a/0;m:c/0 3\n"
}

pub fn collapsed_merges_identical_stacks_test() {
  let p = fixtures.calls([#(["a", "b"], 5), #(["a", "b"], 4)])
  let assert Ok(result) = collapsed.export(p, fixtures.column(p))
  assert result.body == "m:a/0;m:b/0 9\n"
}

pub fn collapsed_drops_stacks_that_cancel_test() {
  let p = fixtures.calls([#(["a"], 5), #(["a"], -5), #(["b"], 1)])
  let assert Ok(result) = collapsed.export(p, fixtures.column(p))
  assert result.body == "m:b/0 1\n"
}

pub fn collapsed_of_nothing_is_empty_test() {
  let p = fixtures.calls([])
  let assert Ok(result) = collapsed.export(p, fixtures.column(p))
  assert result.body == ""
}

// A semicolon in a function name would split a frame in two.
pub fn collapsed_escapes_separators_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCalls,
      [profile.ValueType("n", unit.Count)],
      [
        profile.Function(
          0,
          "m",
          "odd;name",
          0,
          option.None,
          option.None,
          profile.NoLine,
        ),
      ],
      [profile.Sample([0], [1], [])],
    )
  let assert Ok(column) = profile.column(p, 0)
  let assert Ok(result) = collapsed.export(p, column)
  assert result.body == "m:odd,name/0 1\n"
}

pub fn exports_carry_a_loss_list_test() {
  let p = small()
  let assert Ok(c) = collapsed.export(p, fixtures.column(p))
  assert c.losses != []
  assert list.any(c.losses, fn(l) { l == "Units: values are bare numbers." })
  let assert Ok(s) = speedscope.export(p)
  assert list.any(s.losses, fn(l) {
    l == "Coverage and truncation: whether the profile is complete."
  })
  assert chrome_trace.export("x", []).losses != []
  assert export.loss_text(["one", "two"])
    == "This export does not carry:\n- one\n- two\n"
}

pub fn stackless_sources_cannot_export_stacks_test() {
  let assert Ok(p) =
    profile.new(
      profile.AllocationCounts,
      [profile.ValueType("words", unit.Bytes)],
      [],
      [],
    )
  let assert Ok(column) = profile.column(p, 0)
  assert collapsed.export(p, column)
    == Error(export.NoCallStacks(profile.AllocationCounts))
  assert speedscope.export(p)
    == Error(export.NoCallStacks(profile.AllocationCounts))
}

// ------------------------------------------------------------- speedscope

type Scope {
  Scope(frames: Int, profiles: List(ScopeProfile))
}

type ScopeProfile {
  ScopeProfile(
    kind: String,
    unit: String,
    samples: List(List(Int)),
    weights: List(Int),
    end: Int,
  )
}

fn scope_decoder() -> decode.Decoder(Scope) {
  use frames <- decode.subfield(
    ["shared", "frames"],
    decode.list(decode.at(["name"], decode.string)),
  )
  use profiles <- decode.field("profiles", decode.list(profile_decoder()))
  decode.success(Scope(frames: list.length(frames), profiles: profiles))
}

fn profile_decoder() -> decode.Decoder(ScopeProfile) {
  use kind <- decode.field("type", decode.string)
  use unit <- decode.field("unit", decode.string)
  use samples <- decode.field("samples", decode.list(decode.list(decode.int)))
  use weights <- decode.field("weights", decode.list(decode.int))
  use end <- decode.field("endValue", decode.int)
  decode.success(ScopeProfile(kind:, unit:, samples:, weights:, end:))
}

pub fn speedscope_json_parses_with_the_right_frame_count_test() {
  let p = small()
  let assert Ok(result) = speedscope.export(p)
  let assert Ok(scope) = json.parse(result.body, scope_decoder())
  assert scope.frames == 3
  let assert [only] = scope.profiles
  assert only.kind == "sampled"
  assert only.unit == "none"
  assert only.end == 10
  assert list.length(only.samples) == list.length(only.weights)
  assert only.weights == [2, 5, 3]
}

// Samples are root first, as indices into the frame table.
pub fn speedscope_stacks_are_root_first_test() {
  let p = fixtures.calls([#(["a", "b", "c"], 4)])
  let assert Ok(result) = speedscope.export(p)
  let assert Ok(scope) = json.parse(result.body, scope_decoder())
  let assert [only] = scope.profiles
  let a = fixtures.id(p, "a")
  let b = fixtures.id(p, "b")
  let c = fixtures.id(p, "c")
  assert only.samples == [[a, b, c]]
}

pub fn speedscope_writes_one_profile_per_value_type_test() {
  let assert Ok(p) =
    profile.new(
      profile.SampledStacks("polled", 50),
      [
        profile.ValueType("samples", unit.Count),
        profile.ValueType("time", unit.Nanoseconds),
        profile.ValueType("alloc", unit.Bytes),
      ],
      [
        profile.Function(
          0,
          "m",
          "a",
          0,
          Some("src/m.gleam"),
          Some(3),
          profile.Exact,
        ),
      ],
      [profile.Sample([0], [1, 20, 300], [])],
    )
  let assert Ok(result) = speedscope.export(p)
  let assert Ok(scope) = json.parse(result.body, scope_decoder())
  assert list.map(scope.profiles, fn(s) { s.unit })
    == ["none", "nanoseconds", "bytes"]
  assert list.map(scope.profiles, fn(s) { s.weights }) == [[1], [20], [300]]
  assert scope.frames == 1
}

pub fn speedscope_keeps_source_locations_test() {
  let assert Ok(p) =
    profile.new(
      profile.TracedCalls,
      [profile.ValueType("n", unit.Count)],
      [
        profile.Function(
          0,
          "m",
          "a",
          0,
          Some("src/m.gleam"),
          Some(3),
          profile.Exact,
        ),
      ],
      [profile.Sample([0], [1], [])],
    )
  let assert Ok(result) = speedscope.export(p)
  let assert Ok(located) =
    json.parse(
      result.body,
      decode.subfield(
        ["shared", "frames"],
        decode.list({
          use file <- decode.field("file", decode.string)
          use line <- decode.field("line", decode.int)
          decode.success(#(file, line))
        }),
        decode.success,
      ),
    )
  assert located == [#("src/m.gleam", 3)]
}

// ------------------------------------------------------------ chrome trace

pub fn chrome_trace_writes_slices_counters_and_instants_test() {
  let result =
    chrome_trace.export("loomd", [
      Track(1, "ops", [
        Slice("provider call", 1500, 2000, [#("session", "s1")]),
        Instant("gap", 4000, []),
      ]),
      Track(2, "heap", [Counter("heap", 1000, [#("bytes", 4096)])]),
    ])
  let event = {
    use ph <- decode.field("ph", decode.string)
    use name <- decode.field("name", decode.string)
    use ts <- decode.optional_field("ts", 0.0, decode.float)
    decode.success(#(ph, name, ts))
  }
  let assert Ok(events) =
    json.parse(
      result.body,
      decode.field("traceEvents", decode.list(event), decode.success),
    )
  assert events
    == [
      #("M", "process_name", 0.0),
      #("M", "thread_name", 0.0),
      #("M", "thread_name", 0.0),
      #("X", "provider call", 1.5),
      #("i", "gap", 4.0),
      #("C", "heap", 1.0),
    ]
}

pub fn chrome_trace_slice_has_a_duration_in_microseconds_test() {
  let result =
    chrome_trace.export("p", [Track(7, "t", [Slice("s", 0, 2500, [])])])
  let dur = {
    use events <- decode.field(
      "traceEvents",
      decode.list(decode.optional_field(
        "dur",
        0.0,
        decode.float,
        decode.success,
      )),
    )
    decode.success(events)
  }
  let assert Ok(durations) = json.parse(result.body, dur)
  assert list.contains(durations, 2.5)
}

pub fn chrome_trace_is_deterministic_test() {
  let tracks = [Track(1, "a", [Instant("i", 1, [])])]
  assert chrome_trace.export("p", tracks) == chrome_trace.export("p", tracks)
}
