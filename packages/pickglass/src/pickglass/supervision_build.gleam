//// The supervision page from the agent's spawn edges.
////
//// The agent reports, for each process it scanned, who spawned it
//// (`process_info(parent)`). For an OTP child that is its supervisor, which
//// is why this is a supervision tree at all; for any other process it is
//// whichever process called `spawn`, and the page says so in its caveat
//// instead of presenting every edge as supervision. A parent is evidence,
//// not a proof, and the page is labelled as evidence.
////
//// Edges name a child and a parent. A root is a process whose parent is not
//// itself a scanned child: the empty parent, a parent that has exited, or
//// one outside the walk. Children are ordered by pid text so the tree is the
//// same from one feed to the next. The drawn tree is bounded: past
//// `max_nodes` nodes the rest is counted in `omitted`, because a node of
//// thousands of processes would otherwise be thousands of elements.
////
//// A node's kind is read from its initial call. Where the census listed the
//// process, its `proc_lib` `$initial_call` is known (the `owners_detail`
//// rows carry it): a supervisor's is `supervisor:my_sup/1`, and a process
//// whose call is anything else is a `Worker`, even when something it spawned
//// shows below it. That is evidence about the process and not a guess from
//// its name.
////
//// Where the census did not list the process (it lists only its top rows) or
//// `proc_lib` did not start it, there is only the call `process_info`
//// reports, which for an OTP process is `proc_lib:init_p/5`, and the
//// registered name: a name ending in `_sup` is how OTP's own supervisors are
//// named. That is a hint and nothing stronger. A process with no children and
//// no hint is a `Leaf`, and the page does not call it a worker because a
//// supervisor with nothing to supervise looks the same. A process with
//// children and no hint is `UnknownKind`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/string
import pickglass_core/measure
import pickglass_core/owner
import pickglass_core/wire
import pickglass_web/key
import pickglass_web/model

/// The most nodes drawn.
pub const max_nodes = 400

/// What the page says about the edges it draws.
pub const caveat =
  "A parent here is whoever spawned the process. For an OTP child that is its supervisor; for any other process it may be an unrelated spawner. Treat the tree as evidence of supervision, not a proof of it."

/// Build the page's model. `info` is the panel's title-bar line.
///
/// ## Examples
///
/// ```gleam
/// supervision_build.build(info, snapshot, dict.new())
/// ```
pub fn build(
  info: model.PanelInfo,
  snapshot: wire.SupervisionSnapshot,
  initial_calls: Dict(String, String),
) -> model.SupervisionModel {
  let edges = snapshot.edges
  let known =
    dict.from_list(list.map(edges, fn(edge) { #(edge.child_pid_text, Nil) }))
  let children = children_of(edges)
  let roots =
    edges
    |> list.filter(fn(edge) {
      edge.parent_pid_text == "" || !dict.has_key(known, edge.parent_pid_text)
    })
    |> list.sort(by_pid)
  let #(drawn, budget) =
    list.fold(roots, #([], max_nodes), fn(state, edge) {
      let #(nodes, left) = state
      let #(node, left) = node_of(edge, children, initial_calls, left)

      case node {
        Some(found) -> #([found, ..nodes], left)
        None -> #(nodes, left)
      }
    })

  model.SupervisionModel(
    info:,
    roots: list.reverse(drawn),
    caveat:,
    omitted: list.length(edges) - { max_nodes - budget },
  )
}

fn by_pid(a: wire.SpawnEdge, b: wire.SpawnEdge) -> order.Order {
  string.compare(a.child_pid_text, b.child_pid_text)
}

fn children_of(
  edges: List(wire.SpawnEdge),
) -> Dict(String, List(wire.SpawnEdge)) {
  list.fold(edges, dict.new(), fn(table, edge) {
    dict.upsert(table, edge.parent_pid_text, fn(existing) {
      case existing {
        Some(found) -> [edge, ..found]
        None -> [edge]
      }
    })
  })
}

// One node and, while the budget lasts, its children. The budget counts
// nodes drawn across the whole tree, so a wide level cannot spend more than
// is left.
fn node_of(
  edge: wire.SpawnEdge,
  children: Dict(String, List(wire.SpawnEdge)),
  initial_calls: Dict(String, String),
  budget: Int,
) -> #(option.Option(model.SupNode), Int) {
  case budget <= 0 {
    True -> #(None, 0)
    False -> {
      let below =
        dict.get(children, edge.child_pid_text)
        |> option.from_result
        |> option.unwrap([])
        |> list.sort(by_pid)
      let #(drawn, left) =
        list.fold(below, #([], budget - 1), fn(state, child) {
          let #(nodes, left) = state
          let #(node, left) = node_of(child, children, initial_calls, left)

          case node {
            Some(found) -> #([found, ..nodes], left)
            None -> #(nodes, left)
          }
        })

      #(
        Some(model.SupNode(
          key: key.make(edge.child_pid_text),
          label: label_of(edge),
          kind: kind_of(edge, below, initial_calls),
          owner_label: owner_label(edge.owner),
          children: list.reverse(drawn),
        )),
        left,
      )
    }
  }
}

fn label_of(edge: wire.SpawnEdge) -> String {
  case edge.registered_name {
    "" -> edge.child_pid_text
    name -> name <> " " <> edge.child_pid_text
  }
}

fn kind_of(
  edge: wire.SpawnEdge,
  below: List(wire.SpawnEdge),
  initial_calls: Dict(String, String),
) -> model.SupKind {
  case dict.get(initial_calls, edge.child_pid_text) {
    // The process's own `$initial_call` is known, so its kind is read from
    // it and not guessed from a name.
    Ok(call) ->
      case is_supervisor_call(call) {
        True -> model.Supervisor
        False -> model.Worker
      }

    // The census did not list it, or `proc_lib` did not start it: only the
    // hints are left.
    Error(Nil) -> {
      let named = string.contains(edge.initial_call, "supervisor")
      let supervisor = named || string.ends_with(edge.registered_name, "_sup")

      case supervisor, below {
        True, _ -> model.Supervisor
        False, [] -> model.Leaf
        False, [_, ..] -> model.UnknownKind
      }
    }
  }
}

// A `proc_lib` initial call is `module:function/arity`, and a supervisor's
// module is `supervisor` (or `supervisor_bridge`), whatever callback module
// it runs, which is the function's name.
fn is_supervisor_call(call: String) -> Bool {
  string.starts_with(call, "supervisor:")
  || string.starts_with(call, "supervisor_bridge:")
}

fn owner_label(reading: wire.OwnerReading) -> option.Option(String) {
  case reading {
    wire.Unlabelled -> None
    wire.Labelled(path:, role:) ->
      Some(owner.path_to_string(path) <> " / " <> role)
  }
}

/// The page's coverage figures from the walk's own: how many processes the
/// walk scanned of how many there were, and why it stopped.
///
/// ## Examples
///
/// ```gleam
/// supervision_build.outcome(coverage)
/// ```
pub fn outcome(coverage: wire.SupervisionCoverage) -> measure.Outcome {
  case coverage.stop {
    wire.SupervisionFinished -> measure.Complete
    wire.SupervisionScanBudget | wire.SupervisionEdgeBudget ->
      measure.Partial(measure.Truncated(measure.BudgetReached))
    wire.SupervisionDeadline ->
      measure.Partial(measure.Truncated(measure.DeadlineHit))
  }
}

/// How many nodes a model draws, for tests and for the page's own note.
pub fn drawn(page: model.SupervisionModel) -> Int {
  list.fold(page.roots, 0, fn(sum, node) { sum + count(node) })
}

fn count(node: model.SupNode) -> Int {
  1 + list.fold(node.children, 0, fn(sum, child) { sum + count(child) })
}

/// Total edges, for the page's note.
pub fn edge_count(snapshot: wire.SupervisionSnapshot) -> Int {
  int.min(list.length(snapshot.edges), 10_000)
}
