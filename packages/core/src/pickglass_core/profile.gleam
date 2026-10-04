//// The profile model every flame graph, call graph and Top table is built from.
////
//// A profile is a set of samples. Each sample is a call stack (function
//// ids, leaf first), one value per value type, and optional labels naming
//// the owner it belongs to. The function table gives each id a module,
//// name and arity and, where the compiler left debug information, a Gleam
//// source file and line with a stated precision. Every analysis in this
//// package reads this one type, so the invariants that the analyses rely
//// on are established once, here, by `new`:
////
//// - every sample has at least one frame, and every frame names a function
////   in the table;
//// - every sample carries exactly one value for each value type;
//// - function ids are unique;
//// - a profile has at least one value type.
////
//// `Profile` is opaque so that no other module can build one that breaks
//// those rules. The analyses then take a `Column`, a handle to one value
//// type of one profile, instead of a bare index, so an index out of range
//// cannot be written. Diff profiles hold negative values, so values are
//// plain integers and every total is taken over absolute values, as
//// pprof's `computeTotal` does.
////
//// The source of a profile decides what may be drawn from it. Stacks exist
//// for sampled stacks and traced calls; counters and allocation counts are
//// per-function totals with no calling context, so `shape` reports
//// `FunctionTotals` and the flame and graph views refuse them.
////
//// ## Flow
////
//// `new` validates and builds a profile. `column` and `columns` hand out
//// value handles. `samples`, `function` and `total` read it back.
//// `pickglass_core/profile/codec` is the JSON form that capture files
//// carry.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/order
import gleam/result
import gleam/string
import pickglass_core/unit.{type Unit}

/// How the samples of a profile were produced. The source goes on screen
/// beside every view built from the profile.
pub type Source {
  /// Stacks sampled at a rate. `method` names the mechanism (for example
  /// `"polled_stacks"`), `rate` is samples per second.
  SampledStacks(method: String, rate: Int)

  /// A call tree built from traced `call` and `return_to` events.
  TracedCalls

  /// Per-function totals from a counters probe; no stacks.
  TracedCounters

  /// Allocated words per traced function; no stacks.
  AllocationCounts
}

/// Whether a source carries calling context.
pub type Shape {
  /// Samples carry real call stacks, so a calling tree can be built.
  CallStacks

  /// Samples are per-function totals; each stack is the function alone.
  FunctionTotals
}

/// One value a sample carries: a name and the unit it is measured in.
pub type ValueType {
  ValueType(name: String, unit: Unit)
}

/// How exactly a function's source line is known.
pub type LinePrecision {
  /// The line is the call site or definition the compiler recorded.
  Exact

  /// The line is the line of the function's definition only.
  FunctionLevel

  /// No source mapping is known.
  NoLine
}

/// One entry of the function table.
pub type Function {
  Function(
    /// The id samples use to refer to this function.
    id: Int,
    /// The BEAM module, for example `loom@strand_runtime`.
    module: String,
    /// The function name inside the module.
    name: String,
    /// The number of arguments.
    arity: Int,
    /// The Gleam source file, when known.
    file: Option(String),
    /// The Gleam source line, when known.
    line: Option(Int),
    /// How far to trust `line`.
    precision: LinePrecision,
  )
}

/// One observation: a stack, its values, and the labels naming its owner.
pub type Sample {
  Sample(
    /// Function ids, the innermost (leaf) call first.
    frames: List(Int),
    /// One value per value type, in the order of `value_types`.
    values: List(Int),
    /// Owner labels as key and value pairs, such as `#("session", "s_9f2")`.
    labels: List(#(String, String)),
  )
}

/// The reason `new` refused to build a profile.
pub type BuildError {
  /// A profile needs at least one value type.
  NoValueTypes

  /// Two function table entries share this id.
  DuplicateFunction(id: Int)

  /// The sample at this position has no frames.
  EmptyStack(sample: Int)

  /// The sample at this position names a function not in the table.
  UnknownFunction(sample: Int, function: Int)

  /// The sample at this position has the wrong number of values.
  ValueCountMismatch(sample: Int, expected: Int, found: Int)
}

/// A validated profile. Build one with `new`.
pub opaque type Profile {
  Profile(
    source: Source,
    value_types: List(ValueType),
    functions: Dict(Int, Function),
    samples: List(Sample),
  )
}

/// A handle to one value type of one profile. Because only `column` and
/// `columns` create one, an analysis given a `Column` never indexes past
/// the end of a sample's values.
pub opaque type Column {
  Column(index: Int)
}

/// The label that marks a sample as coming from the base of a differential
/// profile. Totals over such a profile count only the marked samples, which
/// makes percentages relative to the base, as pprof's `-diff_base` does.
pub const base_label: #(String, String) = #("pickglass::base", "true")

/// Validate and build a profile.
///
/// ## Examples
///
/// ```gleam
/// profile.new(
///   TracedCalls,
///   [ValueType("time", Nanoseconds)],
///   [Function(0, "m", "f", 0, None, None, NoLine)],
///   [Sample(frames: [0], values: [10], labels: [])],
/// )
/// ```
pub fn new(
  source: Source,
  value_types: List(ValueType),
  functions: List(Function),
  samples: List(Sample),
) -> Result(Profile, BuildError) {
  use <- require_value_types(value_types)
  use table <- result.try(index_functions(functions))
  let width = list.length(value_types)
  use _ <- result.try(check_samples(samples, table, width, 0))
  Ok(Profile(source:, value_types:, functions: table, samples:))
}

fn require_value_types(
  value_types: List(ValueType),
  next: fn() -> Result(Profile, BuildError),
) -> Result(Profile, BuildError) {
  case value_types {
    [] -> Error(NoValueTypes)
    [_, ..] -> next()
  }
}

fn index_functions(
  functions: List(Function),
) -> Result(Dict(Int, Function), BuildError) {
  list.try_fold(functions, dict.new(), fn(table, function) {
    case dict.has_key(table, function.id) {
      True -> Error(DuplicateFunction(function.id))
      False -> Ok(dict.insert(table, function.id, function))
    }
  })
}

fn check_samples(
  samples: List(Sample),
  table: Dict(Int, Function),
  width: Int,
  position: Int,
) -> Result(Nil, BuildError) {
  case samples {
    [] -> Ok(Nil)
    [sample, ..rest] -> {
      use _ <- result.try(check_sample(sample, table, width, position))
      check_samples(rest, table, width, position + 1)
    }
  }
}

fn check_sample(
  sample: Sample,
  table: Dict(Int, Function),
  width: Int,
  position: Int,
) -> Result(Nil, BuildError) {
  let found = list.length(sample.values)
  case sample.frames, found == width {
    [], _ -> Error(EmptyStack(position))
    _, False -> Error(ValueCountMismatch(position, width, found))
    frames, True ->
      case list.find(frames, fn(id) { !dict.has_key(table, id) }) {
        Ok(id) -> Error(UnknownFunction(position, id))
        Error(Nil) -> Ok(Nil)
      }
  }
}

/// A valid profile with one count value type and no samples. Decoders need
/// a value of the target type to report a failure with; this is it.
pub fn empty() -> Profile {
  Profile(
    source: TracedCalls,
    value_types: [ValueType(name: "count", unit: unit.Count)],
    functions: dict.new(),
    samples: [],
  )
}

/// The profile's source.
pub fn source(profile: Profile) -> Source {
  profile.source
}

/// Whether the profile carries calling context.
///
/// ## Examples
///
/// ```gleam
/// profile.shape(TracedCounters)
/// // -> FunctionTotals
/// ```
pub fn shape(source: Source) -> Shape {
  case source {
    SampledStacks(..) | TracedCalls -> CallStacks
    TracedCounters | AllocationCounts -> FunctionTotals
  }
}

/// The value types, in sample order.
pub fn value_types(profile: Profile) -> List(ValueType) {
  profile.value_types
}

/// Handles for every value type, in sample order.
pub fn columns(profile: Profile) -> List(Column) {
  list.index_map(profile.value_types, fn(_, index) { Column(index) })
}

/// The handle for the value type at `index`, if there is one.
///
/// ## Examples
///
/// ```gleam
/// profile.column(p, 0)
/// // -> Ok(_) for any profile
/// ```
pub fn column(profile: Profile, index: Int) -> Result(Column, Nil) {
  case index >= 0 && list.drop(profile.value_types, index) != [] {
    True -> Ok(Column(index))
    False -> Error(Nil)
  }
}

/// The handle for the value type with this name, if there is one.
pub fn column_named(profile: Profile, name: String) -> Result(Column, Nil) {
  use #(_, index) <- result.map(
    profile.value_types
    |> list.index_map(fn(value_type, index) { #(value_type, index) })
    |> list.find(fn(pair) { { pair.0 }.name == name }),
  )
  Column(index)
}

/// The position of a column among the value types.
pub fn column_index(column: Column) -> Int {
  column.index
}

/// The value type a column selects.
pub fn column_type(profile: Profile, column: Column) -> Result(ValueType, Nil) {
  profile.value_types
  |> list.drop(column.index)
  |> list.first
}

/// The samples, in the order they were given.
pub fn samples(profile: Profile) -> List(Sample) {
  profile.samples
}

/// One sample's value for a column. A column that belongs to another
/// profile with more value types reads as zero rather than failing.
pub fn sample_value(sample: Sample, column: Column) -> Int {
  sample.values
  |> list.drop(column.index)
  |> list.first
  |> result.unwrap(0)
}

/// The function table entry for an id.
pub fn function(profile: Profile, id: Int) -> Result(Function, Nil) {
  dict.get(profile.functions, id)
}

/// Every function, ordered by id.
pub fn functions(profile: Profile) -> List(Function) {
  profile.functions
  |> dict.values
  |> list.sort(fn(a, b) { int.compare(a.id, b.id) })
}

/// The printable name of a function: `module:name/arity`.
///
/// ## Examples
///
/// ```gleam
/// profile.function_name(Function(0, "lists", "map", 2, None, None, NoLine))
/// // -> "lists:map/2"
/// ```
pub fn function_name(function: Function) -> String {
  function.module
  <> ":"
  <> function.name
  <> "/"
  <> int.to_string(function.arity)
}

/// The printable name of the function with this id, or `"?"` for an id the
/// table does not hold. A validated profile never names an unknown id.
pub fn name_of(profile: Profile, id: Int) -> String {
  case dict.get(profile.functions, id) {
    Ok(function) -> function_name(function)
    Error(Nil) -> "?"
  }
}

/// The package a BEAM module belongs to. Gleam compiles a module
/// `loom/strand_runtime` to `loom@strand_runtime`, so the package is the
/// text before the first `@`. Erlang modules are their own package.
///
/// ## Examples
///
/// ```gleam
/// profile.package_of("loom@provider@gateway")
/// // -> "loom"
///
/// profile.package_of("lists")
/// // -> "lists"
/// ```
pub fn package_of(module: String) -> String {
  case string.split_once(module, "@") {
    Ok(#(package, _)) -> package
    Error(Nil) -> module
  }
}

/// The total of a column over the whole profile, the denominator every
/// percentage uses. It sums absolute values, so a differential profile's
/// negative samples add to it. If any sample carries `base_label`, only
/// those samples are summed, which makes a differential profile's
/// percentages relative to its base.
///
/// ## Examples
///
/// ```gleam
/// profile.total(p, column)
/// // -> 3096
/// ```
pub fn total(profile: Profile, column: Column) -> Int {
  samples_total(profile.samples, column)
}

fn has_base_label(sample: Sample) -> Bool {
  list.contains(sample.labels, base_label)
}

/// A total over a plain list of samples, with the same rules as `total`.
/// The transform chain uses it to report totals between steps.
pub fn samples_total(samples: List(Sample), column: Column) -> Int {
  let based = list.filter(samples, has_base_label)
  let counted = case based {
    [] -> samples
    [_, ..] -> based
  }
  list.fold(counted, 0, fn(sum, sample) {
    sum + int.absolute_value(sample_value(sample, column))
  })
}

/// The same profile with a different list of samples. The caller must
/// derive the samples from this profile's own by removing samples or
/// frames, or by changing values or labels; that is what keeps every frame
/// in the function table and every sample at full width, and `with_samples`
/// does not check it again. Transforms and diffs use it so that a rewrite
/// does not have to pass through validation it cannot fail.
pub fn with_samples(profile: Profile, samples: List(Sample)) -> Profile {
  Profile(..profile, samples: samples)
}

/// Order two functions by printable name, then by id, the tie-break every
/// display ordering uses so that equal inputs give equal pictures.
pub fn compare_functions(a: Function, b: Function) -> order.Order {
  case string.compare(function_name(a), function_name(b)) {
    order.Eq -> int.compare(a.id, b.id)
    order.Lt -> order.Lt
    order.Gt -> order.Gt
  }
}

/// The profile's stacks with identical frame lists merged, as pairs of
/// frames (leaf first) and the sum of the column over the samples that had
/// them. Stacks are ordered by their frame lists so equal profiles give
/// equal output. A stack whose values cancel to zero (as in a differential
/// profile) is still listed, with value zero; callers that must not draw
/// it filter on the value.
///
/// ## Examples
///
/// ```gleam
/// profile.merged_stacks(p, column)
/// // -> [#([2, 1, 0], 17), #([3, 1, 0], 4)]
/// ```
pub fn merged_stacks(
  profile: Profile,
  column: Column,
) -> List(#(List(Int), Int)) {
  profile.samples
  |> list.fold(dict.new(), fn(table, sample) {
    dict.upsert(table, sample.frames, fn(existing) {
      sample_value(sample, column) + option.unwrap(existing, 0)
    })
  })
  |> dict.to_list
  |> list.sort(fn(a, b) { compare_frames(a.0, b.0) })
}

fn compare_frames(a: List(Int), b: List(Int)) -> order.Order {
  case a, b {
    [], [] -> order.Eq
    [], [_, ..] -> order.Lt
    [_, ..], [] -> order.Gt
    [x, ..xs], [y, ..ys] ->
      case int.compare(x, y) {
        order.Eq -> compare_frames(xs, ys)
        order.Lt -> order.Lt
        order.Gt -> order.Gt
      }
  }
}
