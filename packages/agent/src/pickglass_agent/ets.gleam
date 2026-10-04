//// ETS tables: a bounded listing by memory, and the per-owner totals the
//// owners census attributes to the processes that own them.
////
//// A node's memory report has one `ets` category and nothing under it, so a
//// large table is invisible until something says which one it is. This module
//// reads each table's properties with `ets:info/1` and never its contents:
//// the properties are the size in objects, the memory in words, the owner, the
//// heir, the type and the protection, all of which are bounded terms. A table
//// whose objects are secret is described without being read.
////
//// A table can be deleted between `ets:all/0` listing it and the properties
//// being read. That is a normal event on a busy node and not an error: the
//// table is counted as skipped and the walk goes on, so the coverage shows how
//// many tables the numbers could not include. The walk is bounded by a
//// deadline checked every few hundred tables, and a deadline reached with
//// tables unread is the `Deadline` stop, never a quiet undercount.
////
//// `walk` is the loop; `run` uses it for the listing and the owners census
//// uses it to fold each table's memory into the owner of the process that owns
//// it. Neither sends anything: the server runs them in a worker with a heap
//// cap, which also bounds the one list `ets:all/0` builds.

import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_ets.{type Cache}
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/proc_info
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner, Unknown}
import pickglass_agent/topk

/// The most tables a listing returns.
pub const max_top_k = 500

/// The number of tables a listing returns when the viewer does not say.
pub const default_top_k = 100

/// How many tables to read between looks at the clock.
const clock_interval = 256

/// How much work one walk may do.
pub type Budget {
  Budget(top_k: Int, deadline_ms: Int)
}

/// Why a walk ended.
pub type Stop {
  /// Every table the list named was read or found deleted.
  Finished

  /// The deadline passed with tables unread.
  Deadline
}

/// One table as `ets:info/1` describes it. `name` is empty for a table that
/// has no name, `heir` is empty for a table with no heir, and `owner` is the
/// owner label of the owning process, `Unknown` until a caller resolves it.
/// `owner_name` is the owning process's registered name, empty for a process
/// with none, resolved with the label.
pub type Table {
  Table(
    id: String,
    name: String,
    owner_pid: Pid,
    owner: Owner,
    owner_name: String,
    kind: String,
    objects: Int,
    memory_bytes: Int,
    protection: String,
    heir: String,
  )
}

/// The sums over every table the walk read, listed or not.
pub type Totals {
  Totals(tables: Int, objects: Int, memory_bytes: Int)
}

/// How much of the node's tables the walk covered. `total` is the length of
/// the list at the start, `counted` the tables read, and `skipped` the tables
/// deleted before they could be read. A table created after the list was built
/// is in none of them.
pub type Coverage {
  Coverage(total: Int, counted: Int, skipped: Int, stop: Stop, elapsed_ms: Int)
}

/// The listing: the largest tables by memory, the totals over all tables read,
/// and the coverage.
pub type Report {
  Report(tables: List(Table), totals: Totals, coverage: Coverage)
}

/// What `walk` returns: the caller's accumulator and the counts.
pub type Walk(a) {
  Walk(
    state: a,
    total: Int,
    counted: Int,
    skipped: Int,
    stop: Stop,
    elapsed_ms: Int,
  )
}

type Listing {
  Listing(top: topk.Top(Table), totals: Totals)
}

/// List the largest tables, on the calling process.
///
/// ## Examples
///
/// ```gleam
/// run(Budget(top_k: 100, deadline_ms: 2000))
/// // -> Report(tables: [...], totals: Totals(...), coverage: Coverage(...))
/// ```
pub fn run(budget: Budget) -> Report {
  let started = ffi_proc.now_ms()
  let initial = Listing(topk.new(budget.top_k), Totals(0, 0, 0))
  let walked = walk(started, budget.deadline_ms, initial, offer)
  let largest =
    seq.map(topk.descending(walked.state.top), fn(entry) { entry.1 })

  Report(
    tables: label_owners(largest),
    totals: walked.state.totals,
    coverage: Coverage(
      total: walked.total,
      counted: walked.counted,
      skipped: walked.skipped,
      stop: walked.stop,
      elapsed_ms: walked.elapsed_ms,
    ),
  )
}

fn offer(listing: Listing, table: Table) -> Listing {
  let totals = listing.totals

  Listing(
    top: topk.offer(listing.top, table.memory_bytes, table),
    totals: Totals(
      tables: totals.tables + 1,
      objects: totals.objects + table.objects,
      memory_bytes: totals.memory_bytes + table.memory_bytes,
    ),
  )
}

// Only the tables that made the listing have their owner's label read, so a
// node with fifty thousand tables costs one signal per listed table and not
// one per table.
fn label_owners(tables: List(Table)) -> List(Table) {
  let #(labelled, _) =
    seq.fold(tables, #([], ffi_ets.cache_new()), fn(acc, table) {
      let #(done, cache) = acc
      let #(found, cache) = owner_of(cache, table.owner_pid)

      let name = proc_info.read_registered_name(table.owner_pid)

      #([Table(..table, owner: found, owner_name: name), ..done], cache)
    })

  seq.reverse(labelled)
}

/// Fold every table into an accumulator, on the calling process. A table the
/// walk cannot read is counted as skipped and never reaches `step`.
///
/// `started` is the time on the monotonic clock the deadline is counted from,
/// so a caller that has already spent part of its budget can pass its own
/// start.
///
/// ## Examples
///
/// ```gleam
/// walk(now_ms(), 2000, 0, fn(bytes, table) { bytes + table.memory_bytes })
/// // -> Walk(state: 183_024, ...)
/// ```
pub fn walk(
  started: Int,
  deadline_ms: Int,
  initial: a,
  step: fn(a, Table) -> a,
) -> Walk(a) {
  let ids = ffi_ets.all()
  let word = ffi_vm.word_size()
  let total = seq.length(ids)
  let begun = Walk(initial, total, 0, 0, Finished, 0)
  let done = loop(ids, begun, started, deadline_ms, word, step)

  Walk(..done, elapsed_ms: ffi_proc.now_ms() - started)
}

// One table per turn. The deadline is read every `clock_interval` tables,
// counting the skipped ones, because a node whose tables all vanish as they
// are read should still stop on time.
fn loop(
  ids: List(Term),
  so_far: Walk(a),
  started: Int,
  deadline_ms: Int,
  word: Int,
  step: fn(a, Table) -> a,
) -> Walk(a) {
  case ids {
    [] -> so_far
    [id, ..rest] ->
      case past_deadline(so_far, started, deadline_ms) {
        True -> Walk(..so_far, stop: Deadline)
        False ->
          loop(
            rest,
            visit(so_far, id, word, step),
            started,
            deadline_ms,
            word,
            step,
          )
      }
  }
}

fn past_deadline(so_far: Walk(a), started: Int, deadline_ms: Int) -> Bool {
  { so_far.counted + so_far.skipped } % clock_interval == 0
  && ffi_proc.now_ms() - started >= deadline_ms
}

fn visit(
  so_far: Walk(a),
  id: Term,
  word: Int,
  step: fn(a, Table) -> a,
) -> Walk(a) {
  case read(id, word) {
    // The table was deleted after the list was built, or answered in a shape
    // this release does not document.
    Error(Nil) -> Walk(..so_far, skipped: so_far.skipped + 1)
    Ok(table) ->
      Walk(
        ..so_far,
        state: step(so_far.state, table),
        counted: so_far.counted + 1,
      )
  }
}

// `ets:info/1` answers `undefined` for a deleted table, and otherwise a
// property list whose keys are documented. A missing or mistyped property
// makes the table unreadable rather than zero, so a release that renames one
// cannot make a table look empty.
fn read(id: Term, word: Int) -> Result(Table, Nil) {
  let info = ffi_ets.info(id)

  case ffi_term.is_list(info) {
    False -> Error(Nil)
    True -> {
      use owner_pid <- fallible.then(pid_property(info, "owner"))
      use kind <- fallible.then(atom_property(info, "type"))
      use objects <- fallible.then(integer_property(info, "size"))
      use memory <- fallible.then(integer_property(info, "memory"))
      use protection <- fallible.then(atom_property(info, "protection"))

      Ok(Table(
        id: id_text(info),
        name: name_text(info),
        owner_pid: owner_pid,
        owner: Unknown,
        owner_name: "",
        kind: kind,
        objects: objects,
        memory_bytes: memory * word,
        protection: protection,
        heir: heir_text(info),
      ))
    }
  }
}

fn property(info: Term, key: String) -> Result(Term, Nil) {
  let found = ffi_ets.key_find(ffi_term.atom(key), 1, info)

  case ffi_term.is_tuple(found) && ffi_term.tuple_size(found) == 2 {
    True -> Ok(ffi_term.element(2, found))
    False -> Error(Nil)
  }
}

fn pid_property(info: Term, key: String) -> Result(Pid, Nil) {
  use value <- fallible.then(property(info, key))

  case ffi_term.is_pid(value) {
    True -> Ok(ffi_term.coerce(value))
    False -> Error(Nil)
  }
}

fn atom_property(info: Term, key: String) -> Result(String, Nil) {
  use value <- fallible.then(property(info, key))

  case ffi_term.is_atom(value) {
    True -> Ok(ffi_term.atom_name(ffi_term.coerce(value)))
    False -> Error(Nil)
  }
}

fn integer_property(info: Term, key: String) -> Result(Int, Nil) {
  use value <- fallible.then(property(info, key))

  case ffi_term.is_integer(value) {
    True -> Ok(ffi_term.coerce(value))
    False -> Error(Nil)
  }
}

// A table identifier is a reference on every release this agent supports. One
// that is not shows as the empty string and the viewer keys on the owner and
// name instead.
fn id_text(info: Term) -> String {
  case property(info, "id") {
    Ok(value) ->
      case ffi_term.is_reference(value) {
        True -> ffi_term.ref_text(ffi_term.coerce(value))
        False -> ""
      }
    Error(Nil) -> ""
  }
}

// The name is reported only for a named table. An unnamed table's `name`
// property is its type tag, which is not a name.
fn name_text(info: Term) -> String {
  case property(info, "named_table") {
    Ok(named) ->
      case named == ffi_term.coerce(True) {
        False -> ""
        True ->
          case atom_property(info, "name") {
            Ok(name) -> name
            Error(Nil) -> ""
          }
      }
    Error(Nil) -> ""
  }
}

// An heir is a pid, or the atom `none`.
fn heir_text(info: Term) -> String {
  case property(info, "heir") {
    Ok(heir) -> ffi_term.pid_text_or_empty(heir)
    Error(Nil) -> ""
  }
}

/// The owner label of a process, remembered in `cache` so that a process that
/// owns many tables is asked once. A process that exited is `Unknown`.
///
/// ## Examples
///
/// ```gleam
/// owner_of(ffi_ets.cache_new(), self())
/// // -> #(Unknown, cache)
/// ```
pub fn owner_of(cache: Cache, pid: Pid) -> #(Owner, Cache) {
  let missing = ffi_term.coerce(0)
  let cached = ffi_ets.cache_get(pid, cache, missing)

  case ffi_term.is_integer(cached) {
    False -> #(ffi_term.coerce(cached), cache)
    True -> {
      let found = owner.decode(proc_info.read_label(pid))

      #(found, ffi_ets.cache_put(pid, ffi_term.coerce(found), cache))
    }
  }
}

/// The wire name of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// stop_name(Deadline)
/// // -> "deadline"
/// ```
pub fn stop_name(stop: Stop) -> String {
  case stop {
    Finished -> "finished"
    Deadline -> "deadline"
  }
}
