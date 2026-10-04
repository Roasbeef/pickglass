//// The JSON form of a profile, as a capture file carries it.
////
//// A capture's `profile` record holds a stack table and the samples that
//// refer to it, so that a stack shared by many samples is written once.
//// This module writes that shape and reads it back. The decoder is total:
//// text that is not a profile, a unit this build does not know, a sample
//// naming a stack that is not in the table, or any rule `profile.new`
//// enforces is a decode failure that names what was expected, never a
//// guessed value.
////
//// The record is an object with five keys: `source`, `value_types`,
//// `functions`, `stacks` and `rows`. Each row is
//// `{"stack": id, "values": [...], "labels": [[key, value], ...]}`. Stack
//// ids are assigned by `encode` in order of first use, so the same profile
//// always encodes to the same text.
////
//// ## Flow
////
//// `encode` calls `intern_stacks` to build the table, then writes each
//// part. `decoder` reads the parts, calls `resolve_rows` to look each
//// row's stack id up in the table, and hands the result to `profile.new`.

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/option
import pickglass_core/profile.{
  type Function, type LinePrecision, type Profile, type Sample, type Source,
  type ValueType,
}
import pickglass_core/unit

/// Encode a profile as the JSON value of a capture's `profile` record.
///
/// ## Examples
///
/// ```gleam
/// codec.encode(p) |> json.to_string
/// ```
pub fn encode(profile: Profile) -> Json {
  let #(table, rows) = intern_stacks(profile.samples(profile))
  json.object([
    #("source", encode_source(profile.source(profile))),
    #(
      "value_types",
      json.array(profile.value_types(profile), encode_value_type),
    ),
    #("functions", json.array(profile.functions(profile), encode_function)),
    #("stacks", json.array(table, encode_stack)),
    #("rows", json.array(rows, encode_row)),
  ])
}

// Assign each distinct frame list an id in order of first appearance and
// return the table, in id order, with the samples rewritten to ids.
fn intern_stacks(
  samples: List(Sample),
) -> #(List(#(Int, List(Int))), List(#(Int, Sample))) {
  let #(_, table, rows) =
    list.fold(samples, #(dict.new(), [], []), fn(state, sample) {
      let #(ids, table, rows) = state
      case dict.get(ids, sample.frames) {
        Ok(id) -> #(ids, table, [#(id, sample), ..rows])
        Error(Nil) -> {
          let id = dict.size(ids)
          #(
            dict.insert(ids, sample.frames, id),
            [#(id, sample.frames), ..table],
            [#(id, sample), ..rows],
          )
        }
      }
    })
  #(list.reverse(table), list.reverse(rows))
}

fn encode_source(source: Source) -> Json {
  case source {
    profile.SampledStacks(method:, rate:) ->
      json.object([
        #("kind", json.string("sampled_stacks")),
        #("method", json.string(method)),
        #("rate", json.int(rate)),
      ])
    profile.TracedCalls -> json.object([#("kind", json.string("traced_calls"))])
    profile.TracedCounters ->
      json.object([#("kind", json.string("traced_counters"))])
    profile.AllocationCounts ->
      json.object([#("kind", json.string("allocation_counts"))])
  }
}

fn encode_value_type(value_type: ValueType) -> Json {
  json.object([
    #("name", json.string(value_type.name)),
    #("unit", json.string(unit.to_string(value_type.unit))),
  ])
}

fn encode_function(function: Function) -> Json {
  json.object([
    #("id", json.int(function.id)),
    #("module", json.string(function.module)),
    #("function", json.string(function.name)),
    #("arity", json.int(function.arity)),
    #("file", json.nullable(function.file, json.string)),
    #("line", json.nullable(function.line, json.int)),
    #("precision", json.string(precision_name(function.precision))),
  ])
}

fn precision_name(precision: LinePrecision) -> String {
  case precision {
    profile.Exact -> "exact"
    profile.FunctionLevel -> "function_level"
    profile.NoLine -> "none"
  }
}

fn encode_stack(entry: #(Int, List(Int))) -> Json {
  json.object([
    #("id", json.int(entry.0)),
    #("frames", json.array(entry.1, json.int)),
  ])
}

fn encode_row(row: #(Int, Sample)) -> Json {
  let #(stack, sample) = row
  json.object([
    #("stack", json.int(stack)),
    #("values", json.array(sample.values, json.int)),
    #(
      "labels",
      json.array(sample.labels, fn(label) {
        json.array([label.0, label.1], json.string)
      }),
    ),
  ])
}

/// A total decoder for the JSON value `encode` writes.
///
/// ## Examples
///
/// ```gleam
/// json.parse(text, codec.decoder())
/// ```
pub fn decoder() -> Decoder(Profile) {
  use source <- decode.field("source", source_decoder())
  use value_types <- decode.field(
    "value_types",
    decode.list(value_type_decoder()),
  )
  use functions <- decode.field("functions", decode.list(function_decoder()))
  use stacks <- decode.field("stacks", decode.list(stack_decoder()))
  use rows <- decode.field("rows", decode.list(row_decoder()))
  let table = dict.from_list(stacks)
  case resolve_rows(rows, table, []) {
    Error(Nil) -> decode.failure(profile.empty(), "a row naming a known stack")
    Ok(samples) ->
      case profile.new(source, value_types, functions, samples) {
        Ok(built) -> decode.success(built)
        Error(_) -> decode.failure(profile.empty(), "a consistent profile")
      }
  }
}

// A row names its stack by id; the sample needs the frames.
fn resolve_rows(
  rows: List(#(Int, List(Int), List(#(String, String)))),
  table: Dict(Int, List(Int)),
  acc: List(Sample),
) -> Result(List(Sample), Nil) {
  case rows {
    [] -> Ok(list.reverse(acc))
    [#(stack, values, labels), ..rest] ->
      case dict.get(table, stack) {
        Ok(frames) ->
          resolve_rows(rest, table, [
            profile.Sample(frames:, values:, labels:),
            ..acc
          ])
        Error(Nil) -> Error(Nil)
      }
  }
}

fn source_decoder() -> Decoder(Source) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "sampled_stacks" -> {
      use method <- decode.field("method", decode.string)
      use rate <- decode.field("rate", decode.int)
      decode.success(profile.SampledStacks(method:, rate:))
    }
    "traced_calls" -> decode.success(profile.TracedCalls)
    "traced_counters" -> decode.success(profile.TracedCounters)
    "allocation_counts" -> decode.success(profile.AllocationCounts)
    _ -> decode.failure(profile.TracedCalls, "a known profile source")
  }
}

fn value_type_decoder() -> Decoder(ValueType) {
  use name <- decode.field("name", decode.string)
  use unit_name <- decode.field("unit", decode.string)
  case unit.parse(unit_name) {
    Ok(parsed) -> decode.success(profile.ValueType(name:, unit: parsed))
    Error(Nil) ->
      decode.failure(profile.ValueType(name:, unit: unit.Count), "a known unit")
  }
}

fn function_decoder() -> Decoder(Function) {
  use id <- decode.field("id", decode.int)
  use module <- decode.field("module", decode.string)
  use name <- decode.field("function", decode.string)
  use arity <- decode.field("arity", decode.int)
  use file <- decode.optional_field(
    "file",
    option.None,
    decode.optional(decode.string),
  )
  use line <- decode.optional_field(
    "line",
    option.None,
    decode.optional(decode.int),
  )
  use precision_name <- decode.field("precision", decode.string)
  let function = fn(precision) {
    profile.Function(id:, module:, name:, arity:, file:, line:, precision:)
  }
  case precision_name {
    "exact" -> decode.success(function(profile.Exact))
    "function_level" -> decode.success(function(profile.FunctionLevel))
    "none" -> decode.success(function(profile.NoLine))
    _ -> decode.failure(function(profile.NoLine), "a known line precision")
  }
}

fn stack_decoder() -> Decoder(#(Int, List(Int))) {
  use id <- decode.field("id", decode.int)
  use frames <- decode.field("frames", decode.list(decode.int))
  decode.success(#(id, frames))
}

fn row_decoder() -> Decoder(#(Int, List(Int), List(#(String, String)))) {
  use stack <- decode.field("stack", decode.int)
  use values <- decode.field("values", decode.list(decode.int))
  use labels <- decode.field("labels", decode.list(label_decoder()))
  decode.success(#(stack, values, labels))
}

fn label_decoder() -> Decoder(#(String, String)) {
  use pair <- decode.then(decode.list(decode.string))
  case pair {
    [key, value] -> decode.success(#(key, value))
    _ -> decode.failure(#("", ""), "a [key, value] label pair")
  }
}
