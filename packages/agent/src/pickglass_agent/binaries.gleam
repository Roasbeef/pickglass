//// The reference-counted binaries one process holds.
////
//// A process's memory figure does not say how much of it is binaries: a
//// reference-counted binary (larger than 64 bytes) lives off the heap and the
//// process holds a small reference to it. `process_info(Pid, binary)` lists
//// those references as `{Address, Size, RefCount}`, which is how a leak of
//// large binaries through a long-lived process is told from a leak of heap.
//// The list is one entry per reference, and a process often holds the same
//// binary through many references (a sub-binary, or a copy of a message that
//// carried it): measured on an idle Loom daemon, one supervisor held a 121 KB
//// binary through 100 references, so summing the entries would report 3.9 MB
//// for 121 KB. The read therefore counts a binary once, by its address, for
//// the total and the listing, and reports the number of references beside
//// it. A sub-binary shows the whole binary's size, so the total is what the
//// process keeps alive, not memory unique to it.
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

import pickglass_agent/internal/ffi_map
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
/// reads while it lives, and `refc` is how many references to it exist in the
/// whole node.
pub type Entry {
  Entry(address: String, bytes: Int, refc: Int)
}

/// What a process holds. `distinct` is the number of different binaries and
/// `bytes` their total size. `references` is how many references the process
/// holds to them, at least `distinct`. `entries` is the largest binaries, so
/// `distinct` minus the length of `entries` is how many the listing leaves
/// out.
pub type Report {
  Report(distinct: Int, bytes: Int, references: Int, entries: List(Entry))
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
      let initial = Tally(topk.new(top_k), ffi_map.new(), 0, 0)
      let tally = seq.fold(references, initial, fold_reference)

      Ok(Report(
        distinct: tally.distinct,
        bytes: tally.bytes,
        references: count,
        entries: seq.map(topk.descending(tally.top), fn(entry) { entry.1 }),
      ))
    }
  }
}

// The running result of the fold: the largest binaries, the addresses already
// counted, and the distinct count and byte total.
type Tally {
  Tally(top: topk.Top(Entry), seen: ffi_map.Map, distinct: Int, bytes: Int)
}

// A reference of any shape but `{Address, Size, RefCount}` with integers is
// left out of the listing and the sums, which can only understate. A binary
// whose address was already counted adds nothing, so the same binary held
// through many references is one binary of its own size.
fn fold_reference(tally: Tally, reference: Term) -> Tally {
  case is_reference_triple(reference) {
    False -> tally
    True -> {
      let address = ffi_term.element(1, reference)

      case ffi_map.has_key(address, tally.seen) {
        True -> tally
        False -> {
          let size: Int = ffi_term.coerce(ffi_term.element(2, reference))
          let refc: Int = ffi_term.coerce(ffi_term.element(3, reference))
          let entry =
            Entry(ffi_term.hex_text(ffi_term.coerce(address)), size, refc)

          Tally(
            top: topk.offer(tally.top, size, entry),
            seen: ffi_map.put(address, ffi_term.coerce(True), tally.seen),
            distinct: tally.distinct + 1,
            bytes: tally.bytes + size,
          )
        }
      }
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
