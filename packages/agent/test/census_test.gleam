import gleam/int
import gleam/list
import pickglass_agent/census
import pickglass_agent/ets
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
  let report = census.run(census.Budget(100_000, 5, 2000, census.Basic))
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
  let report = census.run(census.Budget(3, 5, 2000, census.Basic))

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
  let report = census.run(census.Budget(100_000, 5, 2000, census.Basic))
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

  let report = census.run(census.Budget(100_000, 5, 2000, census.Basic))
  let mine = Owned([#("tool", "pickglass")], "agent")

  assert list.any(report.aggregates, fn(a) {
    a.owner == mine && a.processes >= 1 && a.total_heap_words > 0
  })
}

// An extended census carries each row's initial call and attributes the
// memory of ETS tables to the owner of the process that owns them. A table
// owned by an unlabelled process lands under Unknown; one owned by a labelled
// process under its owner.
pub fn extended_census_attributes_ets_to_owners_test() {
  owner.claim_self()

  let table =
    new_table(ffi_term.atom("pg_census_ets_probe"), [NamedTable, Public])
  fill(table, 2000)

  let report = census.run(census.Budget(100_000, 5, 2000, census.Extended))
  let mine = Owned([#("tool", "pickglass")], "agent")
  let listed_bytes =
    list.fold(report.aggregates, 0, fn(sum, a) { sum + a.ets_bytes })

  assert list.any(report.aggregates, fn(a) {
    a.owner == mine && a.ets_tables >= 1 && a.ets_bytes > 2000
  })
  assert report.ets.tables >= 1
  assert listed_bytes <= report.ets.memory_bytes
  assert report.ets.stop == ets.Finished

  let _ = delete(table)
}

// A basic census reads no tables: every owner's ETS figures are zero.
pub fn basic_census_reads_no_tables_test() {
  let report = census.run(census.Budget(100_000, 5, 2000, census.Basic))

  assert report.ets.tables == 0
  assert list.all(report.aggregates, fn(a) {
    a.ets_tables == 0 && a.ets_bytes == 0
  })
}

// A process started by `proc_lib` has its `$initial_call` in the dictionary,
// and the extended census returns it; a spawned closure has none.
pub fn extended_rows_carry_the_proc_lib_call_test() {
  let report = census.run(census.Budget(100_000, 200, 2000, census.Extended))
  let calls =
    list.map(report.rows, fn(row) { census.function_text(row.proc_lib_call) })

  assert list.any(calls, fn(call) { call != "" })
}

type TableOption {
  NamedTable
  Public
}

@external(erlang, "ets", "new")
fn new_table(name: ffi_term.Atom, options: List(TableOption)) -> ffi_term.Term

@external(erlang, "ets", "insert")
fn insert(table: ffi_term.Term, object: #(Int, Int)) -> Bool

@external(erlang, "ets", "delete")
fn delete(table: ffi_term.Term) -> Bool

fn fill(table: ffi_term.Term, count: Int) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let _ = insert(table, #(count, count))

      fill(table, count - 1)
    }
  }
}
