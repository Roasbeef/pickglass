//// Node facts and allocator carrier totals.
////
//// The memory report says how much the VM has handed out. This says what the
//// node is: how long it has run, which emulator and how many schedulers,
//// and how much memory its allocators hold in carriers, which is the figure
//// that explains the gap between what `erlang:memory` counts and what the
//// operating system sees.
////
//// Carrier totals come from `instrument:carriers/0`, which belongs to the
//// `runtime_tools` application and is absent from a slim release. When it is
//// absent, or the allocator it needs is disabled, the answer is
//// `Unavailable` with a reason and never a zero: a node whose carriers
//// cannot be read has an unknown carrier total, not an empty one. The call
//// takes about a millisecond on a node with hundreds of carriers and has no
//// side effect, unlike `system_info({allocator, A})`, whose "maximum since
//// the last call" values it would reset for every other tool.

import pickglass_agent/internal/ffi_safe
import pickglass_agent/internal/ffi_term.{type Atom, type Term}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/seq
import pickglass_agent/topk

/// The most allocator rows a report carries.
const max_rows = 64

/// What the node is.
pub type Facts {
  Facts(
    uptime_ms: Int,
    creation: Int,
    emulator_flavor: String,
    emulator_type: String,
    erts_version: String,
    otp_release: String,
    schedulers: Int,
    schedulers_online: Int,
    dirty_cpu: Int,
    dirty_cpu_online: Int,
    dirty_io: Int,
    word_size: Int,
  )
}

/// Whether a carrier sits in the shared carrier pool.
pub type Pool {
  InPool
  NotInPool
}

/// One allocator's carriers, in one pool state: how many there are, how
/// many bytes they hold, how many of those are in allocated blocks, and how
/// many `instrument` skipped to stay responsive.
pub type CarrierRow {
  CarrierRow(
    allocator: String,
    pool: Pool,
    carriers: Int,
    total_bytes: Int,
    used_bytes: Int,
    unscanned_bytes: Int,
  )
}

/// What the carriers reading produced.
pub type Carriers {
  /// The reading could not be taken, and why.
  Unavailable(reason: String)

  /// The carrier totals, largest first.
  Available(rows: List(CarrierRow))
}

/// The system report.
pub type Report {
  Report(facts: Facts, carriers: Carriers)
}

type CarrierMap

@external(erlang, "maps", "new")
fn new_map() -> CarrierMap

@external(erlang, "maps", "get")
fn map_get(
  key: #(Atom, Atom),
  map: CarrierMap,
  default: #(Int, Int, Int, Int),
) -> #(Int, Int, Int, Int)

@external(erlang, "maps", "put")
fn map_put(
  key: #(Atom, Atom),
  value: #(Int, Int, Int, Int),
  map: CarrierMap,
) -> CarrierMap

@external(erlang, "maps", "to_list")
fn map_to_list(map: CarrierMap) -> List(#(#(Atom, Atom), #(Int, Int, Int, Int)))

/// Read the node's facts and carriers on the calling process.
///
/// ## Examples
///
/// ```gleam
/// read().facts.schedulers
/// // -> 16
/// ```
pub fn read() -> Report {
  Report(facts: facts(), carriers: carriers())
}

fn facts() -> Facts {
  let #(dirty_cpu, dirty_cpu_online) = ffi_vm.dirty_cpu_schedulers()

  Facts(
    uptime_ms: ffi_vm.uptime_ms(),
    creation: ffi_vm.creation(),
    emulator_flavor: ffi_vm.emulator_flavor(),
    emulator_type: ffi_vm.emulator_type(),
    erts_version: ffi_vm.erts_version(),
    otp_release: ffi_vm.otp_release(),
    schedulers: ffi_vm.schedulers(),
    schedulers_online: ffi_vm.schedulers_online(),
    dirty_cpu: dirty_cpu,
    dirty_cpu_online: dirty_cpu_online,
    dirty_io: ffi_vm.dirty_io_schedulers(),
    word_size: ffi_vm.word_size(),
  )
}

// `instrument:carriers/0` answers `{ok, {Unit, [Carrier]}}` or
// `{error, Reason}`. A raised call, such as `undef` for a release without
// `runtime_tools`, comes back from the catching call as an error.
fn carriers() -> Carriers {
  case ffi_safe.call(ffi_safe.Instrument, ffi_safe.Carriers, []) {
    Error(Nil) -> Unavailable("instrument_not_loaded")
    Ok(answer) -> carriers_of(answer)
  }
}

fn carriers_of(answer: Term) -> Carriers {
  case
    ffi_term.is_tuple(answer)
    && ffi_term.tuple_size(answer) == 2
    && ffi_term.element(1, answer) == ffi_term.coerce(ffi_term.atom("ok"))
  {
    False -> Unavailable(error_reason(answer))
    True -> {
      let body = ffi_term.element(2, answer)

      case
        ffi_term.is_tuple(body)
        && ffi_term.tuple_size(body) == 2
        && ffi_term.is_list(ffi_term.element(2, body))
      {
        False -> Unavailable("unexpected_answer")
        True -> Available(rows(ffi_term.coerce(ffi_term.element(2, body))))
      }
    }
  }
}

// `{error, not_enabled}` names the reason as an atom; anything else is
// reported without being interpreted.
fn error_reason(answer: Term) -> String {
  case
    ffi_term.is_tuple(answer)
    && ffi_term.tuple_size(answer) == 2
    && ffi_term.is_atom(ffi_term.element(2, answer))
  {
    True -> ffi_term.atom_name(ffi_term.coerce(ffi_term.element(2, answer)))
    False -> "unexpected_answer"
  }
}

// One `instrument` entry per carrier. The agent sums them by allocator and
// pool state, so the reply is as large as the number of allocators and not
// the number of carriers.
fn rows(carriers: List(Term)) -> List(CarrierRow) {
  let sums = seq.fold(carriers, new_map(), add_carrier)
  let top =
    seq.fold(map_to_list(sums), topk.new(max_rows), fn(top, entry) {
      let #(#(allocator, pool), #(count, total, used, unscanned)) = entry

      topk.offer(
        top,
        total,
        CarrierRow(
          allocator: ffi_term.atom_name(allocator),
          pool: case pool == ffi_term.atom("true") {
            True -> InPool
            False -> NotInPool
          },
          carriers: count,
          total_bytes: total,
          used_bytes: used,
          unscanned_bytes: unscanned,
        ),
      )
    })

  seq.map(topk.descending(top), fn(entry) { entry.1 })
}

// A carrier is `{Allocator, InPool, TotalSize, UnscannedSize, Blocks,
// Histogram}`, where `Blocks` is `[{Type, Count, Size}]`. An entry that does
// not have that shape is left out of the sums rather than guessed at.
fn add_carrier(sums: CarrierMap, carrier: Term) -> CarrierMap {
  case
    ffi_term.is_tuple(carrier)
    && ffi_term.tuple_size(carrier) == 6
    && ffi_term.is_atom(ffi_term.element(1, carrier))
    && ffi_term.is_atom(ffi_term.element(2, carrier))
    && ffi_term.is_integer(ffi_term.element(3, carrier))
    && ffi_term.is_integer(ffi_term.element(4, carrier))
    && ffi_term.is_list(ffi_term.element(5, carrier))
  {
    False -> sums
    True -> {
      let key = #(
        ffi_term.coerce(ffi_term.element(1, carrier)),
        ffi_term.coerce(ffi_term.element(2, carrier)),
      )
      let total: Int = ffi_term.coerce(ffi_term.element(3, carrier))
      let unscanned: Int = ffi_term.coerce(ffi_term.element(4, carrier))
      let used = used_bytes(ffi_term.coerce(ffi_term.element(5, carrier)), 0)
      let #(count, sum_total, sum_used, sum_unscanned) =
        map_get(key, sums, #(0, 0, 0, 0))

      map_put(
        key,
        #(
          count + 1,
          sum_total + total,
          sum_used + used,
          sum_unscanned + unscanned,
        ),
        sums,
      )
    }
  }
}

// Bytes in allocated blocks: the sum of the `Size` of each `{Type, Count,
// Size}` the carrier lists.
fn used_bytes(blocks: List(Term), acc: Int) -> Int {
  case blocks {
    [] -> acc
    [block, ..rest] ->
      case
        ffi_term.is_tuple(block)
        && ffi_term.tuple_size(block) == 3
        && ffi_term.is_integer(ffi_term.element(3, block))
      {
        True ->
          used_bytes(rest, acc + ffi_term.coerce(ffi_term.element(3, block)))
        False -> used_bytes(rest, acc)
      }
  }
}
