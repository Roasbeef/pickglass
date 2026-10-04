import pickglass_agent/detail
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term
import pickglass_agent/owner.{Owned}

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

// A process reads back with every size in bytes and the counts the page
// shows, and its label decodes to its owner.
pub fn a_live_process_reads_back_test() {
  owner.claim_self()

  let assert Ok(found) = detail.read(ffi_proc.self())
    as "the test process can read itself"

  assert found.heap.memory_bytes > 0
  assert found.heap.total_heap_bytes > 0
  assert found.heap.heap_block_bytes > 0
  assert found.gc.fullsweep_after > 0
  assert found.owner == Owned([#("tool", "pickglass")], "agent")
  assert found.capabilities == []
  assert ffi_term.atom_name(found.status) == "running"
}

// The parent is whoever spawned the process, as text, and the counts are
// counts of identifiers and not the identifiers themselves.
pub fn parent_and_relations_are_reported_test() {
  let me = ffi_proc.self()
  let #(child, _) = ffi_proc.spawn_opt(fn() { sleep(2000) }, [ffi_proc.Monitor])
  let assert Ok(found) = detail.read(child) as "the child is alive"

  assert found.relations.parent == ffi_term.pid_text(me)
  assert found.relations.links == 0
  assert found.relations.monitors == 0
}

// A process that exits before the read is an error and never a record of
// zeros.
pub fn an_exited_process_is_an_error_test() {
  let #(child, _) = ffi_proc.spawn_opt(fn() { Nil }, [ffi_proc.Monitor])
  sleep(100)

  assert detail.read(child) == Error(Nil)
  assert detail.read_heap(child) == Error(Nil)
}

pub fn heap_readings_are_comparable_test() {
  let assert Ok(first) = detail.read_heap(ffi_proc.self())
    as "the test process can read its heap"

  assert first.memory_bytes > 0
  assert first.total_heap_bytes >= first.heap_bytes
}
