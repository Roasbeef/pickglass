//// The process census: a bounded walk over every process on the node.
////
//// The census answers two questions at once: which processes use the most
//// memory, and how memory, queue length and reductions add up by owner. It
//// does so without ever building a list of all processes. It walks
//// `erlang:processes_iterator/0` one process at a time, reads a fixed bundle
//// of cheap `process_info` items, and folds each process into a top-K
//// selection and a map of per-owner totals. The result is bounded by K, by
//// the number of owners and by the reply size limit, whatever the node's
//// process count.
////
//// The walk stops at a scan budget or a deadline and says so in its
//// coverage: a census that stopped early is a partial answer with the
//// numbers to prove it, never a quiet undercount. The iterator is not an
//// atomic snapshot, so a process that starts or exits during the walk may be
//// missed or counted once; the coverage's total is the process count at the
//// start, which makes that visible.
////
//// The walk runs in a worker process spawned by the server with a heap cap,
//// so a node with an enormous number of owners cannot grow the agent. This
//// module holds the pure parts and the loop; it sends nothing.

import pickglass_agent/internal/ffi_proc.{type Iterator}
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/proc_info.{type Info}
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner, Owned, Unknown}
import pickglass_agent/topk

/// How much work one census may do.
pub type Budget {
  Budget(max_scanned: Int, top_k: Int, deadline_ms: Int)
}

/// Why the walk ended.
pub type Stop {
  /// The iterator ran out: every process alive for the whole walk was seen.
  Finished

  /// The scan budget was reached with processes left unvisited.
  ScanBudget

  /// The deadline passed with processes left unvisited.
  Deadline
}

/// One process as the census saw it. Words are VM words; the viewer
/// multiplies by the node's word size, which the memory reply carries.
pub type Row {
  Row(
    pid: Pid,
    memory: Int,
    total_heap_words: Int,
    heap_words: Int,
    stack_words: Int,
    queue_length: Int,
    reductions: Int,
    status: Atom,
    function: Term,
    name: Term,
    owner: Owner,
  )
}

/// The totals for one owner.
pub type Aggregate {
  Aggregate(
    owner: Owner,
    processes: Int,
    memory: Int,
    queue_length: Int,
    reductions: Int,
  )
}

/// How much of the node the census covered.
pub type Coverage {
  Coverage(scanned: Int, total: Int, stop: Stop, elapsed_ms: Int)
}

/// The census result.
pub type Report {
  Report(rows: List(Row), aggregates: List(Aggregate), coverage: Coverage)
}

type OwnerMap

type Walk {
  Walk(top: topk.Top(Row), owners: OwnerMap, scanned: Int, stop: Stop)
}

/// The most distinct owners tracked. Past it, new owners fold into one
/// `other` bucket so a label scheme with unbounded cardinality cannot grow
/// the worker without limit.
const max_owners = 5000

/// How many processes to scan between looks at the clock.
const clock_interval = 1024

/// How many owner aggregates a report carries.
const max_aggregates = 100

type Totals =
  #(Int, Int, Int, Int)

@external(erlang, "maps", "new")
fn new_map() -> OwnerMap

@external(erlang, "maps", "get")
fn map_get(key: Owner, map: OwnerMap, default: Totals) -> Totals

@external(erlang, "maps", "put")
fn map_put(key: Owner, value: Totals, map: OwnerMap) -> OwnerMap

@external(erlang, "maps", "size")
fn map_size(map: OwnerMap) -> Int

@external(erlang, "maps", "to_list")
fn map_to_list(map: OwnerMap) -> List(#(Owner, Totals))

/// Run a census on the calling process.
///
/// ## Examples
///
/// ```gleam
/// run(Budget(max_scanned: 200_000, top_k: 20, deadline_ms: 2000))
/// // -> Report(rows: [...], aggregates: [...], coverage: ...)
/// ```
pub fn run(budget: Budget) -> Report {
  let started = ffi_proc.now_ms()
  let total = ffi_vm.process_count()
  let initial = Walk(topk.new(budget.top_k), new_map(), 0, Finished)
  let walk = step(ffi_proc.processes_iterator(), initial, budget, started)

  Report(
    rows: seq.map(topk.descending(walk.top), fn(entry) { entry.1 }),
    aggregates: aggregates(walk.owners),
    coverage: Coverage(
      scanned: walk.scanned,
      total: total,
      stop: walk.stop,
      elapsed_ms: ffi_proc.now_ms() - started,
    ),
  )
}

// One turn of the walk. The iterator's answer is either the atom `none` or
// a tuple of the next pid and the rest of the iterator. A process pulled
// from the iterator after the scan budget is spent is not counted: it is the
// evidence that the walk stopped early rather than finished.
fn step(iterator: Iterator, walk: Walk, budget: Budget, started: Int) -> Walk {
  let next = ffi_proc.processes_next(iterator)

  case ffi_term.is_tuple(next) {
    False -> walk
    True -> {
      let pid: Pid = ffi_term.coerce(ffi_term.element(1, next))
      let rest: Iterator = ffi_term.coerce(ffi_term.element(2, next))

      case over_budget(walk, budget, started) {
        Finished -> step(rest, visit(walk, pid), budget, started)
        stop -> Walk(..walk, stop: stop)
      }
    }
  }
}

// The deadline is checked every `clock_interval` processes, not per process,
// because reading the clock would otherwise cost as much as the
// `process_info` call it guards.
fn over_budget(walk: Walk, budget: Budget, started: Int) -> Stop {
  case walk.scanned >= budget.max_scanned {
    True -> ScanBudget
    False ->
      case walk.scanned % clock_interval == 0 && walk.scanned > 0 {
        False -> Finished
        True ->
          case ffi_proc.now_ms() - started >= budget.deadline_ms {
            True -> Deadline
            False -> Finished
          }
      }
  }
}

fn visit(walk: Walk, pid: Pid) -> Walk {
  case proc_info.read(pid) {
    // The process exited between the iterator yielding it and this read.
    Error(Nil) -> walk
    Ok(infos) -> {
      let row = seq.fold(infos, empty_row(pid), apply_info)

      Walk(
        ..walk,
        top: topk.offer(walk.top, row.memory, row),
        owners: add_to_owner(walk.owners, row),
        scanned: walk.scanned + 1,
      )
    }
  }
}

fn empty_row(pid: Pid) -> Row {
  Row(
    pid: pid,
    memory: 0,
    total_heap_words: 0,
    heap_words: 0,
    stack_words: 0,
    queue_length: 0,
    reductions: 0,
    status: ffi_term.atom("undefined"),
    function: ffi_term.coerce(0),
    name: ffi_term.coerce(0),
    owner: Unknown,
  )
}

fn apply_info(row: Row, info: Info) -> Row {
  case info {
    proc_info.Memory(bytes) -> Row(..row, memory: bytes)
    proc_info.TotalHeapSize(words) -> Row(..row, total_heap_words: words)
    proc_info.HeapSize(words) -> Row(..row, heap_words: words)
    proc_info.StackSize(words) -> Row(..row, stack_words: words)
    proc_info.MessageQueueLen(length) -> Row(..row, queue_length: length)
    proc_info.Reductions(count) -> Row(..row, reductions: count)
    proc_info.Status(state) -> Row(..row, status: state)
    proc_info.CurrentFunction(function) -> Row(..row, function: function)
    proc_info.RegisteredName(name) -> Row(..row, name: name)
    proc_info.Label(label) -> Row(..row, owner: owner.decode(label))
  }
}

fn add_to_owner(owners: OwnerMap, row: Row) -> OwnerMap {
  let key = bounded_key(owners, row.owner)
  let #(processes, memory, queue_length, reductions) =
    map_get(key, owners, #(0, 0, 0, 0))

  map_put(
    key,
    #(
      processes + 1,
      memory + row.memory,
      queue_length + row.queue_length,
      reductions + row.reductions,
    ),
    owners,
  )
}

// A new owner past the cap is filed under `other`. An owner already in the
// map keeps its own entry, so the cap limits cardinality without moving
// totals that were already attributed.
fn bounded_key(owners: OwnerMap, key: Owner) -> Owner {
  case map_size(owners) >= max_owners {
    False -> key
    True ->
      case map_get(key, owners, #(-1, 0, 0, 0)) {
        #(-1, _, _, _) -> Owned([], "other")
        _ -> key
      }
  }
}

// The largest owners by memory, with `Unknown` always included because the
// share of the node nobody has claimed is the first thing a reader needs.
fn aggregates(owners: OwnerMap) -> List(Aggregate) {
  let entries = map_to_list(owners)
  let top =
    seq.fold(entries, topk.new(max_aggregates), fn(top, entry) {
      let #(key, #(processes, memory, queue_length, reductions)) = entry

      case key {
        Unknown -> top
        Owned(_, _) ->
          topk.offer(
            top,
            memory,
            Aggregate(key, processes, memory, queue_length, reductions),
          )
      }
    })
  let owned = seq.map(topk.descending(top), fn(entry) { entry.1 })

  case map_get(Unknown, owners, #(-1, 0, 0, 0)) {
    #(-1, _, _, _) -> owned
    #(processes, memory, queue_length, reductions) -> [
      Aggregate(Unknown, processes, memory, queue_length, reductions),
      ..owned
    ]
  }
}

/// The wire name of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// stop_name(ScanBudget)
/// // -> "scan_budget"
/// ```
pub fn stop_name(stop: Stop) -> String {
  case stop {
    Finished -> "finished"
    ScanBudget -> "scan_budget"
    Deadline -> "deadline"
  }
}

/// Render a `current_function` value, `{Module, Function, Arity}`, as
/// `module:function/arity`. Anything else, such as `undefined`, renders as
/// an empty string.
///
/// ## Examples
///
/// ```gleam
/// function_text(coerce(#(lists, map, 2)))
/// // -> "lists:map/2"
/// ```
pub fn function_text(function: Term) -> String {
  case
    ffi_term.is_tuple(function)
    && ffi_term.tuple_size(function) == 3
    && ffi_term.is_atom(ffi_term.element(1, function))
    && ffi_term.is_atom(ffi_term.element(2, function))
    && ffi_term.is_integer(ffi_term.element(3, function))
  {
    False -> ""
    True -> {
      let module: Atom = ffi_term.coerce(ffi_term.element(1, function))
      let name: Atom = ffi_term.coerce(ffi_term.element(2, function))
      let arity: Int = ffi_term.coerce(ffi_term.element(3, function))

      ffi_term.atom_name(module)
      <> ":"
      <> ffi_term.atom_name(name)
      <> "/"
      <> int_text(arity)
    }
  }
}

/// Render a `registered_name` value. A process with no name reports the
/// empty list, which renders as an empty string.
///
/// ## Examples
///
/// ```gleam
/// name_text(coerce([]))
/// // -> ""
/// ```
pub fn name_text(name: Term) -> String {
  case ffi_term.is_atom(name) {
    True -> ffi_term.atom_name(ffi_term.coerce(name))
    False -> ""
  }
}

@external(erlang, "erlang", "integer_to_binary")
fn int_text(value: Int) -> String
