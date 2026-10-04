//// Process-level bindings: spawning, monitoring, enumeration and the
//// per-process counters the census reads.
////
//// Every function is a direct binding to an existing OTP function; there is
//// no alternative in Gleam's prelude, and the standard library is not
//// available to the agent. The vocabulary types (`Item`, `SpawnOption` and
//// the like) exist because Gleam builds atoms only from constructors: a
//// nullary constructor `MessageQueueLen` is the atom `message_queue_len`,
//// which is what `process_info/2` wants, so the closed set of items the
//// agent can ask for is visible in one type.

import pickglass_agent/internal/ffi_term.{
  type Atom, type Pid, type Reference, type Term,
}

/// The `process_info/2` items the agent reads. Every one is a number, a short
/// atom, a bounded list of identifiers or a fixed-size property list; items
/// that copy process-owned data (messages, dictionary, backtrace) are
/// deliberately absent.
pub type Item {
  Memory
  TotalHeapSize
  HeapSize
  StackSize
  MessageQueueLen
  Reductions
  Status
  CurrentFunction
  RegisteredName
  Label
  InitialCall
  GarbageCollection
  GarbageCollectionInfo
  Links
  Monitors
  MonitoredBy
  Parent
  CurrentStacktrace
}

/// The kind of thing `monitor/2` watches. The agent only monitors
/// processes.
pub type MonitorKind {
  Process
}

/// Options for `spawn_opt/2` that the agent uses.
pub type SpawnOption {
  Monitor
  MaxHeapSize(limit: Term)
}

/// Keys of the `max_heap_size` option map.
pub type HeapLimit {
  Size
  ErrorLogger
}

/// The signal `exit/2` sends to end a worker.
pub type ExitSignal {
  Kill
}

/// The unit `monotonic_time/1` is asked for.
pub type TimeUnit {
  Millisecond
}

/// Options for `demonitor/2`.
pub type DemonitorOption {
  Flush
}

@external(erlang, "erlang", "put")
fn put(key: Atom, value: Term) -> Term

/// Set this process's label, which is what `proc_lib:set_label/1` does: it
/// writes the `'$process_label'` dictionary entry. Calling the dictionary
/// directly works on every OTP release and needs no helper process, which a
/// call through `ffi_safe` would be, labelling the wrong process.
///
/// ## Examples
///
/// ```gleam
/// set_label(ffi_term.coerce(#("owner", 1)))
/// ```
pub fn set_label(label: Term) -> Nil {
  let _ = put(ffi_term.atom("$process_label"), label)

  Nil
}

/// This process.
@external(erlang, "erlang", "self")
pub fn self() -> Pid

/// The node a pid lives on.
@external(erlang, "erlang", "node")
pub fn node_of(pid: Pid) -> Atom

/// Spawn a process running a closure, monitored from the caller, with
/// options. Returns the pid and the monitor reference.
@external(erlang, "erlang", "spawn_opt")
pub fn spawn_opt(
  run: fn() -> Nil,
  options: List(SpawnOption),
) -> #(Pid, Reference)

/// Spawn a process that runs `module:function(args)`. The initial call is
/// then a named function rather than a closure, which matters to the
/// janitor: a process holding a closure of a module counts as running that
/// module's code when the module is purged.
@external(erlang, "erlang", "spawn")
pub fn spawn_call(module: Atom, function: Atom, args: List(Term)) -> Pid

@external(erlang, "maps", "from_list")
fn map_from_list(pairs: List(#(Term, Term))) -> Term

/// A `max_heap_size` option that kills the process when its heap passes
/// `words`, without writing an error report for it.
///
/// ## Examples
///
/// ```gleam
/// spawn_opt(work, [Monitor, heap_limit(1_000_000)])
/// ```
pub fn heap_limit(words: Int) -> SpawnOption {
  MaxHeapSize(
    map_from_list([
      #(ffi_term.coerce(Size), ffi_term.coerce(words)),
      #(ffi_term.coerce(Kill), ffi_term.coerce(True)),
      #(ffi_term.coerce(ErrorLogger), ffi_term.coerce(False)),
    ]),
  )
}

/// Monitor a process. A `{'DOWN', Ref, process, Pid, Reason}` message
/// arrives when it exits.
@external(erlang, "erlang", "monitor")
pub fn monitor(kind: MonitorKind, pid: Pid) -> Reference

/// Remove a monitor and any `DOWN` already queued for it.
@external(erlang, "erlang", "demonitor")
pub fn demonitor(reference: Reference, options: List(DemonitorOption)) -> Bool

/// Ask to be told with `{nodedown, Node}` when a node connection ends. The
/// flag is passed as a term so that no function in the agent takes a bare
/// boolean parameter.
@external(erlang, "erlang", "monitor_node")
pub fn monitor_node_flag(node: Atom, flag: Term) -> Bool

/// Send a signal to a local process.
@external(erlang, "erlang", "exit")
pub fn exit_with(pid: Pid, signal: ExitSignal) -> Bool

@external(erlang, "erlang", "send")
fn send_raw(to: Pid, message: Term) -> Term

/// Send a message. A send to a dead process is not an error.
///
/// ## Examples
///
/// ```gleam
/// send(pid, coerce("hello"))
/// ```
pub fn send(to: Pid, message: Term) -> Nil {
  let _ = send_raw(to, message)

  Nil
}

/// Whether a local process is alive. The VM raises for a pid of another
/// node, so callers pass only pids resolved on this node.
@external(erlang, "erlang", "is_process_alive")
pub fn is_alive(pid: Pid) -> Bool

/// Arrange for a message to be sent to a process after a delay.
@external(erlang, "erlang", "send_after")
pub fn send_after(milliseconds: Int, to: Pid, message: Term) -> Reference

/// Read items from a process. Returns the atom `undefined` for a process
/// that has exited, and otherwise a list of `Info` values in request order.
@external(erlang, "erlang", "process_info")
pub fn process_info(pid: Pid, items: List(Item)) -> Term

/// An opaque position in the walk over every process on the node.
pub type Iterator

/// Begin a walk over every process. The iterator builds no list, so a walk
/// of a hundred thousand processes allocates nothing proportional to the
/// count, and it can stop at any chunk boundary.
@external(erlang, "erlang", "processes_iterator")
pub fn processes_iterator() -> Iterator

/// Advance an iterator. Returns the atom `none` at the end and otherwise a
/// tuple of the next pid and the rest of the iterator.
@external(erlang, "erlang", "processes_next")
pub fn processes_next(iterator: Iterator) -> Term

/// Milliseconds on the monotonic clock. The value may be negative and has
/// no meaning except as a difference.
@external(erlang, "erlang", "monotonic_time")
pub fn monotonic_time(unit: TimeUnit) -> Int

/// The monotonic clock in milliseconds.
pub fn now_ms() -> Int {
  monotonic_time(Millisecond)
}
