//// The reference-counted binaries one process holds.
////
//// A process's memory figure does not say how much of it is binaries: a
//// reference-counted binary (larger than 64 bytes) lives off the heap and the
//// process holds a small reference to it. `process_info(Pid, binary)` lists
//// those references as `{Address, Size, RefCount}`, which is how a leak of
//// large binaries through a long-lived process is told from a leak of heap.
//// The list's length is the number of references the process holds. It can be
//// the same binary several times, and a sub-binary shows the whole binary's
//// size, so the byte total is what the process keeps alive, not memory unique
//// to it.
////
//// This read is costly for a process that holds many binaries. The target
//// builds a list with a tuple for every reference and the answer is copied
//// into the caller, so the cost grows with the count and is paid by the target
//// and the caller together. It is therefore never part of a census: it is made
//// for one pinned process, on request, in a worker with a heap cap and a
//// deadline.
////
//// The count is not known before the list exists, so the bound has two parts.
//// A list longer than `max_binaries` is refused as `TooMany` rather than
//// summarised, and a list so long that the worker's heap cap kills it first
//// is reported the same way by the server. Either way the caller learns the
//// process holds more than the agent will read, and gets no partial figure
//// that might be mistaken for a total.

import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/seq
import pickglass_agent/topk

/// The most binary references one read accepts. At about six words each this
/// is a list a worker can hold twice over, which is what receiving it costs.
pub const max_binaries = 50_000

/// The most binaries a reply lists.
pub const max_top_k = 200

/// One binary the process references. `address` is the binary's address in
/// hexadecimal, which identifies the same binary across processes and across
/// reads while it lives.
pub type Entry {
  Entry(address: String, bytes: Int, refc: Int)
}

/// What a process holds. `count` and `bytes` cover every reference, and
/// `entries` is the largest ones, so `count` minus the length of `entries` is
/// how many the listing leaves out.
pub type Report {
  Report(count: Int, bytes: Int, entries: List(Entry))
}

/// Why a read gave no report.
pub type Failure {
  /// The process exited, or answered in a shape this release does not
  /// document.
  Gone

  /// The process holds more references than `max_binaries`; `count` is how
  /// many it holds.
  TooMany(count: Int)
}

/// Read a process's binaries on the calling process.
///
/// ## Examples
///
/// ```gleam
/// read(pid, 20)
/// // -> Ok(Report(count: 3, bytes: 300_000, entries: [...]))
/// ```
pub fn read(pid: Pid, top_k: Int) -> Result(Report, Failure) {
  let answer = ffi_proc.process_info(pid, [ffi_proc.Binary])

  case ffi_term.is_atom(answer) {
    True -> Error(Gone)
    False -> summarise(ffi_term.coerce(answer), top_k)
  }
}

// The answer is `[{binary, References}]`.
fn summarise(items: List(Term), top_k: Int) -> Result(Report, Failure) {
  case items {
    [item] ->
      case ffi_term.is_tuple(item) && ffi_term.tuple_size(item) == 2 {
        False -> Error(Gone)
        True -> bounded(ffi_term.coerce(ffi_term.element(2, item)), top_k)
      }
    _ -> Error(Gone)
  }
}

fn bounded(references: List(Term), top_k: Int) -> Result(Report, Failure) {
  let count = seq.length(references)

  case count > max_binaries {
    True -> Error(TooMany(count))
    False -> {
      let initial = #(topk.new(top_k), 0)
      let #(top, bytes) = seq.fold(references, initial, fold_reference)

      Ok(Report(
        count: count,
        bytes: bytes,
        entries: seq.map(topk.descending(top), fn(entry) { entry.1 }),
      ))
    }
  }
}

// A reference of any shape but `{Address, Size, RefCount}` with integers is
// skipped from the listing and the sum, which can only understate: the count
// still includes it.
fn fold_reference(
  acc: #(topk.Top(Entry), Int),
  reference: Term,
) -> #(topk.Top(Entry), Int) {
  let #(top, bytes) = acc

  case is_reference_triple(reference) {
    False -> acc
    True -> {
      let size: Int = ffi_term.coerce(ffi_term.element(2, reference))
      let address: Int = ffi_term.coerce(ffi_term.element(1, reference))
      let refc: Int = ffi_term.coerce(ffi_term.element(3, reference))

      #(
        topk.offer(top, size, Entry(ffi_term.hex_text(address), size, refc)),
        bytes + size,
      )
    }
  }
}

fn is_reference_triple(term: Term) -> Bool {
  ffi_term.is_tuple(term)
  && ffi_term.tuple_size(term) == 3
  && ffi_term.is_integer(ffi_term.element(1, term))
  && ffi_term.is_integer(ffi_term.element(2, term))
  && ffi_term.is_integer(ffi_term.element(3, term))
}
