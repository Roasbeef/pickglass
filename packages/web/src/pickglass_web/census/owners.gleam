//// Building the owners page from a census.
////
//// The viewer has a list of processes, each with an owner attribution from
//// core's `owner.join`. This module turns that list into the page's rows,
//// and it is where the page's two honesty rules are enforced by
//// construction rather than by each caller.
////
//// The `unknown` group is a field of core's `Grouping`, so a model built
//// here always has one, empty or not. And a group's total goes through
//// `owner.group_total`, which refuses a column that overlaps; the binary
//// references column is therefore never summed, and the row builder does not
//// even ask. A total over members some of which were unread is kept as a lower
//// bound with a count of the unread, not rounded to a clean figure.
////
//// Groups are ordered by heap capacity, largest first, because the page
//// exists to find what holds memory. Roles within an owner are grouped by the
//// winning claim's role.
////
//// ## Reading order
////
//// `build` groups the census (`owner.group_by`), builds a row per owner
//// (`group_rows`), a row per role inside it (`role_rows`), and the unknown
//// row; `totals` turns member readings into one row's figures.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string
import pickglass_core/measure.{type Measurement, Known}
import pickglass_core/owner
import pickglass_core/unit
import pickglass_web/key
import pickglass_web/model.{
  type CheckpointRef, type OwnerRow, type OwnersModel, type PanelInfo,
  type ProcRow,
}

/// Build the owners page's model from a census.
///
/// `delta_of` gives the change of heap capacity for an owner's label since
/// the baseline, or the word for why it is unknown; it is called with the
/// label of each row.
///
/// ## Examples
///
/// ```gleam
/// let page = owners.build(info, census, checkpoints, Some(idle0), delta_of)
/// page.unknown.label
/// // -> "unknown"
/// ```
pub fn build(
  info: PanelInfo,
  census: List(ProcRow),
  checkpoints: List(CheckpointRef),
  baseline: Option(CheckpointRef),
  delta_of: fn(String) -> Measurement,
) -> OwnersModel {
  let grouping = owner.group_by(census, fn(p) { p.attribution }, 1)

  let rows =
    grouping.owned
    |> list.map(fn(group) { owner_rows(group, delta_of) })
    |> list.sort(fn(a, b) { compare_heap(a.0, b.0) })
    |> list.flat_map(fn(pair) { [pair.0, ..pair.1] })

  let unlabelled = list.length(grouping.unknown.members)

  model.OwnersModel(
    info:,
    rows:,
    unknown: unknown_row(grouping.unknown.members, delta_of),
    checkpoints:,
    baseline:,
    labelled: #(list.length(census) - unlabelled, unlabelled),
    remainder: model.NoRemainder,
    rate_ms: None,
  )
}

/// Record what the owner rows leave out.
///
/// The agent returns the top K groups by heap capacity and, separately, the
/// node's process count and the heap of everything it did not list. The
/// remainder row is that difference, so a reader never mistakes the listed
/// rows for the whole node. A `procs` of zero means nothing is left out and
/// the row is not drawn.
///
/// ## Examples
///
/// ```gleam
/// owners.with_remainder(page, procs: 3398, heap_cap: Known(41 * mib))
/// ```
pub fn with_remainder(
  page: OwnersModel,
  procs procs: Int,
  heap_cap heap_cap: Measurement,
) -> OwnersModel {
  case procs > 0 {
    True ->
      model.OwnersModel(
        ..page,
        remainder: model.Remainder(procs: Known(procs), heap_cap:),
      )
    False -> model.OwnersModel(..page, remainder: model.NoRemainder)
  }
}

// Larger heap first; a row with no known capacity sorts last.
fn compare_heap(a: OwnerRow, b: OwnerRow) -> order.Order {
  int.compare(heap_value(b), heap_value(a))
}

fn heap_value(row: OwnerRow) -> Int {
  case row.heap_cap {
    Known(value:) -> value
    _ -> -1
  }
}

// One owner row followed by its role rows, which carry the members.
fn owner_rows(
  group: owner.Group(ProcRow),
  delta_of: fn(String) -> Measurement,
) -> #(OwnerRow, List(OwnerRow)) {
  let label = case group.key {
    owner.Owned(path:) -> owner.path_to_string(path)
    owner.Unknown -> "unknown"
  }

  let roles = by_role(group.members)

  let role_rows =
    roles
    |> list.map(fn(entry) { role_row(label, entry.0, entry.1, delta_of) })
    |> list.sort(compare_heap)

  let head =
    summary_row(
      key.make("owner:" <> label),
      model.OwnerGroup,
      label,
      0,
      strongest_source(group.members),
      group.members,
      delta_of(label),
    )

  #(model.OwnerRow(..head, members: []), role_rows)
}

fn role_row(
  owner_label: String,
  role: String,
  members: List(ProcRow),
  delta_of: fn(String) -> Measurement,
) -> OwnerRow {
  let label = owner_label <> " / " <> role

  summary_row(
    key.make("role:" <> label),
    model.RoleGroup,
    role,
    1,
    strongest_source(members),
    members,
    delta_of(label),
  )
}

fn unknown_row(
  members: List(ProcRow),
  delta_of: fn(String) -> Measurement,
) -> OwnerRow {
  summary_row(
    key.make("unknown"),
    model.UnknownGroup,
    "unknown",
    0,
    None,
    members,
    delta_of("unknown"),
  )
}

fn summary_row(
  id: key.Key,
  kind: model.OwnerKind,
  label: String,
  depth: Int,
  source: Option(owner.Source),
  members: List(ProcRow),
  delta: Measurement,
) -> OwnerRow {
  model.OwnerRow(
    key: id,
    kind:,
    label:,
    depth:,
    source:,
    dissent: dissent_count(members),
    procs: Known(list.length(members)),
    heap_cap: total(members, fn(p) { p.heap_cap }, unit.Bytes),
    unread: unread(members, fn(p) { p.heap_cap }),
    delta:,
    mailbox: total(members, fn(p) { p.mailbox }, unit.Count),
    reductions: total(members, fn(p) { p.reductions }, unit.Reductions),
    binary_refs: measure.NotApplicable,
    members:,
  )
}

// The sum of an additive column over members. With nothing known the row
// shows the first absent reading's reason, or not-applicable for no members;
// it is never a zero total.
fn total(
  members: List(ProcRow),
  column: fn(ProcRow) -> Measurement,
  u: unit.Unit,
) -> Measurement {
  let group = owner.Group(key: owner.Unknown, members:)

  case owner.group_total(group, u, measure.Additive, column) {
    Ok(sum) -> Known(sum.value)
    Error(_) -> first_absent(members, column)
  }
}

fn first_absent(
  members: List(ProcRow),
  column: fn(ProcRow) -> Measurement,
) -> Measurement {
  case list.find(list.map(members, column), fn(m) { !is_known(m) }) {
    Ok(absent) -> absent
    Error(Nil) -> measure.NotApplicable
  }
}

fn is_known(m: Measurement) -> Bool {
  case m {
    Known(_) -> True
    _ -> False
  }
}

fn unread(members: List(ProcRow), column: fn(ProcRow) -> Measurement) -> Int {
  list.count(members, fn(p) { !is_known(column(p)) })
}

// Group members by the role of the claim that won their attribution.
fn by_role(members: List(ProcRow)) -> List(#(String, List(ProcRow))) {
  let grouped =
    list.fold(members, dict.new(), fn(acc, member) {
      let role = case member.attribution {
        owner.Attributed(winner:, ..) -> winner.role
        owner.Unattributed -> "unknown"
      }

      dict.upsert(acc, role, fn(existing) {
        case existing {
          Some(rows) -> [member, ..rows]
          None -> [member]
        }
      })
    })

  grouped
  |> dict.to_list
  |> list.map(fn(entry) { #(entry.0, list.reverse(entry.1)) })
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
}

fn strongest_source(members: List(ProcRow)) -> Option(owner.Source) {
  members
  |> list.filter_map(fn(member) {
    case member.attribution {
      owner.Attributed(winner:, ..) -> Ok(winner.source)
      owner.Unattributed -> Error(Nil)
    }
  })
  |> list.first
  |> option.from_result
}

fn dissent_count(members: List(ProcRow)) -> Int {
  list.fold(members, 0, fn(count, member) {
    case member.attribution {
      owner.Attributed(dissent:, ..) -> count + list.length(dissent)
      owner.Unattributed -> count
    }
  })
}
