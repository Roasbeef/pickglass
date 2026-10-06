//// An allocation counters probe's result as a core profile.
////
//// A probe that counts allocation (`call_time` and `call_memory`, which is
//// what OTP's `tprof` calls `call_memory`) reads, for each traced function
//// that was called, the calls, the call time and the words allocated on the
//// process heap while the function ran. The VM keeps one total per function
//// and no calling context, so the result is core's `AllocationCounts`
//// source, whose shape is `FunctionTotals`: a Top table can be drawn from it
//// and a flame graph or a call graph cannot, because they would need stacks
//// the VM never recorded.
////
//// A profile built here has three value types, in this order: the number of
//// calls, the call time in nanoseconds (the agent reports microseconds, so
//// each is multiplied by a thousand) and the words allocated, which stay
//// words. A word is not converted to bytes here: its size is a fact about the
//// target that the capture's runtime facts record, and a reader that lacks it
//// shows words.
////
//// A function appears only when it was called and its allocation counter was
//// read. A called function whose counter could not be read, and a function
//// the agent left out because it listed only the largest 200, are counted
//// in the facts and said in the notes; neither is a row with zero words,
//// because zero is a measurement and these are not.
////
//// ## Flow
////
//// - `build` maps the agent's rows into a profile.
//// - `facts` collects what the profile cannot say, for the capture.
//// - `caveats` words what the numbers do not mean.

import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import pickglass/counters_profile
import pickglass_core/capture
import pickglass_core/profile.{type Profile}
import pickglass_core/unit
import pickglass_core/wire
import pickglass_web/fmt

/// The name of the call count column.
pub const calls_column = counters_profile.calls_column

/// The name of the call time column.
pub const time_column = counters_profile.time_column

/// The name of the allocated words column, the one an allocation profile is
/// ranked by.
pub const words_column = "allocated words"

/// The three value types of an allocation profile, in column order.
pub fn value_types() -> List(profile.ValueType) {
  [
    profile.ValueType(name: calls_column, unit: unit.Count),
    profile.ValueType(name: time_column, unit: unit.Nanoseconds),
    profile.ValueType(name: words_column, unit: unit.Words),
  ]
}

/// Build the profile of the functions the agent listed, one sample of one
/// frame each, in the order given.
///
/// ## Examples
///
/// ```gleam
/// allocation_profile.build([wire.FunctionMemory("m", "f", 1, 300, 5, 40)])
/// // -> Ok(profile) with one function and the values [5, 40_000, 300]
/// ```
pub fn build(
  rows: List(wire.FunctionMemory),
) -> Result(Profile, profile.BuildError) {
  let numbered = list.index_map(rows, fn(row, index) { #(index, row) })

  profile.new(
    profile.AllocationCounts,
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
        values: [row.calls, row.time_us * 1000, row.words],
        labels: [],
      )
    }),
  )
}

/// What the capture keeps beside the profile: the window asked for, how many
/// processes were traced, and how the functions that were called divide into
/// those with a reading and those without, so that a missing function is not
/// taken for one that allocated nothing.
///
/// ## Examples
///
/// ```gleam
/// allocation_profile.facts(5000, Some(2), counters, totals)
/// // -> CounterFacts(requested_ms: 5000, processes: Some(2), ..)
/// ```
pub fn facts(
  requested_ms: Int,
  processes: Option(Int),
  counters: wire.CountersSnapshot,
  totals: wire.MemoryTotals,
) -> capture.CounterFacts {
  capture.CounterFacts(
    requested_ms:,
    processes:,
    // Every called function lands in exactly one of read and unread at the
    // allocation read, so the sum is exact even if the counters were read at
    // another moment, as an operator's stop does.
    called: totals.read + totals.unread,
    read: totals.read,
    unread: totals.unread,
    invalidated: counters.invalidated,
    total_words: totals.words,
  )
}

/// The sentences that say how far to trust an allocation profile and what it
/// does not mean. They are the same whether the profile was just taken or was
/// read back from a capture, so a capture's reader is told what a live viewer
/// is.
///
/// ## Examples
///
/// ```gleam
/// allocation_profile.caveats(facts, 200)
/// // -> ["No call stacks: ...", ..]
/// ```
pub fn caveats(facts: capture.CounterFacts, listed: Int) -> List(String) {
  list.flatten([
    [
      "Allocated words are words allocated on the process heap while a traced function ran, summed over the traced processes. They are cumulative allocation, not retained heap, resident memory (RSS), binaries held outside the heap, ETS or native and NIF memory, and a garbage collection does not lower them.",
      "Function totals only: the VM keeps one total per function and no calling context, so there are no call stacks and no attribution of untraced work. A traced function's words exclude those of the traced functions it calls and include those of the untraced functions it calls.",
      "Call time sums over every traced process, and calls are not split by process.",
    ],
    case facts.read - listed {
      omitted if omitted > 0 -> [
        fmt.count(omitted)
        <> " functions with a reading are not listed: the agent keeps the "
        <> fmt.count(listed)
        <> " that allocated the most.",
      ]
      _ -> []
    },
    case facts.unread {
      0 -> []
      count -> [
        fmt.count(count)
        <> " called functions have no allocation reading because the VM no longer counted them; they are not listed and are not zero.",
      ]
    },
    case facts.invalidated {
      0 -> []
      count -> [
        int.to_string(count)
        <> " traced functions were invalidated by a module reload; this snapshot is suspect.",
      ]
    },
  ])
}
