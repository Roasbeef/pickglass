//// Colour classes for charts, from a closed set.
////
//// A chart box is coloured by the package of its function, hashed by core to
//// one of 24 buckets, and a differential box by the sign and size of its
//// change. The page's content security policy refuses inline styles built
//// from data, and a stylesheet generator that scans source for class names
//// cannot see a name assembled from an integer. So each class here is a
//// whole literal string chosen by a `case`, and `priv/pickglass.css`
//// defines every one of them.
////
//// ## Reading order
////
//// `hue` maps a bucket to one of `hue-0` to `hue-23`; `diff` maps a signed
//// change and the value it applies to one of seven diff classes, three
//// intensities each side of `diff-same`.

import gleam/int

/// The class for a package bucket from `layout/flame`'s `colour_bucket`.
/// A bucket outside 0 to 23 takes the first class, so a bad bucket draws a
/// colour instead of failing.
///
/// ## Examples
///
/// ```gleam
/// colour.hue(5)
/// // -> "hue-5"
/// ```
pub fn hue(bucket: Int) -> String {
  case int.modulo(bucket, 24) {
    Ok(0) -> "hue-0"
    Ok(1) -> "hue-1"
    Ok(2) -> "hue-2"
    Ok(3) -> "hue-3"
    Ok(4) -> "hue-4"
    Ok(5) -> "hue-5"
    Ok(6) -> "hue-6"
    Ok(7) -> "hue-7"
    Ok(8) -> "hue-8"
    Ok(9) -> "hue-9"
    Ok(10) -> "hue-10"
    Ok(11) -> "hue-11"
    Ok(12) -> "hue-12"
    Ok(13) -> "hue-13"
    Ok(14) -> "hue-14"
    Ok(15) -> "hue-15"
    Ok(16) -> "hue-16"
    Ok(17) -> "hue-17"
    Ok(18) -> "hue-18"
    Ok(19) -> "hue-19"
    Ok(20) -> "hue-20"
    Ok(21) -> "hue-21"
    Ok(22) -> "hue-22"
    Ok(23) -> "hue-23"
    Ok(_) | Error(_) -> "hue-0"
  }
}

/// The class for a differential box. Positive is a regression and is red;
/// negative is an improvement and is green. The intensity is the change's
/// share of the box's value: under 5 percent is faint, under 25 medium,
/// above that strong.
///
/// ## Examples
///
/// ```gleam
/// colour.diff(delta: 30, of: 100)
/// // -> "diff-up-3"
/// ```
pub fn diff(delta delta: Int, of value: Int) -> String {
  case delta {
    0 -> "diff-same"
    d if d > 0 ->
      case intensity(d, value) {
        1 -> "diff-up-1"
        2 -> "diff-up-2"
        _ -> "diff-up-3"
      }
    d ->
      case intensity(-d, value) {
        1 -> "diff-down-1"
        2 -> "diff-down-2"
        _ -> "diff-down-3"
      }
  }
}

fn intensity(magnitude: Int, value: Int) -> Int {
  case value <= 0 {
    True -> 3
    False ->
      case magnitude * 100 / value {
        pct if pct < 5 -> 1
        pct if pct < 25 -> 2
        _ -> 3
      }
  }
}
