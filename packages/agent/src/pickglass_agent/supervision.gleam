//// The supervision walk: parent edges over the node, without asking a
//// single supervisor anything.
////
//// A process's `parent` is whoever spawned it. For a child of an OTP
//// supervisor that is the supervisor, so the set of `(child, parent)` edges
//// over every process is the supervision forest, and it is read with the
//// same iterator walk as the census instead of `supervisor:which_children`,
//// which blocks on each supervisor and can be answered late or never by a
//// busy one. The cost is a weaker claim: a parent is a spawner, so a process
//// an unrelated process started appears under that process, and the viewer
//// labels the tree "by spawner".
////
//// The walk is bounded three ways: processes scanned, edges returned and a
//// deadline. Whichever ends it first is the `Stop` in the coverage, so a
//// partial tree says why it is partial. It sends nothing; the server runs it
//// in a worker.

import pickglass_agent/internal/detail_info.{
  type Info, InitialCall, Label, Parent, RegisteredName,
}
import pickglass_agent/internal/ffi_proc.{type Iterator}
import pickglass_agent/internal/ffi_term.{type Pid, type Term}
import pickglass_agent/internal/ffi_vm
import pickglass_agent/internal/seq
import pickglass_agent/owner.{type Owner, Unknown}

/// How much work one walk may do.
pub type Budget {
  Budget(max_scanned: Int, max_edges: Int, deadline_ms: Int)
}

/// Why the walk ended.
pub type Stop {
  /// The iterator ran out.
  Finished

  /// The scan budget was reached with processes unvisited.
  ScanBudget

  /// The deadline passed with processes unvisited.
  Deadline

  /// The edge budget was reached with processes unvisited.
  EdgeBudget
}

/// One process and the process that spawned it. `parent` is the empty string
/// for a process whose parent is not recorded.
pub type Edge {
  Edge(
    pid: Pid,
    parent: String,
    registered_name: Term,
    initial_call: Term,
    owner: Owner,
  )
}

/// How much of the node the walk covered.
pub type Coverage {
  Coverage(scanned: Int, total: Int, stop: Stop, elapsed_ms: Int)
}

/// The walk's result.
pub type Report {
  Report(edges: List(Edge), coverage: Coverage)
}

type Walk {
  Walk(edges: List(Edge), edge_count: Int, scanned: Int, stop: Stop)
}

/// How many processes to walk between looks at the clock.
const clock_interval = 1024

/// Walk every process once and collect parent edges, on the calling process.
///
/// ## Examples
///
/// ```gleam
/// run(Budget(max_scanned: 200_000, max_edges: 10_000, deadline_ms: 2000))
/// // -> Report(edges: [...], coverage: Coverage(...))
/// ```
pub fn run(budget: Budget) -> Report {
  let started = ffi_proc.now_ms()
  let total = ffi_vm.process_count()
  let initial = Walk([], 0, 0, Finished)
  let walk = step(ffi_proc.processes_iterator(), initial, budget, started)

  Report(
    edges: seq.reverse(walk.edges),
    coverage: Coverage(
      scanned: walk.scanned,
      total: total,
      stop: walk.stop,
      elapsed_ms: ffi_proc.now_ms() - started,
    ),
  )
}

// One turn of the walk. A process pulled from the iterator after a budget is
// spent is not counted: it is the evidence that the walk stopped early.
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

fn over_budget(walk: Walk, budget: Budget, started: Int) -> Stop {
  case walk.scanned >= budget.max_scanned, walk.edge_count >= budget.max_edges {
    True, _ -> ScanBudget
    False, True -> EdgeBudget
    False, False ->
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
  case detail_info.read_edge(pid) {
    // The process exited between the iterator yielding it and this read.
    Error(Nil) -> walk
    Ok(infos) ->
      Walk(
        ..walk,
        edges: [seq.fold(infos, empty_edge(pid), apply_info), ..walk.edges],
        edge_count: walk.edge_count + 1,
        scanned: walk.scanned + 1,
      )
  }
}

fn empty_edge(pid: Pid) -> Edge {
  Edge(
    pid: pid,
    parent: "",
    registered_name: ffi_term.coerce(0),
    initial_call: ffi_term.coerce(0),
    owner: Unknown,
  )
}

fn apply_info(edge: Edge, info: Info) -> Edge {
  case info {
    Parent(parent) -> Edge(..edge, parent: ffi_term.pid_text_or_empty(parent))
    RegisteredName(name) -> Edge(..edge, registered_name: name)
    InitialCall(call) -> Edge(..edge, initial_call: call)
    Label(label) -> Edge(..edge, owner: owner.decode(label))
    _ -> edge
  }
}

/// The wire name of a stop reason.
///
/// ## Examples
///
/// ```gleam
/// stop_name(EdgeBudget)
/// // -> "edge_budget"
/// ```
pub fn stop_name(stop: Stop) -> String {
  case stop {
    Finished -> "finished"
    ScanBudget -> "scan_budget"
    Deadline -> "deadline"
    EdgeBudget -> "edge_budget"
  }
}
