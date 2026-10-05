//// The zoom of the call graph, as a closed set of steps.
////
//// The graph is drawn from a layout whose natural size is fixed, so zooming
//// is a choice of how large to draw that picture: the whole of it scaled to
//// the frame (`Fit`), or a percentage of its natural size taken from a short
//// list of steps. The server keeps the choice in the page's view state and
//// draws it as the SVG's `width` and `height`, so the browser never reports
//// a size and the stylesheet needs no script.
////
//// Nothing a browser sends names a percentage. A click or a wheel event maps
//// to one of the four `Change`s, and `apply` is the only place a level is
//// computed, so the level is always on the list, whatever arrives.
////
//// ## Where Fit sits among the steps
////
//// `Fit` is a size the browser works out from the frame, which the server
//// never sees, so it has no place on the list. Zooming in from it goes to
//// 100%, the natural size, and zooming out goes to 50%. The graph may be
//// drawn larger or smaller than that at Fit, so the first step from Fit can
//// look like a jump the other way for a graph that was already small; the
//// steps after it are exact.
////
//// ## Reading order
////
//// `Zoom` and `Change` are the types, `apply` takes one step, `percent` and
//// `scaled` read a level back, and `Wheel` is whether the mouse wheel zooms.

import gleam/int

/// How large the call graph is drawn.
pub type Zoom {
  /// Scaled to the frame's width, never larger than its natural size.
  Fit

  /// Drawn at this percentage of its natural size, one of `steps`.
  Scaled(percent: Int)
}

/// A request to change the zoom. It carries no percentage.
pub type Change {
  /// The next larger step.
  ZoomIn

  /// The next smaller step.
  ZoomOut

  /// Scale the graph to the frame.
  ZoomToFit

  /// Draw the graph at its natural size.
  ZoomActual
}

/// Whether the wheel over the graph zooms it.
///
/// A server component cannot decide on the server whether to cancel the
/// browser's default action for an event, and the default action of a plain
/// wheel turn is scrolling the frame. So the handler that cancels it is only
/// attached while the operator has chosen `WheelZooms`; otherwise the wheel
/// scrolls as it always did.
pub type Wheel {
  /// The wheel scrolls the frame and no handler is attached.
  WheelScrolls

  /// The wheel zooms the graph, and the frame scrolls by its scroll bars.
  WheelZooms
}

/// The percentages a graph can be drawn at, smallest first.
pub const steps: List(Int) = [25, 50, 75, 100, 150, 200, 300, 400]

/// The level a change leads to.
///
/// A step in a direction with no further step stays where it is, so the
/// buttons and the wheel can be repeated without leaving the list.
///
/// ## Examples
///
/// ```gleam
/// zoom.apply(zoom.Scaled(100), zoom.ZoomIn)
/// // -> Scaled(150)
///
/// zoom.apply(zoom.Scaled(400), zoom.ZoomIn)
/// // -> Scaled(400)
///
/// zoom.apply(zoom.Fit, zoom.ZoomOut)
/// // -> Scaled(50)
/// ```
pub fn apply(zoom: Zoom, change: Change) -> Zoom {
  case change, zoom {
    ZoomToFit, _ -> Fit
    ZoomActual, _ -> Scaled(100)
    ZoomIn, Fit -> Scaled(100)
    ZoomOut, Fit -> Scaled(50)
    ZoomIn, Scaled(current) -> Scaled(next_above(steps, current, current))
    ZoomOut, Scaled(current) -> Scaled(next_below(steps, current, current))
  }
}

// The first step above `current`, or `current` when it is the largest. Steps
// are ascending, so the first larger one is the next one.
fn next_above(remaining: List(Int), current: Int, fallback: Int) -> Int {
  case remaining {
    [] -> fallback
    [step, ..rest] ->
      case step > current {
        True -> step
        False -> next_above(rest, current, fallback)
      }
  }
}

// The last step below `current`, found by keeping the latest smaller one
// while walking the ascending list.
fn next_below(remaining: List(Int), current: Int, found: Int) -> Int {
  case remaining {
    [] -> found
    [step, ..rest] ->
      case step < current {
        True -> next_below(rest, current, step)
        False -> found
      }
  }
}

/// The text of the readout between the buttons.
///
/// ## Examples
///
/// ```gleam
/// zoom.label(zoom.Scaled(150))
/// // -> "150%"
///
/// zoom.label(zoom.Fit)
/// // -> "Fit"
/// ```
pub fn label(zoom: Zoom) -> String {
  case zoom {
    Fit -> "Fit"
    Scaled(percent) -> int.to_string(percent) <> "%"
  }
}

/// A natural length drawn at this zoom, in whole units and at least one. At
/// `Fit` the natural length is kept, and the stylesheet scales it down to the
/// frame.
///
/// ## Examples
///
/// ```gleam
/// zoom.scaled(zoom.Scaled(150), 301)
/// // -> 452
///
/// zoom.scaled(zoom.Fit, 301)
/// // -> 301
/// ```
pub fn scaled(zoom: Zoom, length: Int) -> Int {
  case zoom {
    Fit -> length
    Scaled(percent) ->
      case length * percent / 100 {
        0 -> 1
        size -> size
      }
  }
}
