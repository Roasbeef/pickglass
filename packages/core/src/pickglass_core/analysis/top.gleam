//// The Top table: flat and cum per function, one column per value type.
////
//// For each function, `flat` is the value of the samples whose innermost
//// frame it is, and `cum` is the value of the samples it appears in at all,
//// counted once per sample so that recursion does not inflate it. The
//// table has a pair of numbers for every value type of the profile, so a
//// sampled-time view and an allocation view are one table, not two.
////
//// With a base profile the table also carries, per function and value type,
//// the candidate minus the base. Functions are matched by printable name
//// (`module:name/arity`), because two captures number their functions
//// independently. A function present only in the base appears with zero
//// totals and a negative delta, so a function that disappeared is visible.
////
//// Unlike the graph, Top applies no node trim: pprof's web view shows
//// 500 rows by default, and `limit` is the caller's decision.
////
//// ## Flow
////
//// `table` calls `accumulate` for the profile and for the base, which adds
//// each sample to its functions' `Totals` through `add_sample`. `build`
//// then joins the two by name and `compare_rows` sorts by the chosen
//// column.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/set
import gleam/string
import pickglass_core/profile.{
  type Column, type Profile, type Sample, type ValueType,
}

/// Which of the two numbers orders the rows.
pub type SortKey {
  /// Order by flat value, the cost of the function itself.
  ByFlat

  /// Order by cumulative value, the cost of the function and its callees.
  ByCum
}

/// How the table is ordered: by which value type and which number.
pub type Sort {
  Sort(column: Column, key: SortKey)
}

/// A function's two numbers for one value type.
pub type Totals {
  Totals(flat: Int, cum: Int)
}

/// One row of the table.
pub type Row {
  Row(
    /// The printable name, `module:name/arity`.
    name: String,
    /// The function's id in the profile, or none for a function present
    /// only in the base.
    function: Option(Int),
    /// One `Totals` per value type, in order.
    totals: List(Totals),
    /// With a base, the candidate's totals minus the base's, per value
    /// type; empty when there is no base.
    delta: List(Totals),
  )
}

/// The whole table.
pub type Table {
  Table(
    /// The value types, naming the columns of every row.
    value_types: List(ValueType),
    /// The rows, best first.
    rows: List(Row),
    /// The column totals the percentages divide by.
    totals: List(Int),
  )
}

/// Why a table could not be built.
pub type TopError {
  /// The base's value types differ from the profile's.
  IncompatibleBase
}

// The accumulator for one function name.
type Acc {
  Acc(function: Option(Int), totals: List(Totals))
}

/// Build the table, optionally against a base.
///
/// ## Examples
///
/// ```gleam
/// top.table(p, None, top.Sort(column, top.ByFlat))
/// ```
pub fn table(
  profile: Profile,
  base: Option(Profile),
  sort: Sort,
) -> Result(Table, TopError) {
  let width = list.length(profile.value_types(profile))
  let own = accumulate(profile)
  case base {
    None -> Ok(build(profile, own, dict.new(), width, sort, Alone))
    Some(other) ->
      case profile.value_types(other) == profile.value_types(profile) {
        False -> Error(IncompatibleBase)
        True ->
          Ok(build(profile, own, accumulate(other), width, sort, Compared))
      }
  }
}

type Comparison {
  Alone
  Compared
}

fn build(
  profile: Profile,
  own: Dict(String, Acc),
  base: Dict(String, Acc),
  width: Int,
  sort: Sort,
  comparison: Comparison,
) -> Table {
  let names =
    set.to_list(set.from_list(list.append(dict.keys(own), dict.keys(base))))
  let zero = zeros(width)
  let rows =
    list.map(names, fn(name) {
      let mine = dict.get(own, name)
      let theirs = dict.get(base, name)
      let totals = case mine {
        Ok(acc) -> acc.totals
        Error(Nil) -> zero
      }
      let delta = case comparison, theirs {
        Alone, _ -> []
        Compared, Ok(acc) -> list.map2(totals, acc.totals, subtract)
        Compared, Error(Nil) -> totals
      }
      Row(
        name: name,
        function: case mine {
          Ok(acc) -> acc.function
          Error(Nil) -> None
        },
        totals: totals,
        delta: delta,
      )
    })
  Table(
    value_types: profile.value_types(profile),
    rows: list.sort(rows, fn(a, b) { compare_rows(a, b, sort) }),
    totals: list.map(profile.columns(profile), fn(column) {
      profile.total(profile, column)
    }),
  )
}

fn zeros(width: Int) -> List(Totals) {
  list.repeat(Totals(0, 0), width)
}

fn subtract(a: Totals, b: Totals) -> Totals {
  Totals(flat: a.flat - b.flat, cum: a.cum - b.cum)
}

fn add(a: Totals, b: Totals) -> Totals {
  Totals(flat: a.flat + b.flat, cum: a.cum + b.cum)
}

// Largest absolute value of the chosen number first, then by name.
fn compare_rows(a: Row, b: Row, sort: Sort) -> order.Order {
  let index = profile.column_index(sort.column)
  let key = sort.key
  let pick = fn(row: Row) {
    let selected =
      row.totals
      |> list.drop(index)
      |> list.first
      |> option.from_result
      |> option.unwrap(Totals(0, 0))
    case key {
      ByFlat -> int.absolute_value(selected.flat)
      ByCum -> int.absolute_value(selected.cum)
    }
  }
  order.break_tie(int.compare(pick(b), pick(a)), string.compare(a.name, b.name))
}

// Flat and cum per function name for every value type. A function counts
// once per sample toward cum however often the stack repeats it.
fn accumulate(profile: Profile) -> Dict(String, Acc) {
  let columns = profile.columns(profile)
  list.fold(profile.samples(profile), dict.new(), fn(table, sample) {
    let values =
      list.map(columns, fn(column) { profile.sample_value(sample, column) })
    add_sample(profile, table, sample, values)
  })
}

fn add_sample(
  profile: Profile,
  table: Dict(String, Acc),
  sample: Sample,
  values: List(Int),
) -> Dict(String, Acc) {
  let leaf = list.first(sample.frames)
  let distinct = list.unique(sample.frames)
  list.fold(distinct, table, fn(current, id) {
    let flat = case leaf == Ok(id) {
      True -> values
      False -> list.map(values, fn(_) { 0 })
    }
    let contribution =
      list.map2(flat, values, fn(f, c) { Totals(flat: f, cum: c) })
    let name = profile.name_of(profile, id)
    dict.upsert(current, name, fn(existing) {
      case existing {
        Some(acc) ->
          Acc(..acc, totals: list.map2(acc.totals, contribution, add))
        None -> Acc(function: Some(id), totals: contribution)
      }
    })
  })
}
