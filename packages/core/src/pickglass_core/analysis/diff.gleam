//// Differential profiles: a candidate compared with a base.
////
//// pprof's `-diff_base` does not compute a per-function difference. It
//// negates every sample of the base, optionally scales the candidate so
//// both have the same total, and merges the two sample sets into one
//// profile, in which samples with the same stack add. A stack present
//// equally in both cancels to zero and is gone; a stack that grew has a
//// positive value, a stack that shrank a negative one. Every analysis then
//// runs on that one profile and needs no special case, because it already
//// handles negative values.
////
//// Two details matter for reading the result. The base samples are labelled
//// with `profile.base_label`, and `profile.total` counts only labelled
//// samples when any exist, so percentages are relative to the base, as in
//// pprof. And functions are matched by their printable name
//// (`module:name/arity`), not by id, because the two profiles were
//// captured separately and their function tables number functions
//// independently.
////
//// This module does not decide whether the two profiles may be compared.
//// pprof checks only that the value types agree, and so does this module;
//// whether the builds and workloads match is the provenance check's job.
////
//// ## Flow
////
//// `merge` checks the value types agree, calls `unify` to build one
//// function table that holds both profiles' functions, calls `scales` for
//// the normalising factors, applies them with `scale_values`, negates the
//// base, and concatenates the samples.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import pickglass_core/profile.{
  type BuildError, type Function, type Profile, type Sample, type ValueType,
}

/// Whether the candidate is scaled to the base's total.
pub type Normalize {
  /// Compare raw values.
  Unnormalized

  /// Scale the candidate, per value type, by the base's total over the
  /// candidate's, so a longer or shorter run does not look like a change.
  Normalized
}

/// Why two profiles could not be merged.
pub type DiffError {
  /// The profiles' value types differ in count, name or unit.
  IncompatibleValueTypes(base: List(ValueType), candidate: List(ValueType))

  /// The merged profile failed validation. This indicates a defect in one
  /// of the inputs' function tables.
  Inconsistent(error: BuildError)
}

/// Merge a base and a candidate into a differential profile. The result
/// keeps the candidate's source and value types.
///
/// ## Examples
///
/// ```gleam
/// diff.merge(base, candidate, diff.Unnormalized)
/// ```
pub fn merge(
  base: Profile,
  candidate: Profile,
  normalize: Normalize,
) -> Result(Profile, DiffError) {
  case profile.value_types(base) == profile.value_types(candidate) {
    False ->
      Error(IncompatibleValueTypes(
        profile.value_types(base),
        profile.value_types(candidate),
      ))
    True -> {
      let #(functions, base_ids) = unify(base, candidate)
      let scale = scales(base, candidate, normalize)
      let scaled =
        list.map(profile.samples(candidate), fn(sample) {
          profile.Sample(..sample, values: scale_values(sample.values, scale))
        })
      let negated =
        list.map(profile.samples(base), fn(sample) {
          profile.Sample(
            frames: list.map(sample.frames, fn(id) { remap(base_ids, id) }),
            values: list.map(sample.values, int.negate),
            labels: [profile.base_label, ..sample.labels],
          )
        })
      profile.new(
        profile.source(candidate),
        profile.value_types(candidate),
        functions,
        list.append(scaled, negated),
      )
      |> result.map_error(Inconsistent)
    }
  }
}

fn remap(ids: Dict(Int, Int), id: Int) -> Int {
  result.unwrap(dict.get(ids, id), id)
}

// One function table for both profiles. The candidate keeps its ids. A base
// function with the same printable name as a candidate function maps onto
// it; any other base function gets a fresh id after the candidate's.
fn unify(
  base: Profile,
  candidate: Profile,
) -> #(List(Function), Dict(Int, Int)) {
  let known =
    profile.functions(candidate)
    |> list.map(fn(function) { #(profile.function_name(function), function.id) })
    |> dict.from_list
  let first_free =
    list.fold(profile.functions(candidate), 0, fn(most, function) {
      int.max(most, function.id + 1)
    })
  let #(extra, ids, _) =
    list.fold(
      profile.functions(base),
      #([], dict.new(), first_free),
      fn(state, function) {
        let #(extra, ids, next) = state
        case dict.get(known, profile.function_name(function)) {
          Ok(existing) -> #(
            extra,
            dict.insert(ids, function.id, existing),
            next,
          )
          Error(Nil) -> #(
            [profile.Function(..function, id: next), ..extra],
            dict.insert(ids, function.id, next),
            next + 1,
          )
        }
      },
    )
  #(list.append(profile.functions(candidate), list.reverse(extra)), ids)
}

// The per-column factor applied to the candidate: one for every column
// unless normalising, then the base's plain total over the candidate's.
fn scales(
  base: Profile,
  candidate: Profile,
  normalize: Normalize,
) -> List(Float) {
  let columns = profile.columns(candidate)
  case normalize {
    Unnormalized -> list.map(columns, fn(_) { 1.0 })
    Normalized ->
      list.map(columns, fn(column) {
        let from_base = plain_sum(profile.samples(base), column)
        let from_candidate = plain_sum(profile.samples(candidate), column)
        case from_candidate {
          0 -> 1.0
          _ -> int.to_float(from_base) /. int.to_float(from_candidate)
        }
      })
  }
}

fn plain_sum(samples: List(Sample), column: profile.Column) -> Int {
  list.fold(samples, 0, fn(sum, sample) {
    sum + profile.sample_value(sample, column)
  })
}

fn scale_values(values: List(Int), scale: List(Float)) -> List(Int) {
  list.map2(values, scale, fn(value, factor) {
    case factor == 1.0 {
      True -> value
      False -> float.round(int.to_float(value) *. factor)
    }
  })
}
