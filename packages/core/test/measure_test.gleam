import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pg_data_gen as gen
import pickglass_core/measure.{
  Additive, Known, Missing, NotApplicable, Overlapping, ProcessExited, Total,
}
import pickglass_core/unit.{Bytes, Ratio}

// An absent reading must have no numeric reading at all: `to_option` is
// the only accessor and it says `None`.
pub fn absent_readings_have_no_value_test() {
  assert measure.to_option(Known(0)) == Some(0)
  assert measure.to_option(Missing(ProcessExited)) == None
  assert measure.to_option(NotApplicable) == None
}

// Rendering an absent reading must produce a word, never a digit.
pub fn absent_readings_render_as_words_test() {
  assert measure.render(Missing(ProcessExited), Bytes)
    == "missing (process_exited)"
  assert measure.render(NotApplicable, Bytes) == "n/a"
  assert measure.render(Known(0), Bytes) == "0 bytes"
}

pub fn property_absent_readings_never_render_a_digit_test() {
  use reason <- gen.check(gen.missing_reason())
  let text = measure.render(Missing(reason), Bytes)
  let digits = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
  assert !list.any(digits, fn(digit) { string.contains(text, digit) })
}

pub fn property_missing_reason_codes_round_trip_test() {
  use reason <- gen.check(gen.missing_reason())
  assert measure.parse_missing_reason(measure.missing_reason_code(reason))
    == Ok(reason)
}

pub fn unknown_codes_are_refused_test() {
  assert measure.parse_missing_reason("zero") == Error(Nil)
  assert measure.parse_kind("rate") == Error(Nil)
  assert measure.parse_scope("galaxy") == Error(Nil)
  assert measure.parse_truncation("") == Error(Nil)
  assert measure.parse_partial("truncated:") == Error(Nil)
  assert measure.parse_partial("truncated:nonsense") == Error(Nil)
}

pub fn property_partial_codes_round_trip_test() {
  use outcome <- gen.check(gen.outcome())
  case outcome {
    measure.Partial(reason:) -> {
      assert measure.parse_partial(measure.partial_code(reason)) == Ok(reason)
    }
    measure.Complete
    | measure.Refused(_)
    | measure.Errored(_)
    | measure.Unrecorded -> Nil
  }
}

// Missing rows are counted beside the total, not added into it as zero.
pub fn sum_counts_absent_rows_separately_test() {
  let rows = [Known(3), Missing(ProcessExited), Known(4), NotApplicable]
  assert measure.sum(Bytes, Additive, rows)
    == Ok(Total(value: 7, known: 2, missing: 1, not_applicable: 1))
}

// A column with no known row has no total; zero would be a fabrication.
pub fn sum_of_nothing_known_is_refused_test() {
  assert measure.sum(Bytes, Additive, []) == Error(measure.NothingKnown)
  assert measure.sum(Bytes, Additive, [Missing(ProcessExited), NotApplicable])
    == Error(measure.NothingKnown)
}

// An overlapping column is refused no matter what it contains.
pub fn sum_refuses_overlapping_columns_test() {
  assert measure.sum(Bytes, Overlapping("shared binaries"), [Known(1)])
    == Error(measure.OverlappingRows("shared binaries"))
  assert measure.sum(Bytes, Overlapping("x"), [])
    == Error(measure.OverlappingRows("x"))
}

pub fn sum_refuses_ratios_test() {
  assert measure.sum(Ratio(per: 100), Additive, [Known(1), Known(2)])
    == Error(measure.RatioDoesNotAdd)
}

// Whatever the rows, `sum` either refuses or returns a total equal to the
// sum of exactly the known rows, with the other rows counted.
pub fn property_sum_matches_known_rows_test() {
  use rows <- gen.check(gen.small_list(gen.measurement()))
  let known =
    list.filter_map(rows, fn(row) {
      option.to_result(measure.to_option(row), Nil)
    })

  case measure.sum(Bytes, Additive, rows) {
    Ok(total) -> {
      assert total.value == list.fold(known, 0, fn(a, b) { a + b })
      assert total.known == list.length(known)
      assert total.known + total.missing + total.not_applicable
        == list.length(rows)
    }
    Error(refusal) -> {
      assert refusal == measure.NothingKnown
      assert known == []
    }
  }
}

pub fn property_overlapping_never_sums_test() {
  use #(rows, why) <- gen.check(qcheck_pair())
  assert measure.sum(Bytes, Overlapping(why), rows)
    == Error(measure.OverlappingRows(why))
}

fn qcheck_pair() {
  gen.tuple2(gen.small_list(gen.measurement()), gen.text())
}

pub fn totals_with_missing_rows_render_as_lower_bounds_test() {
  assert measure.render_total(Total(7, 2, 1, 0), Bytes)
    == "at least 7 bytes (2 of 3 rows known)"
  assert measure.render_total(Total(7, 2, 0, 0), Bytes) == "7 bytes"
}

pub fn series_sum_uses_its_own_additivity_test() {
  let series =
    measure.Series(
      id: 1,
      kind: measure.Gauge,
      unit: Bytes,
      additivity: Overlapping("refc"),
      method: "m",
      scope: measure.ProcessScope,
      subject: "s",
      cadence: measure.OneShot,
    )
  assert measure.sum_series(series, [Known(1)])
    == Error(measure.OverlappingRows("refc"))
  assert measure.sum_series(measure.Series(..series, additivity: Additive), [
      Known(1),
    ])
    == Ok(Total(1, 1, 0, 0))
}

pub fn is_complete_only_for_complete_test() {
  assert measure.is_complete(measure.Complete)
  assert !measure.is_complete(measure.Partial(measure.NoFooter))
  assert !measure.is_complete(measure.Refused("x"))
  assert !measure.is_complete(measure.Errored("x"))
}
