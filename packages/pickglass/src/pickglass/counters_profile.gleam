//// A counters probe's result as a core profile.
////
//// A counters probe counts calls and call time per function inside the VM
//// and sends no trace message, so what it returns is one total per
//// function: no calling context, no timeline. That is exactly core's
//// `TracedCounters` source, whose shape is `FunctionTotals`. The profile
//// page draws a Top table from it and says why it cannot draw a flame
//// graph or a call graph; this module only maps the agent's rows into the
//// profile model.
////
//// A profile built here has two value types, in this order: the number of
//// calls, and the time spent in the function in nanoseconds. The agent
//// reports microseconds, so each is multiplied by a thousand. A function
//// the probe traced and nobody called has no row, because the agent's
//// snapshot omits it and a zero is not a measurement.
////
//// Each row becomes one sample of one frame, which is how core represents
//// a function total: the function is its own and only frame.

import gleam/list
import gleam/option.{None}
import pickglass_core/profile.{type Profile}
import pickglass_core/unit
import pickglass_core/wire

/// The name of the call count column.
pub const calls_column = "calls"

/// The name of the call time column.
pub const time_column = "call time"

/// The two value types of a counters profile, in column order.
pub fn value_types() -> List(profile.ValueType) {
  [
    profile.ValueType(name: calls_column, unit: unit.Count),
    profile.ValueType(name: time_column, unit: unit.Nanoseconds),
  ]
}

/// Build the profile of a snapshot. A row with no calls is left out.
///
/// ## Examples
///
/// ```gleam
/// counters_profile.build(snapshot)
/// // -> Ok(profile) with one sample per called function
/// ```
pub fn build(
  snapshot: wire.CountersSnapshot,
) -> Result(Profile, profile.BuildError) {
  let called = list.filter(snapshot.rows, fn(row) { row.calls > 0 })
  let numbered = list.index_map(called, fn(row, index) { #(index, row) })

  profile.new(
    profile.TracedCounters,
    value_types(),
    list.map(numbered, fn(entry) {
      let #(id, row) = entry

      profile.Function(
        id:,
        module: row.module,
        name: row.function,
        arity: row.arity,
        file: None,
        line: None,
        precision: profile.NoLine,
      )
    }),
    list.map(numbered, fn(entry) {
      let #(id, row) = entry

      profile.Sample(
        frames: [id],
        values: [row.calls, row.time_us * 1000],
        labels: [],
      )
    }),
  )
}
