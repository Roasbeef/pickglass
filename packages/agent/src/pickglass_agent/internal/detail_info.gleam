//// The `process_info/2` answers the detail, supervision and collection
//// probes read, as a Gleam type.
////
//// This is `proc_info`'s sibling for the items that one named process is
//// asked about, or that the supervision walk reads for every process: sizes,
//// the property lists `garbage_collection` and `garbage_collection_info`,
//// the counts behind `links`, `monitors` and `monitored_by`, the parent and
//// the initial call. The constructors are named for the atoms the VM puts
//// first in each `{Item, Value}` tuple, so a list can be matched directly.
////
//// None of the items copies process-owned data beyond identifiers. `links`,
//// `monitors` and `monitored_by` return lists of identifiers whose length is
//// bounded by what the process holds; the worker that reads them runs under
//// a heap cap, so a process with an extreme link count costs the worker and
//// not the agent.

import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}

/// One `{Item, Value}` tuple of a `process_info/2` answer.
pub type Info {
  Memory(bytes: Int)
  TotalHeapSize(words: Int)
  HeapSize(words: Int)
  StackSize(words: Int)
  MessageQueueLen(length: Int)
  Reductions(count: Int)
  Status(state: Atom)
  CurrentFunction(function: Term)
  InitialCall(function: Term)
  RegisteredName(name: Term)
  Label(label: Term)
  GarbageCollection(fields: Term)
  GarbageCollectionInfo(fields: Term)
  Links(pids: List(Term))
  Monitors(entries: List(Term))
  MonitoredBy(pids: List(Term))
  Parent(pid: Term)
}

/// The items one process's detail needs, in the order `read_detail` returns
/// them.
const detail_items = [
  ffi_proc.Memory,
  ffi_proc.TotalHeapSize,
  ffi_proc.HeapSize,
  ffi_proc.StackSize,
  ffi_proc.MessageQueueLen,
  ffi_proc.Reductions,
  ffi_proc.Status,
  ffi_proc.CurrentFunction,
  ffi_proc.InitialCall,
  ffi_proc.RegisteredName,
  ffi_proc.Label,
  ffi_proc.GarbageCollection,
  ffi_proc.GarbageCollectionInfo,
  ffi_proc.Links,
  ffi_proc.Monitors,
  ffi_proc.MonitoredBy,
  ffi_proc.Parent,
]

/// The items a targeted collection compares before and after.
const heap_items = [
  ffi_proc.Memory,
  ffi_proc.TotalHeapSize,
  ffi_proc.HeapSize,
  ffi_proc.StackSize,
  ffi_proc.GarbageCollectionInfo,
]

/// The items the supervision walk reads for every process.
const edge_items = [
  ffi_proc.Parent,
  ffi_proc.RegisteredName,
  ffi_proc.InitialCall,
  ffi_proc.Label,
]

/// Read everything a process detail shows. `Error(Nil)` means the process
/// exited before the read.
///
/// ## Examples
///
/// ```gleam
/// read_detail(self())
/// // -> Ok([Memory(...), TotalHeapSize(...), ...])
/// ```
pub fn read_detail(pid: Pid) -> Result(List(Info), Nil) {
  read(pid, detail_items)
}

/// Read the sizes a collection is judged by.
///
/// ## Examples
///
/// ```gleam
/// read_heap(self())
/// // -> Ok([Memory(...), TotalHeapSize(...), HeapSize(...), ...])
/// ```
pub fn read_heap(pid: Pid) -> Result(List(Info), Nil) {
  read(pid, heap_items)
}

/// Read what the supervision walk needs from one process.
///
/// ## Examples
///
/// ```gleam
/// read_edge(self())
/// // -> Ok([Parent(...), RegisteredName(...), ...])
/// ```
pub fn read_edge(pid: Pid) -> Result(List(Info), Nil) {
  read(pid, edge_items)
}

fn read(pid: Pid, items: List(ffi_proc.Item)) -> Result(List(Info), Nil) {
  let answer = ffi_proc.process_info(pid, items)

  case ffi_term.is_atom(answer) {
    True -> Error(Nil)
    False -> Ok(ffi_term.coerce(answer))
  }
}
