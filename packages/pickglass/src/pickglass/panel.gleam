//// The title-bar line every data panel carries.
////
//// A panel says where its numbers come from: the source, the method, the
//// interval, how much of what was asked was achieved, and what was cut.
//// Several modules build panels, so the one constructor lives here and each
//// states those facts as arguments instead of assembling the record.

import gleam/option.{Some}
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
    /// How long taking the reading took.
    elapsed_ms: Int,
  )
}

/// The line of a panel.
///
/// ## Examples
///
/// ```gleam
/// panel.info(Facts("census", "process_info", 2000, "processes", 10, 10, measure.Complete, 4))
/// ```
pub fn info(facts: Facts) -> model.PanelInfo {
  model.PanelInfo(
    source: facts.source,
    method: facts.method,
    cadence: case facts.cadence_ms > 0 {
      True -> measure.EveryMs(facts.cadence_ms)
      False -> measure.OneShot
    },
    achieved_ms: Some(facts.elapsed_ms),
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
