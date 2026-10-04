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
//// - `owner_heap` gives a function that returns the heap capacity change of
////   an owner row by label, for the owners page's builder.

import gleam/list
import gleam/option.{None, Some}
import pickglass/observation.{type Observation}
import pickglass/os_reader
import pickglass_core/measure.{type Measurement, Known, Missing, NotApplicable}
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

/// Whether an observation's census listed every process it scanned.
pub fn census_complete(observation: Observation) -> Bool {
  case observation.census {
    Ok(census) -> census.coverage.stop == wire.WalkFinished
    Error(_) -> False
  }
}

/// The heap capacity change of an owner row by label, from the owners
/// model built for the baseline census and the one built for the current
/// census. `baseline_complete` says whether an owner absent from the
/// baseline model was truly absent.
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
      Known(after), Known(before), _ -> Known(after - before)
      Known(after), Missing(_), BaselineComplete -> Known(after)
      Known(_), Missing(_), BaselineTopRows -> Missing(measure.BudgetExhausted)
      _, _, _ -> Missing(measure.DecodeFailed)
    }
  }
}

/// Whether the baseline census listed everything it scanned.
pub type Completeness {
  /// An owner it does not show was not there.
  BaselineComplete

  /// An owner it does not show may have been below the cut.
  BaselineTopRows
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
