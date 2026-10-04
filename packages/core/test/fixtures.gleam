//// Hand-built profiles and a tiny deterministic random source for the tests.
////
//// Stacks are written root first, the way a reader draws them, and turned
//// into the leaf-first frame lists the model uses. Functions are named by a
//// bare string and live in the module `m` with arity zero, so `"a"` prints
//// as `m:a/0`. The random source is a linear congruential generator, so a
//// property test explores the same cases on every run.

import gleam/dict
import gleam/list
import gleam/option.{None}
import pickglass_core/profile.{type Profile}
import pickglass_core/unit

/// Build a one-column profile from `#(root_first_names, value)` stacks.
pub fn calls(stacks: List(#(List(String), Int))) -> Profile {
  labelled(list.map(stacks, fn(stack) { #(stack.0, stack.1, []) }))
}

/// Like `calls`, with labels on each stack.
pub fn labelled(
  stacks: List(#(List(String), Int, List(#(String, String)))),
) -> Profile {
  let names =
    stacks
    |> list.flat_map(fn(stack) { stack.0 })
    |> list.unique
  let ids =
    names
    |> list.index_map(fn(name, id) { #(name, id) })
    |> dict.from_list
  let functions =
    list.index_map(names, fn(name, id) {
      profile.Function(
        id: id,
        module: "m",
        name: name,
        arity: 0,
        file: None,
        line: None,
        precision: profile.NoLine,
      )
    })
  let samples =
    list.map(stacks, fn(stack) {
      let frames =
        stack.0
        |> list.reverse
        |> list.map(fn(name) {
          let assert Ok(id) = dict.get(ids, name)
          id
        })
      profile.Sample(frames: frames, values: [stack.1], labels: stack.2)
    })
  let assert Ok(built) =
    profile.new(
      profile.SampledStacks("test", 100),
      [profile.ValueType("samples", unit.Count)],
      functions,
      samples,
    )
  built
}

/// The only column of a one-column profile.
pub fn column(p: Profile) -> profile.Column {
  let assert Ok(column) = profile.column(p, 0)
  column
}

/// The id of the function with this bare name.
pub fn id(p: Profile, name: String) -> Int {
  let assert Ok(function) =
    list.find(profile.functions(p), fn(function) { function.name == name })
  function.id
}

/// The next value of the generator.
pub fn next(seed: Int) -> Int {
  { seed * 1_103_515_245 + 12_345 } % 2_147_483_648
}

/// A number below `bound` and the next seed. High bits are used because the
/// low bits of this generator have short periods.
pub fn below(seed: Int, bound: Int) -> #(Int, Int) {
  let following = next(seed)
  #(following / 65_536 % bound, following)
}

/// A random profile with up to `functions` distinct function names, up to
/// `stacks` stacks of depth up to `depth`, and values from 1 to 20.
pub fn random_calls(
  seed: Int,
  functions: Int,
  stacks: Int,
  depth: Int,
) -> #(Profile, Int) {
  let #(count, seed) = below(seed, stacks)
  let #(built, seed) =
    list.fold(list.repeat(Nil, count + 1), #([], seed), fn(state, _) {
      let #(acc, seed) = state
      let #(length, seed) = below(seed, depth)
      let #(names, seed) = random_names(seed, length + 1, functions, [])
      let #(value, seed) = below(seed, 20)
      #([#(names, value + 1), ..acc], seed)
    })
  #(calls(built), seed)
}

fn random_names(
  seed: Int,
  length: Int,
  functions: Int,
  acc: List(String),
) -> #(List(String), Int) {
  case length {
    0 -> #(acc, seed)
    _ -> {
      let #(pick, seed) = below(seed, functions)
      random_names(seed, length - 1, functions, [name(pick), ..acc])
    }
  }
}

fn name(number: Int) -> String {
  "f" <> int_text(number)
}

fn int_text(number: Int) -> String {
  case number {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    _ -> int_text(number / 10) <> int_text(number % 10)
  }
}

/// The integers from `from` through `to`, empty when `to` is smaller.
pub fn span(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..span(from + 1, to)]
  }
}
