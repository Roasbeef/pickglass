//// The shapes `process_info/2` returns, as a Gleam type.
////
//// `process_info(Pid, Items)` answers with one `{Item, Value}` tuple per
//// requested item, in the order requested, or the atom `undefined` for a
//// process that has exited. Declaring the tuples as constructors lets the
//// census match on them directly, with no per-item lookup. The shapes are
//// the VM's documented ones, not input from outside, so the cast in
//// `read` is a claim about OTP rather than about a message.

import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Atom, type Pid, type Term}

/// One `{Item, Value}` tuple of a `process_info/2` answer. Each constructor
/// is the tuple whose first element is the snake_case atom of its name.
pub type Info {
  Memory(bytes: Int)
  TotalHeapSize(words: Int)
  HeapSize(words: Int)
  StackSize(words: Int)
  MessageQueueLen(length: Int)
  Reductions(count: Int)
  Status(state: Atom)
  CurrentFunction(function: Term)
  RegisteredName(name: Term)
  Label(label: Term)
}

/// The items the census asks for, in the order `read` returns them.
const census_items = [
  ffi_proc.Memory,
  ffi_proc.TotalHeapSize,
  ffi_proc.HeapSize,
  ffi_proc.StackSize,
  ffi_proc.MessageQueueLen,
  ffi_proc.Reductions,
  ffi_proc.Status,
  ffi_proc.CurrentFunction,
  ffi_proc.RegisteredName,
  ffi_proc.Label,
]

/// Read the census items from one process. `Error(Nil)` means the process
/// exited between the walk reaching it and this call.
///
/// ## Examples
///
/// ```gleam
/// read(self())
/// // -> Ok([Memory(34584), TotalHeapSize(...), ...])
/// ```
pub fn read(pid: Pid) -> Result(List(Info), Nil) {
  let answer = ffi_proc.process_info(pid, census_items)

  case ffi_term.is_atom(answer) {
    True -> Error(Nil)
    False -> Ok(ffi_term.coerce(answer))
  }
}

/// Read one process's label term, or the atom `undefined` for a process with
/// none or one that exited. The walk over ETS tables asks this for the owner of
/// a table, which is a process the census did not necessarily visit.
///
/// ## Examples
///
/// ```gleam
/// read_label(self())
/// // -> the label term, or undefined
/// ```
pub fn read_label(pid: Pid) -> Term {
  let answer = ffi_proc.process_info(pid, [ffi_proc.Label])

  case ffi_term.is_atom(answer) {
    True -> ffi_term.coerce(answer)
    False -> {
      let items: List(Term) = ffi_term.coerce(answer)

      case items {
        [item] -> ffi_term.element(2, item)
        _ -> ffi_term.coerce(answer)
      }
    }
  }
}

/// Read the census items and the process's `proc_lib` initial call. The call
/// lives in the dictionary key `'$initial_call'`, which `proc_lib` writes
/// before it runs the process's code, and the `{dictionary, Key}` item returns
/// that one value without copying the rest of the dictionary: a process with a
/// large dictionary costs the same as one with none. The call is `{Module,
/// Function, Arity}` for a process `proc_lib` started and the atom `undefined`
/// for any other. `proc_lib:initial_call/1` was considered and not used
/// because it also invents an atom per argument for its dummy argument list.
///
/// ## Examples
///
/// ```gleam
/// read_with_initial_call(self())
/// // -> Ok(#([Memory(34584), ...], coerce(undefined)))
/// ```
pub fn read_with_initial_call(pid: Pid) -> Result(#(List(Info), Term), Nil) {
  let answer =
    ffi_proc.process_info(pid, [
      ffi_proc.Dictionary(ffi_term.atom("$initial_call")),
      ..census_items
    ])

  case ffi_term.is_atom(answer) {
    True -> Error(Nil)
    False -> {
      let entries: List(Term) = ffi_term.coerce(answer)

      case entries {
        [entry, ..infos] ->
          Ok(#(ffi_term.coerce(infos), ffi_term.element(2, entry)))
        [] -> Error(Nil)
      }
    }
  }
}
