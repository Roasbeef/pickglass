import gleam/list
import pickglass_agent/internal/ffi_proc
import pickglass_agent/internal/ffi_term
import pickglass_agent/supervision

@external(erlang, "timer", "sleep")
fn sleep(milliseconds: Int) -> a

// A spawned process shows up with the process that spawned it as its parent.
pub fn a_child_is_listed_under_its_spawner_test() {
  let me = ffi_term.pid_text(ffi_proc.self())
  let #(child, _) = ffi_proc.spawn_opt(fn() { sleep(3000) }, [ffi_proc.Monitor])
  let report = supervision.run(supervision.Budget(200_000, 10_000, 2000))

  assert report.coverage.stop == supervision.Finished
  assert list.any(report.edges, fn(edge) {
    edge.pid == child && edge.parent == me
  })
}

// The edge budget stops the walk and says so, with the processes it did not
// reach left uncounted.
pub fn the_edge_budget_stops_the_walk_test() {
  let report = supervision.run(supervision.Budget(200_000, 3, 2000))

  assert list.length(report.edges) == 3
  assert report.coverage.stop == supervision.EdgeBudget
  assert report.coverage.scanned == 3
}

pub fn the_scan_budget_stops_the_walk_test() {
  let report = supervision.run(supervision.Budget(2, 10_000, 2000))

  assert report.coverage.stop == supervision.ScanBudget
  assert report.coverage.scanned == 2
}

pub fn stop_names_are_the_wire_names_test() {
  assert supervision.stop_name(supervision.EdgeBudget) == "edge_budget"
  assert supervision.stop_name(supervision.Finished) == "finished"
}
