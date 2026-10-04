//// The title-bar line every data panel carries.
////
//// A panel says where its numbers come from: the source, the method, the
//// interval, how much of what was asked was achieved, and what was cut.
//// Several modules build panels, so the one constructor lives here and each
//// states those facts as arguments instead of assembling the record.

import gleam/option.{type Option}
import pickglass_core/measure.{NotApplicable}
import pickglass_web/model

/// What a panel's line is built from.
pub type Facts {
  Facts(
    source: String,
    method: String,
    /// The collection cadence in milliseconds, or zero for a reading taken
    /// once.
    cadence_ms: Int,
    /// What the coverage counts: `processes`, `categories`, ...
    scope: String,
    requested: Int,
    achieved: Int,
    outcome: measure.Outcome,
    /// The time between the starts of the two newest collection passes, when
    /// the panel is refreshed by a repeating pass that has run twice.
    gap_ms: Option(Int),
    /// How long taking the reading took, when it was timed.
    took_ms: Option(Int),
  )
}

/// The line of a panel.
///
/// ## Examples
///
/// ```gleam
/// panel.info(Facts("census", "process_info", 2000, "processes", 10, 10, measure.Complete, None, Some(4)))
/// ```
pub fn info(facts: Facts) -> model.PanelInfo {
  model.PanelInfo(
    source: facts.source,
    method: facts.method,
    cadence: case facts.cadence_ms > 0 {
      True -> measure.EveryMs(facts.cadence_ms)
      False -> measure.OneShot
    },
    achieved_ms: facts.gap_ms,
    took_ms: facts.took_ms,
    coverage: measure.Coverage(
      scope: facts.scope,
      requested: facts.requested,
      achieved: facts.achieved,
      outcome: facts.outcome,
      dropped_events: NotApplicable,
      in_flight_events: NotApplicable,
      unscanned_bytes: NotApplicable,
    ),
  )
}
