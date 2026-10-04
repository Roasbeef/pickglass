//// The ownership vocabulary: owner paths, roles, the sources that claim
//// them, and the grouping that every owner view is built on.
////
//// Pickglass does not know what a Loom session is. A host declares
//// ownership by labelling its own processes with a path of
//// `{kind, id}` segments, outermost first, and a role. Other evidence,
//// such as a registry the host reports or the supervision tree, can claim
//// an owner too. This module defines what a claim is, how competing claims
//// join into one attribution, and how a list of things groups by owner.
////
//// Two rules keep the views honest. First, every claim keeps its source and
//// confidence, and the join prefers a process's own label over the host's
//// registry over the supervision tree, so a weaker source can fill a gap
//// but never overrides a stronger one; a disagreeing weaker claim is kept
//// as dissent for the UI to show. Second, every grouping has an explicit
//// `unknown` group, present even when empty, so an unlabelled process is
//// visible as the thing to fix rather than silently absent.
////
//// ## Flow
////
//// - `segment` builds a path segment; `join` picks one claim from many.
//// - `group_by` groups items by their attribution at a path depth.
//// - `group_total` sums a group's column, honoring additivity.

import gleam/int
import gleam/list
import gleam/order.{type Order}
import gleam/string
import pickglass_core/measure.{
  type Additivity, type Measurement, type SumRefusal, type Total,
}
import pickglass_core/unit.{type Unit}

// ------------------------------------------------------------ vocabulary

/// One step of an owner path: a kind such as `session` and an id.
pub type Segment {
  Segment(kind: String, id: String)
}

/// The longest kind or id accepted in a segment.
pub const max_segment_length = 128

/// Build a segment. Kind and id must be non-empty, at most 128 characters,
/// and must not contain `/` or a newline, which `path_to_string` and the
/// capture format use as separators.
///
/// ## Examples
///
/// ```gleam
/// owner.segment("session", "s-12")
/// // -> Ok(Segment("session", "s-12"))
///
/// owner.segment("", "x")
/// // -> Error(Nil)
/// ```
pub fn segment(kind: String, id: String) -> Result(Segment, Nil) {
  case valid_part(kind) && valid_part(id) {
    True -> Ok(Segment(kind:, id:))
    False -> Error(Nil)
  }
}

fn valid_part(text: String) -> Bool {
  let length = string.length(text)

  length >= 1
  && length <= max_segment_length
  && !string.contains(text, "/")
  && !string.contains(text, "\n")
}

/// An owner path from outermost to innermost, for Loom
/// `[session s-12, strand main]`.
pub type Path =
  List(Segment)

/// Render a path as `session:s-12/strand:main`.
///
/// ## Examples
///
/// ```gleam
/// owner.path_to_string([Segment("session", "s-12")])
/// // -> "session:s-12"
/// ```
pub fn path_to_string(path: Path) -> String {
  path
  |> list.map(fn(segment) { segment.kind <> ":" <> segment.id })
  |> string.join("/")
}

/// Order paths by their rendered text, for stable group ordering.
pub fn compare_path(a: Path, b: Path) -> Order {
  string.compare(path_to_string(a), path_to_string(b))
}

/// Where an ownership claim came from.
pub type Source {
  /// The process labelled itself. The strongest claim.
  Declared

  /// The host reported it, for example a summary or an OS child.
  Provider

  /// A name registry the host maintains.
  Registry

  /// The process's place in the supervision tree: structural evidence,
  /// used only when nothing stronger claims the process.
  Supervision
}

/// How far a claim can be trusted within its source.
pub type Confidence {
  Low
  Medium
  High
}

/// One source's claim that a thing belongs to an owner.
pub type Claim {
  Claim(
    path: Path,
    /// The role within the owner, such as `restart_keeper`.
    role: String,
    source: Source,
    confidence: Confidence,
  )
}

/// The stable code of a source.
pub fn source_code(source: Source) -> String {
  case source {
    Declared -> "declared"
    Provider -> "provider"
    Registry -> "registry"
    Supervision -> "supervision"
  }
}

/// Parse a source code; any other text is an error.
pub fn parse_source(code: String) -> Result(Source, Nil) {
  list.find([Declared, Provider, Registry, Supervision], fn(source) {
    source_code(source) == code
  })
}

/// The stable code of a confidence.
pub fn confidence_code(confidence: Confidence) -> String {
  case confidence {
    Low -> "low"
    Medium -> "medium"
    High -> "high"
  }
}

/// Parse a confidence code; any other text is an error.
pub fn parse_confidence(code: String) -> Result(Confidence, Nil) {
  list.find([Low, Medium, High], fn(confidence) {
    confidence_code(confidence) == code
  })
}

// ------------------------------------------------------------------ join

/// The result of joining all claims about one thing.
pub type Attribution {
  /// One claim won. `dissent` holds the other claims whose path differs,
  /// strongest first, for the UI to show.
  Attributed(winner: Claim, dissent: List(Claim))

  /// No usable claim: the thing is `unknown`.
  Unattributed
}

/// Join claims by source strength: a label over the provider over the
/// registry over supervision. Within one source the higher confidence wins,
/// and a tie keeps the earlier claim. A claim with an empty path says
/// nothing and is ignored.
///
/// ## Examples
///
/// ```gleam
/// owner.join([supervision_claim, label_claim])
/// // -> Attributed(label_claim, dissent: [supervision_claim]) when the
/// //    paths differ
///
/// owner.join([])
/// // -> Unattributed
/// ```
pub fn join(claims: List(Claim)) -> Attribution {
  let usable = list.filter(claims, fn(claim) { claim.path != [] })
  let ranked = list.sort(usable, by: compare_claim)

  case ranked {
    [] -> Unattributed
    [winner, ..rest] ->
      Attributed(
        winner:,
        dissent: list.filter(rest, fn(claim) { claim.path != winner.path }),
      )
  }
}

// Stronger source first, then higher confidence first. `list.sort` is
// stable, so a full tie keeps the caller's order.
fn compare_claim(a: Claim, b: Claim) -> Order {
  order.break_tie(
    int.compare(source_rank(a.source), source_rank(b.source)),
    int.compare(confidence_rank(b.confidence), confidence_rank(a.confidence)),
  )
}

fn source_rank(source: Source) -> Int {
  case source {
    Declared -> 0
    Provider -> 1
    Registry -> 2
    Supervision -> 3
  }
}

fn confidence_rank(confidence: Confidence) -> Int {
  case confidence {
    Low -> 0
    Medium -> 1
    High -> 2
  }
}

// -------------------------------------------------------------- grouping

/// The key of a group.
pub type GroupKey {
  /// Things attributed to this owner path.
  Owned(path: Path)

  /// Things nobody claimed.
  Unknown
}

/// The things that share one key.
pub type Group(a) {
  Group(key: GroupKey, members: List(a))
}

/// Items grouped by owner. `unknown` is a field, not a list element, so
/// the type cannot represent a grouping without one.
pub type Grouping(a) {
  Grouping(
    /// Groups of attributed items, ordered by rendered path.
    owned: List(Group(a)),
    /// The unknown group; its members may be empty.
    unknown: Group(a),
  )
}

/// Group items by the owner path their attribution gives, truncated to
/// `depth` segments (a depth below one is read as one). An item with no
/// attribution goes to the unknown group, which is present even when it
/// has no members.
///
/// ## Examples
///
/// ```gleam
/// owner.group_by([], fn(_) { owner.Unattributed }, 1).unknown
/// // -> Group(Unknown, [])
/// ```
pub fn group_by(
  items: List(a),
  attribution_of attribution_of: fn(a) -> Attribution,
  depth depth: Int,
) -> Grouping(a) {
  let keyed =
    list.map(items, fn(item) {
      #(key_of(attribution_of(item), int.max(depth, 1)), item)
    })

  let #(unknown, owned) = list.partition(keyed, fn(pair) { pair.0 == Unknown })

  Grouping(
    owned: owned |> to_groups |> list.sort(by: compare_group),
    unknown: Group(key: Unknown, members: list.map(unknown, second)),
  )
}

fn key_of(attribution: Attribution, depth: Int) -> GroupKey {
  case attribution {
    Attributed(winner:, ..) ->
      case list.take(winner.path, depth) {
        [] -> Unknown
        path -> Owned(path)
      }
    Unattributed -> Unknown
  }
}

fn second(pair: #(a, b)) -> b {
  pair.1
}

// Collect members under their key, newest first, then reverse each group so
// members keep the order the caller supplied.
fn to_groups(keyed: List(#(GroupKey, a))) -> List(Group(a)) {
  keyed
  |> list.fold([], fn(groups, pair) { insert(groups, pair.0, pair.1) })
  |> list.map(fn(group) { Group(..group, members: list.reverse(group.members)) })
}

fn insert(groups: List(Group(a)), key: GroupKey, item: a) -> List(Group(a)) {
  case groups {
    [] -> [Group(key:, members: [item])]
    [group, ..rest] if group.key == key -> [
      Group(..group, members: [item, ..group.members]),
      ..rest
    ]
    [group, ..rest] -> [group, ..insert(rest, key, item)]
  }
}

fn compare_group(a: Group(x), b: Group(x)) -> Order {
  case a.key, b.key {
    Owned(x), Owned(y) -> compare_path(x, y)
    Owned(_), Unknown -> order.Lt
    Unknown, Owned(_) -> order.Gt
    Unknown, Unknown -> order.Eq
  }
}

/// Every group of a grouping, owned groups first and the unknown group
/// last.
pub fn all_groups(grouping: Grouping(a)) -> List(Group(a)) {
  list.append(grouping.owned, [grouping.unknown])
}

/// Total one column over a group's members. An empty group, a column with
/// no known row, an overlapping column and a ratio column are all refused;
/// no case yields a zero that was not summed from known rows.
///
/// ## Examples
///
/// ```gleam
/// owner.group_total(group, unit.Bytes, measure.Additive, heap_of)
/// ```
pub fn group_total(
  group: Group(a),
  unit u: Unit,
  additivity additivity: Additivity,
  value_of value_of: fn(a) -> Measurement,
) -> Result(Total, SumRefusal) {
  measure.sum(u, additivity, list.map(group.members, value_of))
}
