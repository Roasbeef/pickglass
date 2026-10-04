//// Choosing the processes a one-click profile samples.
////
//// A profile button names a group of processes, such as an owner, the whole
//// node, or one process, and a stack probe takes at most sixteen targets. So
//// something has to choose, and it has to say what it chose, because a plan
//// that names sixteen of thirty-one processes without saying so reads as a
//// profile of all of them.
////
//// The choice is the processes that did the most work in the last pass:
//// ordered by reductions per second between the two newest census passes,
//// then by heap capacity, then by pid text so equal processes are always
//// chosen in the same order. A process with no rate (it was not in both
//// passes, or there has been only one pass) ranks below every process with
//// one, and is not given a rate of zero. When no process has a rate at all
//// the order is by heap alone, and the sentence says why.
////
//// The module is pure. The web mount builds `Candidate`s from the census
//// rows it holds and the command line builds them from its own observations,
//// so the two choose by the same rule and word the result the same way.
////
//// ## Flow
////
//// - `candidates_of` reads the rows of the newest pass.
//// - `choose` ranks them, cuts at the limit and writes the sentence the plan
////   card shows (`describe`).

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import pickglass_core/measure
import pickglass_web/model

/// One process that may be sampled.
pub type Candidate {
  Candidate(
    /// The pid as text, as the census row showed it.
    pid_text: String,
    /// Reductions per second over the last two passes, when the process was
    /// in both.
    rate: Option(Int),
    /// Heap capacity in bytes, zero when it was not read.
    heap_bytes: Int,
  )
}

/// What the profile is of, which decides how the choice is worded.
pub type Scope {
  /// The processes of one owner, named as the owners page names it.
  OwnerScope(label: String)

  /// Every listed process of the node.
  WholeNode

  /// One named process.
  OneProcess(pid_text: String)
}

/// The processes chosen and the sentence that says how.
pub type Chosen {
  Chosen(
    /// The pid texts, busiest first.
    pids: List(String),
    /// How many processes the choice was made from.
    listed: Int,
    /// The sentence for the plan card, such as "12 of 31 listed processes of
    /// session:abc, the busiest by reductions/s".
    sentence: String,
  )
}

/// Why nothing was chosen.
pub type Refusal {
  /// The scope has no process in the last pass. The text says which scope.
  NothingToProfile(reason: String)
}

/// The candidates among the rows of a census pass.
///
/// ## Examples
///
/// ```gleam
/// profile_scope.candidates_of(rows)
/// // -> [Candidate("<0.91.0>", Some(1200), 233_000), ..]
/// ```
pub fn candidates_of(rows: List(model.ProcRow)) -> List(Candidate) {
  list.map(rows, fn(row) {
    Candidate(
      pid_text: row.pid_text,
      rate: measure.to_option(row.reductions),
      heap_bytes: option.unwrap(measure.to_option(row.heap_cap), 0),
    )
  })
}

/// Choose at most `limit` of the candidates, the busiest first.
///
/// ## Examples
///
/// ```gleam
/// profile_scope.choose(candidates, 16, OwnerScope("session:abc"))
/// // -> Ok(Chosen(pids, 31, "16 of 31 listed processes of session:abc, ..."))
/// ```
pub fn choose(
  candidates: List(Candidate),
  limit: Int,
  scope: Scope,
) -> Result(Chosen, Refusal) {
  case candidates {
    [] -> Error(NothingToProfile(none_text(scope)))
    _ -> {
      let ranked = list.sort(candidates, busiest_first)
      let chosen = list.take(ranked, limit)
      let listed = list.length(ranked)
      let ranking = case list.any(candidates, fn(c) { c.rate != None }) {
        True -> ByReductions
        False -> ByHeap
      }

      Ok(Chosen(
        pids: list.map(chosen, fn(candidate) { candidate.pid_text }),
        listed:,
        sentence: describe(scope, list.length(chosen), listed, ranking),
      ))
    }
  }
}

// What the ranking used, for the sentence.
type Ranking {
  ByReductions
  ByHeap
}

// A rate beats no rate, a higher rate beats a lower one, then a larger heap,
// then the pid text, so the order is total and repeatable.
fn busiest_first(a: Candidate, b: Candidate) -> order.Order {
  order.break_tie(
    compare_rates(a.rate, b.rate),
    order.break_tie(
      int.compare(b.heap_bytes, a.heap_bytes),
      string.compare(a.pid_text, b.pid_text),
    ),
  )
}

fn compare_rates(a: Option(Int), b: Option(Int)) -> order.Order {
  case a, b {
    Some(x), Some(y) -> int.compare(y, x)
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> order.Eq
  }
}

fn none_text(scope: Scope) -> String {
  case scope {
    OwnerScope(label:) ->
      "the last pass lists no live process of " <> owner_name(label)
    WholeNode -> "the last pass lists no process"
    OneProcess(pid_text:) ->
      "the last pass does not list " <> pid_text <> ", which may have exited"
  }
}

fn owner_name(label: String) -> String {
  case label {
    "unknown" -> "the unknown owner"
    other -> other
  }
}

// The sentence for the plan card. A choice that took every candidate says
// "all"; one that cut says how many of how many and by what ranking, since
// that is the figure a reader needs to avoid taking the profile for the whole
// group.
fn describe(scope: Scope, taken: Int, listed: Int, ranking: Ranking) -> String {
  let counts = int.to_string(taken) <> " of " <> int.to_string(listed)
  let by = case ranking {
    ByReductions -> "the busiest by reductions/s"
    ByHeap -> "the largest by heap, since reductions/s needs two census passes"
  }

  case scope, taken < listed {
    OneProcess(pid_text:), _ -> pid_text
    OwnerScope(label:), False ->
      "all "
      <> int.to_string(listed)
      <> " listed processes of "
      <> owner_name(label)
    OwnerScope(label:), True ->
      counts <> " listed processes of " <> owner_name(label) <> ", " <> by
    WholeNode, False ->
      "all " <> int.to_string(listed) <> " listed processes of the node"
    WholeNode, True -> counts <> " listed processes of the node, " <> by
  }
}
