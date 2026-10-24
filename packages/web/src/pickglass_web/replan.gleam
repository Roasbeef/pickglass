//// The profile a refusal offers to run again.
////
//// A one-click profile chooses its processes from the newest census. When
//// every one of them has exited by the time the operator confirms, the
//// choice is stale and choosing again from the current census is the likely
//// fix. This type says which button's choice to repeat; the flow draws the
//// button, and the viewer resolves it against current data exactly as it
//// does for the original click.

import pickglass_web/key.{type Key}

/// A profile that can be planned again with one click.
pub type Again {
  /// The busiest processes of the newest pass, chosen afresh.
  AgainBusiest

  /// The processes of this owner row, chosen afresh.
  AgainOwner(owner: Key)
}
