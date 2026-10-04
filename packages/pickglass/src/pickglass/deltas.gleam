//// Changes since a checkpoint.
////
//// Every figure that shows a change shows it against the observation a
//// checkpoint kept. The rules are the ones the pages already follow: a
//// change is only a number when both readings are numbers, a reading that
//// was not taken says why instead of being treated as zero, and an owner
//// that the baseline census could not have listed has no baseline, which is
//// different from an owner that was not there.
////
//// That last case needs care. A census lists the top rows only, so an
//// owner missing from the baseline might have existed and fallen below the
//// cut. The census says whether it listed everything it scanned; when it
//// did, a missing owner was absent and its baseline is zero; when it did
//// not, the baseline is `Missing`, and the page shows the word.
////
//// ## Flow
////
//// - `memory` is a memory category's change.
//// - `os_rss` is the target's resident set change.
//// - `owner_heap_from_aggregates` gives that function from the agent's
////   per-owner aggregates, which cover every process the walk scanned.
//// - `owner_heap` gives the same function from the listed rows alone, for a
////   baseline that has no aggregates (a capture) or a walk that stopped
////   early.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import pickglass/observation.{type Observation}
import pickglass/os_reader
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
import pickglass_core/owner
import pickglass_core/wire
import pickglass_web/model

/// A memory category's change from the baseline to the current reading.
/// A category the baseline did not report has no baseline.
///
/// ## Examples
///
/// ```gleam
/// deltas.memory(current, baseline, "binary")
/// // -> Known(4096)
/// ```
pub fn memory(
  current: Observation,
  baseline: Observation,
  category: String,
) -> Measurement {
  case current.memory, baseline.memory {
    Ok(now), Ok(before) ->
      case
        list.key_find(now.categories, category),
        list.key_find(before.categories, category)
      {
        Ok(after), Ok(earlier) -> Known(after - earlier)
        _, _ -> Missing(measure.UnsupportedOnRuntime)
      }
    _, _ -> Missing(measure.DecodeFailed)
  }
}

/// The change of the target's resident set.
///
/// ## Examples
///
/// ```gleam
/// deltas.os_rss(current, baseline)
/// ```
pub fn os_rss(current: Observation, baseline: Observation) -> Measurement {
  case target_rss(current), target_rss(baseline) {
    Known(after), Known(before) -> Known(after - before)
    Missing(reason), _ | _, Missing(reason) -> Missing(reason)
    _, _ -> NotApplicable
  }
}

/// The resident set of the target in an observation, or the word for why
/// there is none.
pub fn target_rss(observation: Observation) -> Measurement {
  case observation.os {
    Ok(readings) ->
      case os_reader.target_of(readings) {
        Some(reading) -> reading.rss
        None -> Missing(measure.ProcessExited)
      }
    Error(_) -> Missing(measure.CounterDisabled)
  }
}

/// Whether an observation's census listed every process it scanned. The walk
/// must have finished, and the rows must be as many as the processes scanned:
/// the agent lists only its top rows, so a node with more processes than that
/// has a census that scanned everything and lists a part.
pub fn census_complete(observation: Observation) -> Bool {
  case observation.census {
    Ok(census) ->
      census.coverage.stop == wire.WalkFinished
      && list.length(census.rows) == census.coverage.scanned
    Error(_) -> False
  }
}

/// The heap capacity change of an owner row by label, from the agent's
/// per-owner aggregates in two observations.
///
/// The aggregates are sums over every process the walk scanned, so they stay
/// complete on a node with more processes than the census lists as rows,
/// which is where the listed rows alone cannot give a change. They are
/// usable when both walks finished and both reported their totals. A walk
/// that stopped at its scan budget or its deadline summed only part of the
/// node, and `Error(Nil)` says the caller has no such pair; it then uses
/// `owner_heap`, which answers that the budget was exhausted.
///
/// The agent lists the largest owners by memory and counts how many it
/// tracked. A label that one side lists and the other does not has a change
/// only if the other side listed every owner, which makes its absence a zero.
/// Otherwise the owner may have been below the cut, and the answer is the
/// budget word and not a number. When some owners are unlisted on a side, an
/// owner's figure is the sum of its listed roles, so it omits roles smaller
/// than the smallest listed one.
///
/// ## Examples
///
/// ```gleam
/// deltas.owner_heap_from_aggregates(now, before, 8)
/// // -> Ok(fn(label) { Known(-4096) })
/// ```
pub fn owner_heap_from_aggregates(
  current: Observation,
  baseline: Observation,
  word_size: Int,
) -> Result(fn(String) -> Measurement, Nil) {
  use now <- result.try(aggregates_of(current, word_size))
  use before <- result.try(aggregates_of(baseline, word_size))

  Ok(fn(label) {
    case side_value(now, label), side_value(before, label) {
      Ok(after), Ok(earlier) -> Known(after - earlier)
      _, _ -> Missing(measure.BudgetExhausted)
    }
  })
}

// One observation's per-owner heap capacity in bytes, and whether it lists
// every owner the walk tracked.
type Aggregates {
  Aggregates(heaps: Dict(String, Int), owners: Listing)
}

type Listing {
  EveryOwner
  TopOwnersOnly
}

fn aggregates_of(
  observation: Observation,
  word_size: Int,
) -> Result(Aggregates, Nil) {
  use census <- result.try(result.replace_error(observation.census, Nil))
  use totals <- result.try(result.replace_error(observation.totals, Nil))
  use owners <- result.try(result.replace_error(observation.owner_heaps, Nil))

  case census.coverage.stop {
    wire.WalkFinished ->
      Ok(
        Aggregates(
          heaps: list.fold(owners, dict.new(), fn(heaps, entry) {
            add_heap(heaps, entry, word_size)
          }),
          owners: case totals.owners_listed >= totals.owners_tracked {
            True -> EveryOwner
            False -> TopOwnersOnly
          },
        ),
      )
    wire.ScanBudgetReached | wire.DeadlineReached -> Error(Nil)
  }
}

// An owner's heap is added under the labels the owners page uses: the owner
// by its first path segment, the role under it as `owner / role`, and the
// unlabelled processes as `unknown`.
fn add_heap(
  heaps: Dict(String, Int),
  entry: wire.OwnerHeapTotal,
  word_size: Int,
) -> Dict(String, Int) {
  let bytes = entry.total_heap_words * word_size

  case entry.total.owner {
    wire.Unlabelled -> add_to(heaps, "unknown", bytes)
    wire.Labelled(path:, role:) -> {
      let label = owner.path_to_string(list.take(path, 1))

      heaps
      |> add_to(label, bytes)
      |> add_to(label <> " / " <> role, bytes)
    }
  }
}

fn add_to(
  heaps: Dict(String, Int),
  label: String,
  bytes: Int,
) -> Dict(String, Int) {
  dict.upsert(heaps, label, fn(existing) {
    case existing {
      Some(sum) -> sum + bytes
      None -> bytes
    }
  })
}

// An owner's heap on one side. An owner the side does not list was absent
// when that side listed every owner, and is unknown otherwise.
fn side_value(side: Aggregates, label: String) -> Result(Int, Nil) {
  case dict.get(side.heaps, label), side.owners {
    Ok(bytes), _ -> Ok(bytes)
    Error(Nil), EveryOwner -> Ok(0)
    Error(Nil), TopOwnersOnly -> Error(Nil)
  }
}

/// The heap capacity change of an owner row by label, from the owners
/// model built for the baseline census and the one built for the current
/// census. An owner's heap in a model is the sum over the rows its census
/// listed. When either census listed only its top rows, the two sums cover
/// different sets of processes, whether the owner is absent from one side or
/// present on both, so no change is claimed.
///
/// ## Examples
///
/// ```gleam
/// deltas.owner_heap(current_page, baseline_page, True)("session:s-12")
/// ```
pub fn owner_heap(
  current: model.OwnersModel,
  baseline: model.OwnersModel,
  completeness: Completeness,
) -> fn(String) -> Measurement {
  let now = heaps_by_label(current)
  let before = heaps_by_label(baseline)

  fn(label) {
    case reading(now, label), reading(before, label), completeness {
      Known(after), Known(before), BothComplete -> Known(after - before)
      Known(after), Missing(_), BothComplete -> Known(after)
      Known(_), Known(_), TopRowsOnly | Known(_), Missing(_), TopRowsOnly ->
        Missing(measure.BudgetExhausted)
      _, _, _ -> Missing(measure.DecodeFailed)
    }
  }
}

/// Whether the two censuses an owner change compares listed everything they
/// scanned.
pub type Completeness {
  /// Both did. An owner one of them does not show was not there.
  BothComplete

  /// At least one listed only its top rows, so an owner it does not show may
  /// have been below the cut, and one it shows may be missing processes.
  TopRowsOnly
}

// The heap capacity of every owner row of a page, by the label an owners
// page builder hands its delta function: an owner by its path, a role as
// `path / role`, and the unknown group as `unknown`. A role row follows its
// owner's row, which is how the pair is found.
fn heaps_by_label(page: model.OwnersModel) -> List(#(String, Measurement)) {
  let #(labelled, _) =
    list.fold(page.rows, #([], ""), fn(state, row) {
      case row.kind {
        model.RoleGroup -> #(
          [#(state.1 <> " / " <> row.label, row.heap_cap), ..state.0],
          state.1,
        )
        model.OwnerGroup | model.UnknownGroup -> #(
          [#(row.label, row.heap_cap), ..state.0],
          row.label,
        )
      }
    })

  [#("unknown", page.unknown.heap_cap), ..labelled]
}

fn reading(heaps: List(#(String, Measurement)), label: String) -> Measurement {
  case list.key_find(heaps, label) {
    Ok(found) -> found
    Error(Nil) -> Missing(measure.ProcessExited)
  }
}
