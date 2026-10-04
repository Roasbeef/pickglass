//// One process in detail: the fixed bundle of cheap `process_info` items a
//// pinned process's page shows, and the heap reading a targeted collection
//// compares before and after.
////
//// The bundle is closed and chosen for cost and safety. It holds sizes,
//// counters, the status, the function names, the label, the two
//// `garbage_collection` property lists and the counts behind links,
//// monitors and monitors-of. It never holds `messages`, `dictionary`,
//// `backtrace` or the process's state: those copy data the process owns and
//// can be megabytes, and the data may be secret. Sizes arrive in words and
//// leave in bytes, so the viewer needs no word size to read them.
////
//// Reading a process is a signal to it, and a process that does not handle
//// signals promptly (suspended, or in a long non-yielding built-in) delays
//// the answer. The server therefore runs `read` in a worker with a deadline
//// and never in its own process.

import pickglass_agent/internal/detail_info.{
  GarbageCollection, GarbageCollectionInfo, HeapSize, Label, Links, Memory,
  MessageQueueLen, MonitoredBy, Monitors, Parent, Reductions, RegisteredName,
  StackSize, Status, TotalHeapSize,
}
import pickglass_agent/internal/fallible
import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner}

/// The sizes of a process's heap and what surrounds it, in bytes.
/// `memory_bytes` is everything the VM accounts to the process; the heap
/// fields are the young and old generations, their allocated blocks, message
/// fragments and the off-heap binary virtual heap.
pub type Heap {
  Heap(
    memory_bytes: Int,
    total_heap_bytes: Int,
    heap_bytes: Int,
    stack_bytes: Int,
    heap_block_bytes: Int,
    old_heap_bytes: Int,
    old_heap_block_bytes: Int,
    mbuf_bytes: Int,
    bin_vheap_bytes: Int,
  )
}

/// The garbage collection settings of a process. A `max_heap_bytes` of zero
/// is the VM's own "no limit".
pub type GcSettings {
  GcSettings(
    minor_gcs: Int,
    fullsweep_after: Int,
    min_heap_bytes: Int,
    max_heap_bytes: Int,
  )
}

/// How many links, monitors and monitoring processes a process has, and who
/// started it.
pub type Relations {
  Relations(links: Int, monitors: Int, monitored_by: Int, parent: String)
}

/// Everything a process detail page shows.
pub type Detail {
  Detail(
    pid: Pid,
    heap: Heap,
    gc: GcSettings,
    relations: Relations,
    queue_length: Int,
    reductions: Int,
    status: Atom,
    current_function: Term,
    initial_call: Term,
    registered_name: Term,
    owner: Owner,
    capabilities: List(String),
  )
}

/// Read a process's detail. `Error(Nil)` means it exited, or answered in a
/// shape this OTP release does not document.
///
/// ## Examples
///
/// ```gleam
/// read(self())
/// // -> Ok(Detail(pid: self(), ...))
/// ```
pub fn read(pid: Pid) -> Result(Detail, Nil) {
  use infos <- fallible.then(detail_info.read_detail(pid))

  case infos {
    [
      Memory(memory),
      TotalHeapSize(total),
      HeapSize(heap),
      StackSize(stack),
      MessageQueueLen(queue),
      Reductions(reductions),
      Status(status),
      detail_info.CurrentFunction(function),
      detail_info.InitialCall(initial),
      RegisteredName(name),
      Label(label),
      GarbageCollection(settings),
      GarbageCollectionInfo(info),
      Links(links),
      Monitors(monitors),
      MonitoredBy(monitored_by),
      Parent(parent),
    ] -> {
      use heap <- fallible.then(heap_of(memory, total, heap, stack, info))
      use gc <- fallible.then(gc_of(settings))

      Ok(Detail(
        pid: pid,
        heap: heap,
        gc: gc,
        relations: Relations(
          links: seq.length(links),
          monitors: seq.length(monitors),
          monitored_by: seq.length(monitored_by),
          parent: ffi_term.pid_text_or_empty(parent),
        ),
        queue_length: queue,
        reductions: reductions,
        status: status,
        current_function: function,
        initial_call: initial,
        registered_name: name,
        owner: owner.decode(label),
        capabilities: owner.capabilities(label),
      ))
    }
    _ -> Error(Nil)
  }
}

/// Read the sizes a targeted collection compares. `Error(Nil)` means the
/// process exited.
///
/// ## Examples
///
/// ```gleam
/// read_heap(self())
/// // -> Ok(Heap(memory_bytes: 34584, ...))
/// ```
pub fn read_heap(pid: Pid) -> Result(Heap, Nil) {
  use infos <- fallible.then(detail_info.read_heap(pid))

  case infos {
    [
      Memory(memory),
      TotalHeapSize(total),
      HeapSize(heap),
      StackSize(stack),
      GarbageCollectionInfo(info),
    ] -> heap_of(memory, total, heap, stack, info)
    _ -> Error(Nil)
  }
}

fn heap_of(
  memory: Int,
  total_words: Int,
  heap_words: Int,
  stack_words: Int,
  info: Term,
) -> Result(Heap, Nil) {
  let word = ffi_vm.word_size()

  use heap_block <- fallible.then(field(info, "heap_block_size"))
  use old_heap <- fallible.then(field(info, "old_heap_size"))
  use old_block <- fallible.then(field(info, "old_heap_block_size"))
  use mbuf <- fallible.then(field(info, "mbuf_size"))
  use binary <- fallible.then(field(info, "bin_vheap_size"))

  Ok(Heap(
    memory_bytes: memory,
    total_heap_bytes: total_words * word,
    heap_bytes: heap_words * word,
    stack_bytes: stack_words * word,
    heap_block_bytes: heap_block * word,
    old_heap_bytes: old_heap * word,
    old_heap_block_bytes: old_block * word,
    mbuf_bytes: mbuf * word,
    bin_vheap_bytes: binary * word,
  ))
}

fn gc_of(settings: Term) -> Result(GcSettings, Nil) {
  let word = ffi_vm.word_size()

  use minor <- fallible.then(field(settings, "minor_gcs"))
  use sweep <- fallible.then(field(settings, "fullsweep_after"))
  use min_heap <- fallible.then(field(settings, "min_heap_size"))
  use max_heap <- fallible.then(max_heap_words(settings))

  Ok(GcSettings(
    minor_gcs: minor,
    fullsweep_after: sweep,
    min_heap_bytes: min_heap * word,
    max_heap_bytes: max_heap * word,
  ))
}

@external(erlang, "lists", "keyfind")
fn keyfind(key: Atom, position: Int, list: Term) -> Term

// An integer value from a `process_info` property list, or `Error(Nil)` when
// the key is absent or its value is not an integer. A missing key is an
// error and not a zero, so a release that renames one cannot make a size
// read as nothing.
fn field(list: Term, key: String) -> Result(Int, Nil) {
  case ffi_term.is_list(list) {
    False -> Error(Nil)
    True -> {
      let found = keyfind(ffi_term.atom(key), 1, list)

      case ffi_term.is_tuple(found) && ffi_term.tuple_size(found) == 2 {
        False -> Error(Nil)
        True -> integer(ffi_term.element(2, found))
      }
    }
  }
}

fn integer(term: Term) -> Result(Int, Nil) {
  case ffi_term.is_integer(term) {
    True -> Ok(ffi_term.coerce(term))
    False -> Error(Nil)
  }
}

// `max_heap_size` is a map `#{size => Words, kill => ..., ...}` on every
// release since OTP 19. The lookup goes through the catching call so a
// release that returns a bare integer fails the read and is not guessed at.
fn max_heap_words(settings: Term) -> Result(Int, Nil) {
  let found = keyfind(ffi_term.atom("max_heap_size"), 1, settings)

  case ffi_term.is_tuple(found) && ffi_term.tuple_size(found) == 2 {
    False -> Error(Nil)
    True -> {
      use size <- fallible.then(
        ffi_safe.call(ffi_safe.Maps, ffi_safe.Get, [
          ffi_term.coerce(ffi_safe.Size),
          ffi_term.element(2, found),
        ]),
      )

      integer(size)
    }
  }
}
