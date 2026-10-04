//// Checkpoints and what they are compared against.
////
//// A checkpoint is the operator saying "from here on, show me what
//// changed". For that to work the viewer needs the readings as they were at
//// that moment, and the ring cannot be trusted to still hold them: at its
//// cadence and size it forgets after ten minutes, and the questions a
//// checkpoint exists for (does an idle daemon keep growing) take longer.
//// A `Mark` therefore carries its own copy of the newest observation at the
//// time it was taken. `capture.Checkpoint` stays the record that goes into a
//// capture file, with its name and timestamps; the baseline observation is
//// the viewer's, and a capture opened later gets it back by finding the
//// observation nearest before the checkpoint.
////
//// A mark whose baseline is `None` (a checkpoint taken before any pass
//// completed, or before the first observation of a replayed capture) offers
//// no deltas. A page says so and shows no change, never a zero.
////
//// ## Flow
////
//// - `take` builds a mark from the newest observation.
//// - `from_capture` rebuilds the marks of a capture file.
//// - `chosen` picks the mark a page compares against.

import gleam/list
import gleam/option.{type Option, None, Some}
import pickglass/observation.{type Observation}
import pickglass_core/capture

/// A checkpoint and the observation its figures are compared against.
pub type Mark {
  Mark(checkpoint: capture.Checkpoint, baseline: Option(Observation))
}

/// A mark for a checkpoint taken now. `newest` is the newest observation
/// the viewer holds, if any.
///
/// ## Examples
///
/// ```gleam
/// marks.take(capture.Checkpoint("idle-0", 0, 1000), Some(observation))
/// ```
pub fn take(
  checkpoint: capture.Checkpoint,
  newest: Option(Observation),
) -> Mark {
  Mark(checkpoint:, baseline: newest)
}

/// The marks of a capture's checkpoints. Each baseline is the newest
/// observation whose pass began no later than the checkpoint; a checkpoint
/// before the first pass has none. `observations` is oldest first.
///
/// ## Examples
///
/// ```gleam
/// marks.from_capture(checkpoints, observations)
/// ```
pub fn from_capture(
  checkpoints: List(capture.Checkpoint),
  observations: List(Observation),
) -> List(Mark) {
  list.map(checkpoints, fn(checkpoint) {
    let before =
      list.filter(observations, fn(observation) {
        observation.at_ms <= checkpoint.system_ms
      })

    Mark(checkpoint:, baseline: option.from_result(list.last(before)))
  })
}

/// The mark a page compares against: the one named by `wanted` if it is
/// still among `marks`, otherwise the newest. `marks` is oldest first, and a
/// page that has no checkpoint at all compares against nothing.
///
/// ## Examples
///
/// ```gleam
/// marks.chosen(marks, Some(0))
/// ```
pub fn chosen(marks: List(Mark), wanted: Option(Int)) -> Option(#(Int, Mark)) {
  let indexed = list.index_map(marks, fn(mark, index) { #(index, mark) })

  case wanted {
    Some(index) ->
      case list.find(indexed, fn(entry) { entry.0 == index }) {
        Ok(entry) -> Some(entry)
        Error(Nil) -> newest(indexed)
      }
    None -> newest(indexed)
  }
}

fn newest(indexed: List(#(Int, Mark))) -> Option(#(Int, Mark)) {
  case list.last(indexed) {
    Ok(entry) -> Some(entry)
    Error(Nil) -> None
  }
}
