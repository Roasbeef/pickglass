import gleam/int
import gleam/list
import gleam/string
import pg_data_gen as gen
import pickglass_core/measure.{Additive, Known, Missing, Overlapping}
import pickglass_core/owner.{
  Attributed, Claim, Declared, High, Low, Owned, Provider, Registry, Segment,
  Supervision, Unattributed, Unknown,
}
import pickglass_core/unit.{Bytes}

fn session(id: String) -> owner.Path {
  [Segment("session", id)]
}

fn strand(id: String, name: String) -> owner.Path {
  [Segment("session", id), Segment("strand", name)]
}

pub fn segments_are_validated_test() {
  assert owner.segment("session", "s-12") == Ok(Segment("session", "s-12"))
  assert owner.segment("", "x") == Error(Nil)
  assert owner.segment("x", "") == Error(Nil)
  assert owner.segment("a/b", "x") == Error(Nil)
  assert owner.segment("x", "a\nb") == Error(Nil)
  assert owner.segment(string.repeat("a", 129), "x") == Error(Nil)
}

pub fn path_text_test() {
  assert owner.path_to_string(strand("s1", "main")) == "session:s1/strand:main"
  assert owner.path_to_string([]) == ""
}

// A process's own label beats the registry, which beats supervision, even
// when the weaker claim has higher confidence.
pub fn join_prefers_label_over_registry_over_supervision_test() {
  let label = Claim(session("a"), "r", Declared, Low)
  let registry = Claim(session("b"), "r", Registry, High)
  let supervision = Claim(session("c"), "r", Supervision, High)

  assert owner.join([supervision, registry, label])
    == Attributed(label, [registry, supervision])
  assert owner.join([supervision, registry])
    == Attributed(registry, [supervision])
  assert owner.join([supervision]) == Attributed(supervision, [])
}

pub fn join_orders_provider_between_label_and_registry_test() {
  let provider = Claim(session("a"), "r", Provider, Low)
  let registry = Claim(session("a"), "r", Registry, High)

  assert owner.join([registry, provider]) == Attributed(provider, [])
}

// Within one source, higher confidence wins and a tie keeps the earlier
// claim.
pub fn join_breaks_ties_by_confidence_then_order_test() {
  let low = Claim(session("a"), "r", Declared, Low)
  let high = Claim(session("b"), "r", Declared, High)
  let other_high = Claim(session("c"), "r", Declared, High)

  assert owner.join([low, high]) == Attributed(high, [low])
  assert owner.join([high, other_high]) == Attributed(high, [other_high])
}

// A weaker claim that agrees is not dissent.
pub fn join_reports_only_disagreeing_claims_as_dissent_test() {
  let label = Claim(session("a"), "r", Declared, High)
  let agreeing = Claim(session("a"), "x", Supervision, Low)

  assert owner.join([label, agreeing]) == Attributed(label, [])
}

pub fn join_ignores_empty_paths_and_empty_input_test() {
  assert owner.join([]) == Unattributed
  assert owner.join([Claim([], "r", Declared, High)]) == Unattributed
}

fn items() -> List(#(String, owner.Attribution)) {
  let claim = fn(path) { Attributed(Claim(path, "r", Declared, High), []) }

  [
    #("a1", claim(strand("s1", "main"))),
    #("a2", claim(strand("s1", "side"))),
    #("b1", claim(session("s2"))),
    #("u1", Unattributed),
  ]
}

pub fn group_by_depth_one_groups_by_outermost_segment_test() {
  let grouping = owner.group_by(items(), fn(item) { item.1 }, 1)

  assert list.map(grouping.owned, fn(group) { group.key })
    == [Owned(session("s1")), Owned(session("s2"))]
  assert list.map(grouping.unknown.members, fn(item) { item.0 }) == ["u1"]
}

pub fn group_by_depth_two_splits_strands_test() {
  let grouping = owner.group_by(items(), fn(item) { item.1 }, 2)

  assert list.map(grouping.owned, fn(group) { group.key })
    == [
      Owned(strand("s1", "main")),
      Owned(strand("s1", "side")),
      Owned(session("s2")),
    ]
}

pub fn group_members_keep_their_input_order_test() {
  let same = Attributed(Claim(session("s"), "r", Declared, High), [])
  let grouping = owner.group_by(["x", "y", "z"], fn(_) { same }, 1)

  assert list.map(grouping.owned, fn(group) { group.members })
    == [["x", "y", "z"]]
}

// The unknown group exists even for no items at all.
pub fn unknown_group_is_present_when_empty_test() {
  let empty = owner.group_by([], fn(_) { Unattributed }, 1)
  assert empty.unknown == owner.Group(Unknown, [])
  assert empty.owned == []

  let all_owned =
    owner.group_by(
      ["a"],
      fn(_) { Attributed(Claim(session("s"), "r", Declared, High), []) },
      1,
    )
  assert all_owned.unknown == owner.Group(Unknown, [])
  assert list.last(owner.all_groups(all_owned)) == Ok(owner.Group(Unknown, []))
}

// Every item lands in exactly one group, whatever the depth and claims.
pub fn property_grouping_partitions_every_item_test() {
  use #(claims, depth) <- gen.check(gen.tuple2(
    gen.small_list(gen.small_list(gen.claim())),
    gen.non_negative(),
  ))
  let indexed = list.index_map(claims, fn(group, index) { #(index, group) })
  let grouping = owner.group_by(indexed, fn(item) { owner.join(item.1) }, depth)
  let members =
    owner.all_groups(grouping)
    |> list.flat_map(fn(group) { group.members })

  assert list.length(members) == list.length(indexed)
  assert list.sort(list.map(members, fn(m) { m.0 }), int.compare)
    == list.map(indexed, fn(item) { item.0 })
  assert grouping.unknown.key == Unknown
}

pub fn group_totals_honor_additivity_and_never_invent_zero_test() {
  let group =
    owner.Group(Owned(session("s")), [
      Known(1),
      Missing(measure.ProcessExited),
      Known(2),
    ])
  let value_of = fn(m) { m }

  assert owner.group_total(group, Bytes, Additive, value_of)
    == Ok(measure.Total(3, 2, 1, 0))
  assert owner.group_total(group, Bytes, Overlapping("refc"), value_of)
    == Error(measure.OverlappingRows("refc"))

  let empty = owner.Group(Unknown, [])
  assert owner.group_total(empty, Bytes, Additive, value_of)
    == Error(measure.NothingKnown)
}

pub fn source_and_confidence_codes_round_trip_test() {
  use source <- list.each([Declared, Provider, Registry, Supervision])
  assert owner.parse_source(owner.source_code(source)) == Ok(source)
  assert owner.parse_source("label") == Error(Nil)
}
