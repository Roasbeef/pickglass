import gleam/list
import pickglass_core/unit.{Bytes, Count, Nanoseconds, Ratio, Reductions}

// Every unit written to a capture must read back as itself, or a capture
// written by one build would change meaning when opened by the next.
pub fn every_unit_round_trips_test() {
  let units = [Bytes, Count, Reductions, Nanoseconds, Ratio(per: 10_000)]
  use u <- list.each(units)
  assert unit.parse(unit.to_string(u)) == Ok(u)
}

// Words are deliberately not a unit, and a ratio needs a positive
// denominator; both must be refused rather than guessed at.
pub fn unknown_and_degenerate_units_are_refused_test() {
  assert unit.parse("words") == Error(Nil)
  assert unit.parse("ratio/0") == Error(Nil)
  assert unit.parse("ratio/-5") == Error(Nil)
  assert unit.parse("ratio/") == Error(Nil)
}
