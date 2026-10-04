//// Measurements, the series that describe them, and the coverage of a
//// collection.
////
//// The recurring failure of memory tooling is a number that is not what it
//// looks like: a counter that could not be read and was shown as zero, a
//// per-process column that overlaps and was summed into a total, a
//// truncated census presented as the whole node. This module makes each of
//// those a type rather than a habit.
////
//// A `Measurement` is `Known`, `Missing` with a closed reason, or
//// `NotApplicable`. There is no function here that turns an absent
//// measurement into an `Int`: `to_option` returns `None`, `render` returns
//// a word, and `sum` counts absent rows separately instead of adding them.
//// An `Additivity` is declared once per series, and `sum` refuses an
//// `Overlapping` series outright. A `Coverage` record says how much of what
//// was requested a collection achieved and why it stopped early.
////
//// ## Flow
////
//// - `to_option` and `render` read one measurement.
//// - `sum` totals a column of them, honoring `Additivity`.
//// - `Series` describes a column; `Coverage` describes a collection.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pickglass_core/unit.{type Unit}

// ------------------------------------------------------------ measurement

/// One reading of one counter for one subject.
pub type Measurement {
  /// The counter was read and has this value in the series' unit.
  Known(value: Int)

  /// The counter could not be read, for a reason from a closed list.
  Missing(reason: MissingReason)

  /// The counter does not exist for this subject, for example a heap size
  /// for a port.
  NotApplicable
}

/// Why a counter could not be read. The list is closed so a capture can
/// record the reason as a stable code and a reader can refuse an unknown one.
pub type MissingReason {
  /// The subject exited before the read.
  ProcessExited

  /// The counter exists but is switched off in the target.
  CounterDisabled

  /// The operating system does not provide the counter.
  UnsupportedOnPlatform

  /// This OTP release or emulator does not provide the counter.
  UnsupportedOnRuntime

  /// The collection budget ran out before this row.
  BudgetExhausted

  /// The collection deadline passed before this row.
  DeadlineReached

  /// The agent's reply for this row did not decode.
  DecodeFailed
}

/// Every missing reason, for codecs and exhaustive tests.
pub const all_missing_reasons: List(MissingReason) = [
  ProcessExited,
  CounterDisabled,
  UnsupportedOnPlatform,
  UnsupportedOnRuntime,
  BudgetExhausted,
  DeadlineReached,
  DecodeFailed,
]

/// The stable code of a missing reason, used in capture files.
///
/// ## Examples
///
/// ```gleam
/// measure.missing_reason_code(ProcessExited)
/// // -> "process_exited"
/// ```
pub fn missing_reason_code(reason: MissingReason) -> String {
  case reason {
    ProcessExited -> "process_exited"
    CounterDisabled -> "counter_disabled"
    UnsupportedOnPlatform -> "unsupported_on_platform"
    UnsupportedOnRuntime -> "unsupported_on_runtime"
    BudgetExhausted -> "budget_exhausted"
    DeadlineReached -> "deadline_reached"
    DecodeFailed -> "decode_failed"
  }
}

/// Parse a code written by `missing_reason_code`. Any other text is an
/// error, never a default reason.
///
/// ## Examples
///
/// ```gleam
/// measure.parse_missing_reason("deadline_reached")
/// // -> Ok(DeadlineReached)
///
/// measure.parse_missing_reason("zero")
/// // -> Error(Nil)
/// ```
pub fn parse_missing_reason(code: String) -> Result(MissingReason, Nil) {
  list.find(all_missing_reasons, fn(reason) {
    missing_reason_code(reason) == code
  })
}

/// The value if the measurement is `Known`, and `None` otherwise. `None`
/// is the only answer for an absent reading: there is no accessor with a
/// default.
///
/// ## Examples
///
/// ```gleam
/// measure.to_option(Known(7))
/// // -> Some(7)
///
/// measure.to_option(Missing(ProcessExited))
/// // -> None
/// ```
pub fn to_option(measurement: Measurement) -> Option(Int) {
  case measurement {
    Known(value:) -> Some(value)
    Missing(_) | NotApplicable -> None
  }
}

/// Render a measurement for a person. A reading shows its value and unit;
/// an absent one shows a word that says why, never a number.
///
/// ## Examples
///
/// ```gleam
/// measure.render(Known(2048), Bytes)
/// // -> "2048 bytes"
///
/// measure.render(Missing(ProcessExited), Bytes)
/// // -> "missing (process_exited)"
///
/// measure.render(NotApplicable, Bytes)
/// // -> "n/a"
/// ```
pub fn render(measurement: Measurement, in u: Unit) -> String {
  case measurement {
    Known(value:) -> int.to_string(value) <> " " <> unit.to_string(u)
    Missing(reason:) -> "missing (" <> missing_reason_code(reason) <> ")"
    NotApplicable -> "n/a"
  }
}

// ------------------------------------------------------------ additivity

/// Whether the rows of a column may be added into a group total.
pub type Additivity {
  /// Rows are disjoint, so their sum is meaningful.
  Additive

  /// Rows may share the thing measured, for example per-process counts of
  /// references to the same reference-counted binary. A sum would count
  /// shared bytes more than once, so none is produced.
  Overlapping(why: String)
}

/// The sum of the known rows of a column, with the rows that were not
/// known counted beside it so the total can never read as complete when it
/// is not.
pub type Total {
  Total(
    /// The sum of the `Known` rows.
    value: Int,
    /// How many rows were `Known`. Always at least one.
    known: Int,
    /// How many rows were `Missing`. When this is above zero the value is a
    /// lower bound only for a non-negative column.
    missing: Int,
    /// How many rows were `NotApplicable`; these are excluded, not missing.
    not_applicable: Int,
  )
}

/// Why `sum` produced no total.
pub type SumRefusal {
  /// The series is `Overlapping`; the string is its declared reason.
  OverlappingRows(why: String)

  /// Ratios have a per-series denominator and do not add.
  RatioDoesNotAdd

  /// No row was `Known`, so any number would be a fabrication.
  NothingKnown
}

/// Add the rows of a column.
///
/// An `Overlapping` column and a `Ratio` column are refused. Absent rows
/// are counted in the result, not treated as zero, and a column with no
/// known row at all is refused rather than totalled as zero.
///
/// ## Examples
///
/// ```gleam
/// measure.sum(Bytes, Additive, [Known(3), Missing(ProcessExited), Known(4)])
/// // -> Ok(Total(value: 7, known: 2, missing: 1, not_applicable: 0))
///
/// measure.sum(Bytes, Overlapping("shared binaries"), [Known(3)])
/// // -> Error(OverlappingRows("shared binaries"))
/// ```
pub fn sum(
  unit u: Unit,
  additivity additivity: Additivity,
  rows rows: List(Measurement),
) -> Result(Total, SumRefusal) {
  case additivity, u {
    Overlapping(why:), _ -> Error(OverlappingRows(why))
    Additive, unit.Ratio(_) -> Error(RatioDoesNotAdd)
    Additive, _ -> total_of(rows)
  }
}

// Fold the rows into counts. The accumulator starts with `known: 0`, and a
// zero never escapes: `total_of` refuses a column where none was known.
fn total_of(rows: List(Measurement)) -> Result(Total, SumRefusal) {
  let empty = Total(value: 0, known: 0, missing: 0, not_applicable: 0)
  let total = list.fold(rows, empty, add_row)

  case total.known {
    0 -> Error(NothingKnown)
    _ -> Ok(total)
  }
}

fn add_row(total: Total, row: Measurement) -> Total {
  case row {
    Known(value:) ->
      Total(..total, value: total.value + value, known: total.known + 1)

    Missing(_) -> Total(..total, missing: total.missing + 1)

    NotApplicable -> Total(..total, not_applicable: total.not_applicable + 1)
  }
}

/// Render a total, marking it as a lower bound when rows were missing.
///
/// ## Examples
///
/// ```gleam
/// measure.render_total(Total(7, 2, 1, 0), Bytes)
/// // -> "at least 7 bytes (2 of 3 rows known)"
/// ```
pub fn render_total(total: Total, in u: Unit) -> String {
  let value = int.to_string(total.value) <> " " <> unit.to_string(u)

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

// ---------------------------------------------------------------- series

/// How a series' values relate to time.
pub type SeriesKind {
  /// A level read at an instant, such as bytes in use.
  Gauge

  /// A monotonically increasing count, such as reductions.
  Counter

  /// The change of a counter over the sampling interval.
  DeltaOverInterval
}

/// What a series is measured about.
pub type Scope {
  /// The whole target node.
  NodeScope

  /// One process.
  ProcessScope

  /// One owner path.
  OwnerScope

  /// One OS process.
  OsProcessScope
}

/// How often a series was requested to be read.
pub type Cadence {
  /// Read once, for example by `attach --once`.
  OneShot

  /// Read at a fixed interval in milliseconds.
  EveryMs(interval_ms: Int)
}

/// The metadata of one column of samples.
pub type Series {
  Series(
    /// The series id the `samples` records refer to.
    id: Int,
    kind: SeriesKind,
    unit: Unit,
    /// Whether rows may be added.
    additivity: Additivity,
    /// The collector, API and parameters that produced the values, as a
    /// stable identifier. Two series with different methods are not
    /// comparable.
    method: String,
    scope: Scope,
    /// The subject within the scope, such as an owner path or a pin.
    subject: String,
    cadence: Cadence,
  )
}

/// Total the rows of a series, using the unit and additivity it declares.
///
/// ## Examples
///
/// ```gleam
/// measure.sum_series(series, [Known(1), Known(2)])
/// ```
pub fn sum_series(
  series: Series,
  rows: List(Measurement),
) -> Result(Total, SumRefusal) {
  sum(series.unit, series.additivity, rows)
}

/// The stable code of a series kind.
pub fn kind_code(kind: SeriesKind) -> String {
  case kind {
    Gauge -> "gauge"
    Counter -> "counter"
    DeltaOverInterval -> "delta"
  }
}

/// Parse a series kind code; any other text is an error.
pub fn parse_kind(code: String) -> Result(SeriesKind, Nil) {
  list.find([Gauge, Counter, DeltaOverInterval], fn(kind) {
    kind_code(kind) == code
  })
}

/// The stable code of a scope.
pub fn scope_code(scope: Scope) -> String {
  case scope {
    NodeScope -> "node"
    ProcessScope -> "process"
    OwnerScope -> "owner"
    OsProcessScope -> "os_process"
  }
}

/// Parse a scope code; any other text is an error.
pub fn parse_scope(code: String) -> Result(Scope, Nil) {
  list.find([NodeScope, ProcessScope, OwnerScope, OsProcessScope], fn(scope) {
    scope_code(scope) == code
  })
}

// -------------------------------------------------------------- coverage

/// Why a collection stopped before it covered what was asked.
pub type TruncationReason {
  /// Only the top K rows were kept by design.
  TopKLimit

  /// The event or sample budget ran out.
  BudgetReached

  /// The collection deadline passed.
  DeadlineHit

  /// A bounded ring overwrote older records.
  RingOverflow

  /// A scan limit, such as bytes unscanned, stopped the walk.
  ScanLimit
}

/// Why a capture or collection is less than complete.
pub type PartialReason {
  /// The capture file ended without a footer: it may be cut short.
  NoFooter

  /// The footer's record counts disagree with the records read.
  FooterCountMismatch

  /// The collection was cut short for the stated reason.
  Truncated(reason: TruncationReason)
}

/// How a collection ended.
pub type Outcome {
  /// Everything requested was collected.
  Complete

  /// Some of what was requested was collected.
  Partial(reason: PartialReason)

  /// The agent declined to run the collection; the string says why.
  Refused(reason: String)

  /// The collection failed; the string says why.
  Errored(reason: String)

  /// The capture does not say how the collection ended. It is not
  /// `Complete`: an older capture, or one written before the outcome was
  /// kept, may hide a probe that was cut short.
  Unrecorded
}

/// What one collection covered.
pub type Coverage {
  Coverage(
    /// What was collected, such as `census` or `probe:counters`.
    scope: String,
    /// The budget that was requested, in the collection's own unit.
    requested: Int,
    /// What was achieved against that budget.
    achieved: Int,
    outcome: Outcome,
    /// Events dropped before they were read, if the collector can count.
    dropped_events: Measurement,
    /// Events that arrived after the budget was reached.
    in_flight_events: Measurement,
    /// Bytes of a scan that were not read.
    unscanned_bytes: Measurement,
  )
}

/// The stable code of a truncation reason.
pub fn truncation_code(reason: TruncationReason) -> String {
  case reason {
    TopKLimit -> "top_k_limit"
    BudgetReached -> "budget_reached"
    DeadlineHit -> "deadline_hit"
    RingOverflow -> "ring_overflow"
    ScanLimit -> "scan_limit"
  }
}

/// Parse a truncation code; any other text is an error.
pub fn parse_truncation(code: String) -> Result(TruncationReason, Nil) {
  list.find(
    [TopKLimit, BudgetReached, DeadlineHit, RingOverflow, ScanLimit],
    fn(reason) { truncation_code(reason) == code },
  )
}

/// The stable code of a partial reason, with the truncation reason after a
/// colon when there is one.
///
/// ## Examples
///
/// ```gleam
/// measure.partial_code(NoFooter)
/// // -> "no_footer"
///
/// measure.partial_code(Truncated(TopKLimit))
/// // -> "truncated:top_k_limit"
/// ```
pub fn partial_code(reason: PartialReason) -> String {
  case reason {
    NoFooter -> "no_footer"
    FooterCountMismatch -> "footer_count_mismatch"
    Truncated(reason:) -> "truncated:" <> truncation_code(reason)
  }
}

/// Parse a partial-reason code written by `partial_code`.
pub fn parse_partial(code: String) -> Result(PartialReason, Nil) {
  case code {
    "no_footer" -> Ok(NoFooter)
    "footer_count_mismatch" -> Ok(FooterCountMismatch)
    "truncated:" <> reason -> parse_truncation(reason) |> result.map(Truncated)
    _ -> Error(Nil)
  }
}

/// Whether the outcome is `Complete`. A caller that wants to show a
/// banner asks this rather than matching, so a new outcome cannot be
/// treated as complete by accident.
pub fn is_complete(outcome: Outcome) -> Bool {
  case outcome {
    Complete -> True
    Partial(_) | Refused(_) | Errored(_) | Unrecorded -> False
  }
}
