//// speedscope JSON, the file format of the speedscope viewer.
////
//// Speedscope's "sampled" profile type is a list of stacks (as indices into
//// a shared frame table, root first) with a weight for each. The export
//// writes one speedscope profile per value type of the profile, so the
//// viewer's profile switcher selects the column. Frames carry the Gleam
//// file and line when the function table has them.
////
//// Speedscope knows a few units. Bytes and nanoseconds map to the
//// equivalents; counts, reductions and ratios are written as `none`, and
//// the profile's name carries the real unit so it is not lost on screen.
//// Stacks whose total is zero or negative are left out, since speedscope
//// weights are non-negative.
////
//// ## Flow
////
//// `export` builds the frame table once with `encode_frame`, then one
//// profile object per column from the profile's merged stacks with
//// `encode_profile`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option
import pickglass_core/export.{type Export, type ExportError, Export}
import pickglass_core/profile.{
  type Column, type Function, type Profile, type ValueType,
}
import pickglass_core/unit

/// Write a profile as speedscope JSON, one speedscope profile per column.
///
/// ## Examples
///
/// ```gleam
/// speedscope.export(p)
/// ```
pub fn export(profile: Profile) -> Result(Export, ExportError) {
  case profile.shape(profile.source(profile)) {
    profile.FunctionTotals ->
      Error(export.NoCallStacks(profile.source(profile)))
    profile.CallStacks -> {
      let functions = profile.functions(profile)
      let index =
        functions
        |> list.index_map(fn(function, position) { #(function.id, position) })
        |> dict.from_list
      let value_types = profile.value_types(profile)
      let profiles =
        list.map2(profile.columns(profile), value_types, fn(column, value_type) {
          encode_profile(profile, column, value_type, index)
        })
      let document =
        json.object([
          #(
            "$schema",
            json.string("https://www.speedscope.app/file-format-schema.json"),
          ),
          #(
            "shared",
            json.object([
              #("frames", json.array(functions, encode_frame)),
            ]),
          ),
          #("profiles", json.array(profiles, fn(entry) { entry })),
          #("name", json.string("pickglass profile")),
          #("activeProfileIndex", json.int(0)),
          #("exporter", json.string("pickglass")),
        ])
      Ok(Export(body: json.to_string(document), losses: losses(value_types)))
    }
  }
}

fn encode_frame(function: Function) -> Json {
  let location = case function.file, function.line {
    option.Some(file), option.Some(line) -> [
      #("file", json.string(file)),
      #("line", json.int(line)),
    ]
    option.Some(file), option.None -> [#("file", json.string(file))]
    option.None, _ -> []
  }
  json.object([
    #("name", json.string(profile.function_name(function))),
    ..location
  ])
}

fn encode_profile(
  profile: Profile,
  column: Column,
  value_type: ValueType,
  index: Dict(Int, Int),
) -> Json {
  let stacks =
    profile.merged_stacks(profile, column)
    |> list.filter(fn(stack) { stack.1 > 0 })
  let samples =
    list.map(stacks, fn(stack) {
      stack.0
      |> list.reverse
      |> list.filter_map(fn(id) { dict.get(index, id) })
    })
  let weights = list.map(stacks, fn(stack) { stack.1 })
  json.object([
    #("type", json.string("sampled")),
    #(
      "name",
      json.string(
        value_type.name <> " (" <> unit.to_string(value_type.unit) <> ")",
      ),
    ),
    #("unit", json.string(speedscope_unit(value_type))),
    #("startValue", json.int(0)),
    #("endValue", json.int(int.sum(weights))),
    #(
      "samples",
      json.array(samples, fn(frames) { json.array(frames, json.int) }),
    ),
    #("weights", json.array(weights, json.int)),
  ])
}

fn speedscope_unit(value_type: ValueType) -> String {
  case value_type.unit {
    unit.Bytes -> "bytes"
    unit.Nanoseconds -> "nanoseconds"
    unit.Count | unit.Reductions | unit.Words | unit.Ratio(_) -> "none"
  }
}

/// What this format leaves out for a profile with these value types.
pub fn losses(value_types: List(ValueType)) -> List(String) {
  let unmapped =
    list.filter(value_types, fn(value_type) {
      speedscope_unit(value_type) == "none"
    })
  let base = [
    "Coverage and truncation: whether the profile is complete.",
    "Owner labels: which session or strand a sample belongs to.",
    "Provenance: when, where and how the profile was taken.",
    "Line precision: lines are written whether exact or function level.",
    "Stacks whose total is zero or negative.",
  ]
  case unmapped {
    [] -> base
    _ -> [
      "Units: counts, reductions and ratios are written as `none`; the unit is in the profile name only.",
      ..base
    ]
  }
}
