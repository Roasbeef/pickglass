//// Number, size and duration text for the pages.
////
//// Every figure on a page passes through this module, so the rule that a
//// missing value is a word and never a number is kept in one place. A
//// `Measurement` that is `Known` is written in the unit's natural scale
//// (binary prefixes for bytes, thousands separators for counts, a percentage
//// for a ratio). A `Missing` or `NotApplicable` one is handed to
//// `measure.render`, which produces the word, and the page marks it with the
//// `word` class so it reads differently from a number.
////
//// All arithmetic is on integers. A byte count is scaled to hundredths of
//// its unit with integer division, then written with two, one or no decimals
//// depending on magnitude, so the text is deterministic and needs no float
//// formatting.
////
//// ## Reading order
////
//// `cell` and `signed` write a `Measurement`; `bytes`, `count`, `duration_ms`
//// and `ratio` write a bare integer; `is_word` tells a view whether a cell
//// should carry the `word` class.

import gleam/int
import gleam/list
import gleam/string
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/unit.{type Unit}

/// The minus sign used for negative deltas. It is U+2212, which lines up with
/// the plus sign in a tabular-figure font where a hyphen would not.
pub const minus: String = "−"

/// Write a count with a comma between each group of three digits.
///
/// ## Examples
///
/// ```gleam
/// fmt.count(3412)
/// // -> "3,412"
/// ```
pub fn count(n: Int) -> String {
  case n < 0 {
    True -> minus <> count(-n)
    False -> group_digits(int.to_string(n))
  }
}

// Insert separators by walking the digit string from the right in groups of
// three; the string is short, so the repeated slicing is not a concern.
fn group_digits(digits: String) -> String {
  case string.length(digits) <= 3 {
    True -> digits
    False -> {
      let head = string.drop_end(digits, 3)
      let tail = string.slice(digits, string.length(digits) - 3, 3)
      group_digits(head) <> "," <> tail
    }
  }
}

/// Write a byte count with a binary prefix: two decimals below 10 of a unit,
/// one below 100, none above.
///
/// ## Examples
///
/// ```gleam
/// fmt.bytes(190_000_000)
/// // -> "181 MiB"
///
/// fmt.bytes(1_932_735_283)
/// // -> "1.80 GiB"
///
/// fmt.bytes(512)
/// // -> "512 B"
/// ```
pub fn bytes(n: Int) -> String {
  case n < 0 {
    True -> minus <> bytes(-n)
    False -> scale_bytes(n, ["B", "KiB", "MiB", "GiB", "TiB"], 1)
  }
}

// Divide by 1024 until the value fits the unit, tracking the divisor, then
// format hundredths. The last unit in the list absorbs anything larger.
fn scale_bytes(n: Int, units: List(String), divisor: Int) -> String {
  case units {
    [only] -> with_decimals(n * 100 / divisor, only)
    [name, ..rest] ->
      case n < divisor * 1024 {
        True ->
          case divisor {
            1 -> int.to_string(n) <> " B"
            _ -> with_decimals(n * 100 / divisor, name)
          }
        False -> scale_bytes(n, rest, divisor * 1024)
      }
    [] -> int.to_string(n) <> " B"
  }
}

// Hundredths of a unit become "x.yz", "xx.y" or "xxx" by magnitude.
fn with_decimals(hundredths: Int, name: String) -> String {
  let whole = hundredths / 100
  let frac = hundredths % 100

  case whole {
    w if w < 10 -> int.to_string(w) <> "." <> pad2(frac) <> " " <> name
    w if w < 100 ->
      int.to_string(w) <> "." <> int.to_string(frac / 10) <> " " <> name
    w -> int.to_string(w) <> " " <> name
  }
}

fn pad2(n: Int) -> String {
  string.pad_start(int.to_string(n), 2, "0")
}

/// Write a duration given in nanoseconds in the largest unit that keeps the
/// number readable.
///
/// ## Examples
///
/// ```gleam
/// fmt.nanoseconds(1_500_000)
/// // -> "1.50 ms"
/// ```
pub fn nanoseconds(n: Int) -> String {
  case n {
    n if n < 1000 -> int.to_string(n) <> " ns"
    n if n < 1_000_000 -> with_decimals(n * 100 / 1000, "µs")
    n if n < 1_000_000_000 -> with_decimals(n * 100 / 1_000_000, "ms")
    n -> with_decimals(n * 100 / 1_000_000_000, "s")
  }
}

/// Write a duration given in milliseconds.
///
/// ## Examples
///
/// ```gleam
/// fmt.duration_ms(10_020)
/// // -> "10.02 s"
///
/// fmt.duration_ms(8_040_000)
/// // -> "2 h 14 min"
/// ```
pub fn duration_ms(ms: Int) -> String {
  case ms {
    ms if ms < 1000 -> int.to_string(ms) <> " ms"
    ms if ms < 60_000 -> with_decimals(ms / 10, "s")
    ms if ms < 3_600_000 ->
      int.to_string(ms / 60_000)
      <> " min "
      <> int.to_string(ms % 60_000 / 1000)
      <> " s"
    ms ->
      int.to_string(ms / 3_600_000)
      <> " h "
      <> int.to_string(ms % 3_600_000 / 60_000)
      <> " min"
  }
}

/// Write parts per `per` as a percentage with one decimal.
///
/// ## Examples
///
/// ```gleam
/// fmt.ratio(30, 10_000)
/// // -> "0.3%"
/// ```
pub fn ratio(value: Int, per: Int) -> String {
  let tenths = value * 1000 / per

  int.to_string(tenths / 10)
  <> "."
  <> int.to_string(int.absolute_value(tenths) % 10)
  <> "%"
}

/// Write a fraction given as `part` of `whole` as a percentage with one
/// decimal; a zero whole is shown as a dash rather than a division.
pub fn share(part: Int, of whole: Int) -> String {
  case whole {
    0 -> "–"
    _ -> ratio(part, whole)
  }
}

/// Write a known value in its unit's natural scale.
///
/// ## Examples
///
/// ```gleam
/// fmt.known(2048, unit.Bytes)
/// // -> "2.00 KiB"
/// ```
pub fn known(value: Int, in u: Unit) -> String {
  case u {
    unit.Bytes -> bytes(value)
    unit.Count -> count(value)
    unit.Reductions -> count(value)
    unit.Nanoseconds -> nanoseconds(value)
    unit.Ratio(per:) -> ratio(value, per)
  }
}

/// Write a total in its unit's natural scale, marked as a lower bound when
/// rows were missing. It is `measure.render_total` with the figure scaled,
/// so a byte total reads "1.19 GiB" and not a long integer.
///
/// ## Examples
///
/// ```gleam
/// fmt.total(Total(value: 3 * 1024 * 1024, known: 3, missing: 0, not_applicable: 0), unit.Bytes)
/// // -> "3.00 MiB"
/// ```
pub fn total(total: measure.Total, in u: Unit) -> String {
  let value = known(total.value, u)

  case total.missing {
    0 -> value
    missing ->
      "at least "
      <> value
      <> " ("
      <> int.to_string(total.known)
      <> " of "
      <> int.to_string(total.known + missing)
      <> " rows known)"
  }
}

/// Write a measurement: a known value in its scale, or the word that
/// `measure.render` gives for an absent one. A missing value is never
/// written as a number.
///
/// ## Examples
///
/// ```gleam
/// fmt.cell(Known(181 * 1024 * 1024), unit.Bytes)
/// // -> "181 MiB"
///
/// fmt.cell(Missing(CounterDisabled), unit.Bytes)
/// // -> "missing (counter_disabled)"
/// ```
pub fn cell(m: Measurement, in u: Unit) -> String {
  case m {
    Known(value:) -> known(value, u)
    _ -> measure.render(m, u)
  }
}

/// Write a change: a known value with an explicit sign, or the word for an
/// absent one. A known zero is written `0`, because it is a real reading.
///
/// ## Examples
///
/// ```gleam
/// fmt.signed(Known(188 * 1024 * 1024), unit.Bytes)
/// // -> "+188 MiB"
/// ```
pub fn signed(m: Measurement, in u: Unit) -> String {
  case m {
    Known(value:) if value > 0 -> "+" <> known(value, u)
    Known(value:) if value < 0 -> minus <> known(-value, u)
    Known(_) -> "0"
    _ -> measure.render(m, u)
  }
}

/// Whether a measurement renders as a word instead of a number, so the view
/// can give the cell the `word` class.
pub fn is_word(m: Measurement) -> WordOrNumber {
  case m {
    Known(_) -> Number
    _ -> Word
  }
}

/// Whether a cell holds a number or a word.
pub type WordOrNumber {
  /// A figure.
  Number

  /// A word standing for an absent reading.
  Word
}

/// Join text parts with the middle dot the title bars use.
///
/// ## Examples
///
/// ```gleam
/// fmt.dotted(["census", "10.0 s"])
/// // -> "census · 10.0 s"
/// ```
pub fn dotted(parts: List(String)) -> String {
  string.join(list.filter(parts, fn(part) { part != "" }), " · ")
}

/// Write a Unix time in milliseconds as the UTC time of day, with
/// milliseconds.
///
/// ## Examples
///
/// ```gleam
/// fmt.clock(1_700_000_062_118)
/// // -> "22:14:22.118"
/// ```
pub fn clock(unix_ms: Int) -> String {
  let day_ms = case int.modulo(unix_ms, 86_400_000) {
    Ok(ms) -> ms
    Error(Nil) -> 0
  }

  let hours = day_ms / 3_600_000
  let minutes = day_ms % 3_600_000 / 60_000
  let seconds = day_ms % 60_000 / 1000
  let millis = day_ms % 1000

  pad2(hours)
  <> ":"
  <> pad2(minutes)
  <> ":"
  <> pad2(seconds)
  <> "."
  <> string.pad_start(int.to_string(millis), 3, "0")
}
