import gleam/int
import gleam/list
import pickglass_agent/census
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{coerce}
import pickglass_agent/owner.{Owned, Unknown}

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

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

// The totals cover every scanned process, and an owner's heap capacity is
// carried beside its memory, so a remainder row has real numbers to subtract.
pub fn totals_cover_every_scanned_process_test() {
  let report = census.run(census.Budget(100_000, 5, 2000))
  let listed_heap =
    list.fold(report.aggregates, 0, fn(sum, a) { sum + a.total_heap_words })
  let listed_processes =
    list.fold(report.aggregates, 0, fn(sum, a) { sum + a.processes })

  assert report.totals.processes == report.coverage.scanned
  assert report.totals.owners_listed == list.length(report.aggregates)
  assert report.totals.owners_tracked >= report.totals.owners_listed
  assert listed_heap <= report.totals.total_heap_words
  assert listed_processes <= report.totals.processes
  assert report.totals.total_heap_words > 0
}

// A labelled process is attributed to its owner, with its heap counted.
pub fn labelled_processes_aggregate_by_owner_test() {
  let _ =
    ffi_proc.spawn_opt(
      fn() {
        owner.claim_self()
        sleep(3000)
      },
      [],
    )
  sleep(50)

  let report = census.run(census.Budget(100_000, 5, 2000))
  let mine = Owned([#("tool", "pickglass")], "agent")

  assert list.any(report.aggregates, fn(a) {
    a.owner == mine && a.processes >= 1 && a.total_heap_words > 0
  })
}
