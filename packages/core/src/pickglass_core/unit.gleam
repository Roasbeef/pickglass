//// The units every pickglass measurement is expressed in.
////
//// A number with no unit is the source of most misread profiles: a
//// reduction count read as time, a word count read as bytes. Pickglass
//// therefore carries the unit beside every series, profile value type and
//// export, and this module is the one closed list of them. `Reductions` is
//// its own unit rather than a kind of count so that no code path can turn
//// a VM work counter into seconds; words are not a unit at all, because the
//// agent converts them to bytes with the target's word size before a value
//// leaves the target.

import gleam/int

/// The unit of a measured value.
pub type Unit {
  /// Bytes of memory or data.
  Bytes

  /// A plain count of things: processes, calls, samples, messages.
  Count

  /// BEAM reductions, a VM work counter. It is not time and never converts
  /// to time.
  Reductions

  /// Nanoseconds of wall-clock or measured duration.
  Nanoseconds

  /// A ratio expressed as parts per `per`, for example utilization in parts
  /// per 10,000.
  Ratio(per: Int)
}

/// The unit's stable name, used in capture files and exports.
///
/// ## Examples
///
/// ```gleam
/// unit.to_string(Reductions)
/// // -> "reductions"
///
/// unit.to_string(Ratio(per: 10_000))
/// // -> "ratio/10000"
/// ```
pub fn to_string(unit: Unit) -> String {
  case unit {
    Bytes -> "bytes"
    Count -> "count"
    Reductions -> "reductions"
    Nanoseconds -> "nanoseconds"
    Ratio(per:) -> "ratio/" <> int.to_string(per)
  }
}

/// Parse a unit name written by `to_string`. Any other text is an error,
/// never a guess, so a capture with a unit this build does not know is
/// reported rather than read as counts.
///
/// ## Examples
///
/// ```gleam
/// unit.parse("bytes")
/// // -> Ok(Bytes)
///
/// unit.parse("ratio/100")
/// // -> Ok(Ratio(per: 100))
///
/// unit.parse("words")
/// // -> Error(Nil)
/// ```
pub fn parse(text: String) -> Result(Unit, Nil) {
  case text {
    "bytes" -> Ok(Bytes)
    "count" -> Ok(Count)
    "reductions" -> Ok(Reductions)
    "nanoseconds" -> Ok(Nanoseconds)
    "ratio/" <> per -> parse_ratio(per)
    _ -> Error(Nil)
  }
}

// A ratio's denominator must be a positive integer; zero or a negative
// denominator would make every value in the series meaningless.
fn parse_ratio(per: String) -> Result(Unit, Nil) {
  case int.parse(per) {
    Ok(per) if per > 0 -> Ok(Ratio(per:))
    Ok(_) | Error(_) -> Error(Nil)
  }
}
