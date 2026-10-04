import gleam/int
import gleam/list
import pickglass_agent/census
import pickglass_agent/internal/ffi_term.{coerce}
import pickglass_agent/owner.{Unknown}

type Mfa {
  Lists
  Map
}

// A census of the test node returns at most K rows ordered by memory, and
// attributes every unlabelled process to Unknown.
pub fn census_is_bounded_and_ordered_test() {
  let report = census.run(census.Budget(100_000, 5, 2000))
  let memories = list.map(report.rows, fn(row) { row.memory })

  assert list.length(report.rows) <= 5
  assert report.rows != []
  assert report.coverage.scanned > 0
  assert report.coverage.stop == census.Finished
  assert memories == list.reverse(list.sort(memories, int.compare))
  assert list.any(report.aggregates, fn(a) { a.owner == Unknown })
}

// A scan budget below the process count stops the walk and says so.
pub fn scan_budget_truncates_test() {
  let report = census.run(census.Budget(3, 5, 2000))

  assert report.coverage.stop == census.ScanBudget
  assert report.coverage.scanned == 3
}

pub fn function_text_renders_or_blanks_test() {
  assert census.function_text(coerce(#(Lists, Map, 2))) == "lists:map/2"
  assert census.function_text(coerce(0)) == ""
}
