import gleam/int
import gleam/list
import pickglass_agent/ets
import pickglass_agent/internal/ffi_ets
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Term, coerce}
import pickglass_agent/owner.{Owned, Unknown}

type TableOption {
  NamedTable
  Public
  Private
  Set
}

@external(erlang, "ets", "new")
fn new_table(name: ffi_term.Atom, options: List(TableOption)) -> Term

@external(erlang, "ets", "insert")
fn insert(table: Term, object: #(Int, Int)) -> Bool

@external(erlang, "ets", "delete")
fn delete(table: Term) -> Bool

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

fn fill(table: Term, count: Int) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let _ = insert(table, #(count, count))

      fill(table, count - 1)
    }
  }
}

// A named table is listed with its name, owner, type and protection, and its
// size is the object count and its memory is in bytes. Its objects are never
// read: the listing has no field that could carry one.
pub fn a_named_table_is_listed_by_properties_test() {
  let table =
    new_table(ffi_term.atom("pg_ets_named_probe"), [NamedTable, Public, Set])
  fill(table, 500)

  let report = ets.run(ets.Budget(500, 2000))
  let assert Ok(found) =
    list.find(report.tables, fn(entry) { entry.name == "pg_ets_named_probe" })

  assert found.objects == 500
  assert found.kind == "set"
  assert found.protection == "public"
  assert found.memory_bytes > 500
  assert found.owner_pid == ffi_proc.self()
  assert found.heir == ""
  assert report.coverage.stop == ets.Finished
  assert report.totals.tables == report.coverage.counted
  assert report.totals.objects >= 500

  let _ = delete(table)
}

// An unnamed table has an empty name and a text identifier, and the listing
// is ordered by memory with at most K entries, while the totals cover every
// table read.
pub fn the_listing_is_bounded_and_ordered_test() {
  let table = new_table(ffi_term.atom("pg_ets_unnamed_probe"), [Private, Set])
  fill(table, 100)

  let report = ets.run(ets.Budget(3, 2000))
  let memories = list.map(report.tables, fn(entry) { entry.memory_bytes })

  assert list.length(report.tables) <= 3
  assert memories == list.reverse(list.sort(memories, int.compare))
  assert list.fold(report.tables, 0, fn(sum, entry) { sum + entry.memory_bytes })
    <= report.totals.memory_bytes
  assert report.coverage.total >= report.coverage.counted

  let _ = delete(table)
}

// The owner of a listed table is the decoded label of the process that owns
// it, and a process with no label is `Unknown`. The tables are owned by
// processes of their own, because the test process may already be labelled.
pub fn the_owner_label_is_decoded_test() {
  let #(plain, _) =
    ffi_proc.spawn_opt(
      fn() {
        let _ =
          new_table(ffi_term.atom("pg_ets_unlabelled"), [
            NamedTable,
            Public,
            Set,
          ])

        sleep(3000)
      },
      [ffi_proc.Monitor],
    )
  let #(labelled, _) =
    ffi_proc.spawn_opt(
      fn() {
        owner.claim_self()

        let _ =
          new_table(ffi_term.atom("pg_ets_labelled"), [NamedTable, Public, Set])

        sleep(3000)
      },
      [ffi_proc.Monitor],
    )

  sleep(200)

  let report = ets.run(ets.Budget(500, 2000))
  let assert Ok(unowned) =
    list.find(report.tables, fn(entry) { entry.name == "pg_ets_unlabelled" })
  let assert Ok(owned) =
    list.find(report.tables, fn(entry) { entry.name == "pg_ets_labelled" })

  assert unowned.owner == Unknown
  assert unowned.owner_pid == plain
  assert owned.owner == Owned([#("tool", "pickglass")], "agent")
  assert owned.owner_pid == labelled

  let _ = ffi_proc.exit_with(plain, ffi_proc.Kill)
  let _ = ffi_proc.exit_with(labelled, ffi_proc.Kill)

  Nil
}

// A table deleted after the list was built is counted as skipped and the
// walk goes on. The step deletes a table that has not been read yet; which one
// is last in the list is not specified, so every other probe table goes.
pub fn a_table_deleted_mid_walk_is_counted_test() {
  let tables =
    list.index_map(list.repeat(0, 40), fn(_, index) {
      new_table(ffi_term.atom("pg_ets_vanish_" <> int.to_string(index)), [
        NamedTable,
        Public,
        Set,
      ])
    })
  let before = list.length(ffi_ets.all())
  let walked =
    ets.walk(ffi_proc.now_ms(), 2000, 0, fn(seen, _table) {
      case seen {
        0 -> {
          list.each(tables, fn(table) {
            let _ = delete(table)
          })
          1
        }
        _ -> seen + 1
      }
    })

  assert walked.total >= before
  assert walked.skipped > 0
  assert walked.counted + walked.skipped == walked.total
  assert walked.state == walked.counted
  assert walked.stop == ets.Finished
}

// A deadline already in the past stops the walk at the first clock check and
// says so, with tables unread.
pub fn a_spent_deadline_stops_the_walk_test() {
  let walked = ets.walk(ffi_proc.now_ms() - 10_000, 1, 0, fn(n, _) { n + 1 })

  assert walked.stop == ets.Deadline
  assert walked.counted < walked.total
}

pub fn owner_of_caches_per_process_test() {
  let #(first, cache) = ets.owner_of(ffi_ets.cache_new(), ffi_proc.self())
  let #(second, _) = ets.owner_of(cache, ffi_proc.self())

  assert first == second
  assert coerce(first) == coerce(second)
  sleep(0)
}
